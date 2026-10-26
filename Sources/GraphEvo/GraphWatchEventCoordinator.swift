//
//  GraphWatchEventCoordinator.swift
//  GraphEvo
//

import CoreData
import Foundation

internal enum GraphWatchLocalCapture {
    private static let lock = NSLock()
    private static var suppressedContexts = Set<ObjectIdentifier>()

    static func isSuppressed(_ context: NSManagedObjectContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedContexts.contains(ObjectIdentifier(context))
    }

    static func whileSuppressed(_ context: NSManagedObjectContext, _ body: () throws -> Void) rethrows {
        let identifier = ObjectIdentifier(context)
        lock.lock()
        let inserted = suppressedContexts.insert(identifier).inserted
        lock.unlock()
        defer {
            lock.lock()
            if inserted { suppressedContexts.remove(identifier) }
            lock.unlock()
        }
        try body()
    }
}

internal final class GraphWatchEventCoordinator {
    private weak var graph: Graph?
    private weak var context: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var pendingLocalDeletions: [GraphWatchEventEnvelope] = []
    private let cloudDelivery: GraphWatchBatchDeliveryCoordinator

    init(graph: Graph, context: NSManagedObjectContext) {
        self.graph = graph
        self.context = context
        self.cloudDelivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: context)
        installObservers(context: context)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    internal func requestCloudDelivery() {
        cloudDelivery.request()
    }

    internal func prepareCloudDelivery(startingAfter token: NSPersistentHistoryToken?) {
        cloudDelivery.prepare(startingAfter: token)
    }

    // Called on the public context queue before the private save removes rows.
    // Resolve IDs here: no private-context objects enter the public report.
    internal func captureTransactionDeletions(_ ids: [NSManagedObjectID]) -> [GraphWatchEventEnvelope] {
        guard let graph, graph.watchReportCompletion != nil,
              graph.watchReportSources.contains(.local), let context else { return [] }
        return materialize(transactionObjects(ids, in: context),
                           operation: .delete, source: .local)
    }

    // Called after the successful save, merge and deletion finalization, on the
    // public context queue. Always defer the callback beyond transaction scopes.
    internal func deliverTransaction(_ ids: [AnyHashable: Any], deletions: [GraphWatchEventEnvelope]) {
        guard let graph, graph.watchReportCompletion != nil,
              graph.watchReportSources.contains(.local), let context else { return }
        let inserted = transactionObjects(ids[NSInsertedObjectsKey] as? [NSManagedObjectID] ?? [], in: context)
        let updated = transactionObjects(ids[NSUpdatedObjectsKey] as? [NSManagedObjectID] ?? [], in: context)
        let deletedURIs = Set((ids[NSDeletedObjectsKey] as? [NSManagedObjectID] ?? [])
            .map { $0.uriRepresentation().absoluteString })
        deliverReport(materialize(inserted, operation: .insert, source: .local) +
                      materialize(updated, operation: .update, source: .local) +
                      deletions.filter { deletedURIs.contains($0.objectURI) },
                      source: .local, deferred: true)
    }

    private func transactionObjects(_ ids: [NSManagedObjectID], in context: NSManagedObjectContext) -> [NSManagedObject] {
        ids.compactMap { id in
            do { return try context.existingObject(with: id) }
            catch {
                graph?.emit(.error(.watchEventMaterialization(source: .local, underlying: error)))
                return nil
            }
        }
    }

    private func installObservers(context: NSManagedObjectContext) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.contextObjectsDidChange(notification)
        })
        observers.append(center.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.contextDidSave(notification)
        })
        observers.append(center.addObserver(
            forName: .GraphEvoSimulatedRemoteChange,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.remoteChange(notification)
        })
    }

    private func contextObjectsDidChange(_ notification: Notification) {
        guard let context, !GraphWatchLocalCapture.isSuppressed(context) else { return }
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            pendingLocalDeletions.removeAll()
            return
        }
        let deleted = managedObjects(notification.userInfo?[NSDeletedObjectsKey])
        guard !deleted.isEmpty else { return }
        let envelopes = materialize(deleted, operation: .delete, source: .local)
        pendingLocalDeletions.append(contentsOf: envelopes)
    }

    private func contextDidSave(_ notification: Notification) {
        guard let context, !GraphWatchLocalCapture.isSuppressed(context) else { return }
        let inserted = materialize(
            managedObjects(notification.userInfo?[NSInsertedObjectsKey]),
            operation: .insert,
            source: .local
        )
        let updated = materialize(
            managedObjects(notification.userInfo?[NSUpdatedObjectsKey]),
            operation: .update,
            source: .local
        )

        // Merges can also emit ObjectsDidChange deletions. Only this save's
        // actual deleted IDs belong to its local batch.
        let savedDeletions = managedObjects(notification.userInfo?[NSDeletedObjectsKey])
        let savedDeletionURIs = Set(savedDeletions.map { $0.objectID.uriRepresentation().absoluteString })
        var deleted = pendingLocalDeletions.filter { savedDeletionURIs.contains($0.objectURI) }
        pendingLocalDeletions.removeAll()
        let capturedURIs = Set(deleted.map(\.objectURI))
        let fallbackDeleted = savedDeletions
            .filter { !capturedURIs.contains($0.objectID.uriRepresentation().absoluteString) }
        deleted.append(contentsOf: materialize(fallbackDeleted, operation: .delete, source: .local))

        deliverReport(inserted + updated + deleted, source: .local)
    }

    private func remoteChange(_ notification: Notification) {
        guard let context else { return }
        if notification.userInfo?[GraphEvoOrderedRemoteChangesKey] != nil {
            // Legacy Watch instances observe the original notification
            // directly. The batch path owns materialization and retry for
            // Persistent History reports, so do not materialize a second
            // copy here or let a batch failure affect legacy callbacks.
            cloudDelivery.request()
            return
        }

        let envelopes: [GraphWatchEventEnvelope]
        let inserted = materialize(managedObjects(notification.userInfo?[NSInsertedObjectsKey], in: context), operation: .insert, source: .cloud)
        let updated = materialize(managedObjects(notification.userInfo?[NSUpdatedObjectsKey], in: context), operation: .update, source: .cloud)
        let deleted = materialize(managedObjects(notification.userInfo?[NSDeletedObjectsKey], in: context), operation: .delete, source: .cloud)
        envelopes = inserted + updated + deleted

        // Direct/simulated notifications do not have a Persistent History
        // delivery cursor and retain the existing batch behavior.
        deliverReport(envelopes, source: .cloud)
    }

    private func materialize(
        _ objects: [NSManagedObject],
        operation: GraphWatchChangeOperation,
        source: GraphSource,
        transactionIndex: Int = 0,
        changeIndex: Int = 0
    ) -> [GraphWatchEventEnvelope] {
        guard let graph else { return [] }
        return objects.enumerated().compactMap { offset, object in
            do {
                return try GraphWatchEventMaterializer.materialize(
                    object: object,
                    operation: operation,
                    source: source,
                    transactionIndex: transactionIndex,
                    changeIndex: changeIndex + offset
                )
            } catch {
                // Preserve the legacy Watch error contract. The retryable
                // warning is emitted only by the persistent-history batch
                // delivery path.
                graph.emit(.error(.watchEventMaterialization(source: source, underlying: error)))
                return nil
            }
        }
    }

    private func deliverReport(_ envelopes: [GraphWatchEventEnvelope], source: GraphSource, deferred: Bool = false) {
        guard let graph,
              graph.watchReportSources.contains(source),
              graph.watchReportCompletion != nil,
              !envelopes.isEmpty else { return }
        guard let context else { return }
        let results = GraphWatchStructuralValidation.validate(envelopes, in: context)
        let invalidIDs = Set(results.filter { !$0.isValid }.map(\.objectID))
        let issues = GraphWatchStructuralValidation.issues(results, envelopes: envelopes)
        if source == .cloud && !issues.isEmpty {
            graph.emit(.warning(.watchReportMaterializationFailed(source: source, failedEvents: issues.count, details: issues)))
            return
        }
        // Local delivery retains its best-effort contract; there is no history retry cursor.
        for issue in issues {
            graph.emit(.error(.watchEventMaterialization(source: source, underlying: issue.error)))
        }
        let ordered = envelopes.filter { !invalidIDs.contains($0.owner.objectID) }
            .sorted { $0.isOrdered(before: $1) }
        guard !ordered.isEmpty else { return }
        let deliver = { [weak graph] in
            guard let graph else { return }
            let report = GraphWatchReport(graph: graph, source: source, events: ordered.map(\.event), structuralValidationResults: results)
            graph.watchReportCompletion?(report, nil)
        }
        if Thread.isMainThread && !deferred {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func managedObjects(_ value: Any?, in context: NSManagedObjectContext? = nil) -> [NSManagedObject] {
        guard let set = value as? NSSet else { return [] }
        return set.allObjects.compactMap { value in
            if let object = value as? NSManagedObject { return object }
            if let objectID = value as? NSManagedObjectID, let context { return context.object(with: objectID) }
            return nil
        }.sorted {
            $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }
    }
}
