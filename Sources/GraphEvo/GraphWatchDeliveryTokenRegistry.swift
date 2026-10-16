//
//  GraphWatchDeliveryTokenRegistry.swift
//  GraphEvo
//

import CoreData
import Foundation

internal final class GraphWatchDeliveryTokenStore {
    private let url: URL
    private let lock = NSLock()

    init(configuration: GraphStoreConfiguration, storeURL: URL) {
        let directory: URL
        if let group = configuration.appGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            directory = container.appendingPathComponent("CosmicMind/Graph/PersistentHistory", isDirectory: true)
        } else {
            directory = storeURL.deletingLastPathComponent().appendingPathComponent(".GraphEvo/PersistentHistory", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("watch-delivery-\(Self.hash(storeURL.standardizedFileURL.path)).token")
    }

    func load() throws -> NSPersistentHistoryToken? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    func save(_ token: NSPersistentHistoryToken) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try data.write(to: url, options: [.atomic])
    }

    #if DEBUG
    var debugURL: URL { url }
    #endif

    private static func hash(_ value: String) -> String {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result = result &* 1_099_511_628_211
        }
        return String(format: "%016llx", result)
    }
}

internal final class GraphWatchDeliveryTokenRegistry {
    static let shared = GraphWatchDeliveryTokenRegistry()
    private let lock = NSLock()
    private var stores: [String: GraphWatchDeliveryTokenStore] = [:]

    private init() {}

    func store(configuration: GraphStoreConfiguration, storeURL: URL) -> GraphWatchDeliveryTokenStore {
        let key = storeURL.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let store = stores[key] { return store }
        let store = GraphWatchDeliveryTokenStore(configuration: configuration, storeURL: storeURL)
        stores[key] = store
        return store
    }
}

internal enum GraphWatchDeliveryError: LocalizedError {
    case historyGap(underlying: Error)
    case tokenStore(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .historyGap(let error): return "The Persistent History interval required by the Graph Watch report is no longer available: \(error.localizedDescription)"
        case .tokenStore(let error): return "The Graph Watch delivery token could not be read or written: \(error.localizedDescription)"
        }
    }
}

internal final class GraphWatchBatchDeliveryCoordinator {
    private weak var graph: Graph?
    private weak var context: NSManagedObjectContext?
    private let queue = DispatchQueue(label: "GraphEvo.GraphWatchBatchDelivery")
    private let store: GraphWatchDeliveryTokenStore
    private var processing = false
    private var pending = false
    private var token: NSPersistentHistoryToken?
    private var tokenLoaded = false

    init(graph: Graph, context: NSManagedObjectContext) {
        self.graph = graph
        self.context = context
        let url = graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL
        self.store = GraphWatchDeliveryTokenRegistry.shared.store(configuration: graph.configuration, storeURL: url)
    }

    func prepare(startingAfter processingToken: NSPersistentHistoryToken?) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self, !self.tokenLoaded else { return }
            do {
                self.token = try self.store.load()
                if self.token == nil, let processingToken {
                    self.token = processingToken
                    try self.store.save(processingToken)
                }
                self.tokenLoaded = true
            } catch {
                self.tokenLoaded = true
                self.emitStructuralError(error)
            }
        }
    }

    func request() {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = true
            self.startIfNeeded()
        }
    }

    private var isEnabled: Bool {
        guard let graph else { return false }
        guard graph.watchReportSources.contains(.cloud) else { return false }
        return graph.watchReportCompletion != nil
    }

    private func startIfNeeded() {
        guard !processing, pending, let graph, let context else { return }
        processing = true
        pending = false
        if !tokenLoaded {
            do {
                token = try store.load()
                tokenLoaded = true
            } catch {
                tokenLoaded = true
                finishStructural(error)
                return
            }
        }

        let bg = graph.persistentContainer?.newBackgroundContext()
        guard let bg else { finishStructural(GraphWatchDeliveryError.tokenStore(underlying: NSError(domain: "GraphEvo", code: 1))); return }
        bg.transactionAuthor = GraphDeviceAuthor.current()
        bg.perform { [weak self, weak graph] in
            guard let self, let graph else { return }
            do {
                let fetched = try self.fetch(after: self.token, in: bg)
                if fetched.records.isEmpty {
                    // Consume history containing only local changes or superseded remote events.
                    if let last = fetched.lastToken {
                        try self.store.save(last)
                        self.token = last
                    }
                    self.finishWithoutReport()
                    return
                }
                try self.merge(fetched, into: context)
                self.materializeAndDeliver(fetched, context: context)
            } catch {
                if self.isHistoryGap(error) {
                    self.processAfterHistoryGap(using: bg, context: context, original: error)
                } else {
                    self.finishStructural(error)
                }
            }
        }
    }

    private func processAfterHistoryGap(using bg: NSManagedObjectContext, context: NSManagedObjectContext, original: Error) {
        do {
            let fetched = try fetch(after: nil, in: bg, historyGap: true, gapError: GraphWatchDeliveryError.historyGap(underlying: original))
            guard !fetched.records.isEmpty else {
                if let current = fetched.lastToken ?? graph?.ph_processingTokenForWatchDelivery() {
                    try store.save(current)
                    token = current
                }
                finishWith(report: nil, error: GraphWatchDeliveryError.historyGap(underlying: original))
                return
            }
            try merge(fetched, into: context)
            // Re-enter the normal materialization path with the retained history.
            materializeAndDeliver(fetched, context: context)
        } catch {
            finishStructural(error)
        }
    }

    private func materializeAndDeliver(_ fetched: FetchedHistory, context: NSManagedObjectContext) {
        guard let graph else { return }
        var envelopes: [GraphWatchEventEnvelope] = []
        var issues: [GraphWatchMaterializationIssue] = []
        var validationResults: [GraphStructuralValidationResult] = []
        var unmaterializedDeletions: [GraphWatchUnmaterializedDeletion] = []
        do {
            try context.performAndWait {
                for record in fetched.records {
                    let object = context.object(with: record.objectID)
                    do {
                        if let envelope = try GraphWatchEventMaterializer.materialize(object: object, operation: record.operation, source: .cloud, transactionIndex: record.transactionIndex, changeIndex: record.changeIndex) { envelopes.append(envelope) }
                    } catch {
                        if record.operation == .delete {
                            // The retained delete is proof of absence, not an import to await.
                            unmaterializedDeletions.append(GraphWatchUnmaterializedDeletion(objectID: record.objectID, error: error))
                        } else {
                            issues.append(GraphWatchMaterializationIssue(eventKind: record.operation.diagnosticName, objectReference: redactedReference(object), error: error))
                        }
                    }
                }
                try Graph.finalizePersistedDeletions(in: context, ids: Set(fetched.deleted))
                validationResults = GraphWatchStructuralValidation.validate(envelopes, in: context, deletedIDs: Set(fetched.deleted))
                issues += GraphWatchStructuralValidation.issues(validationResults, envelopes: envelopes)
            }
        } catch {
            finishStructural(error)
            return
        }
        if !issues.isEmpty {
            graph.emit(.warning(.watchReportMaterializationFailed(source: .cloud, failedEvents: issues.count, details: issues)))
            // Surviving-object failures retain the entire batch, including
            // deletion evidence, even after history-gap recovery.
            finishMaterializationFailure()
            return
        }
        do {
            guard let lastToken = fetched.lastToken else {
                finishWith(report: nil, error: fetched.gapError)
                return
            }
            try store.save(lastToken)
            token = lastToken
            let report = envelopes.isEmpty && unmaterializedDeletions.isEmpty ? nil : GraphWatchReport(
                graph: graph, source: .cloud,
                events: envelopes.sorted { $0.isOrdered(before: $1) }.map(\.event),
                structuralValidationResults: validationResults,
                unmaterializedDeletions: unmaterializedDeletions.sorted {
                    $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
                }
            )
            finishWith(report: report, error: fetched.gapError)
        } catch { finishStructural(error) }
    }

    private func merge(_ fetched: FetchedHistory, into context: NSManagedObjectContext) throws {
        try GraphWatchLocalCapture.whileSuppressed(context) {
            try context.performAndWait {
                let mergeInfo: [AnyHashable: Any] = [
                    NSInsertedObjectIDsKey: NSSet(array: fetched.inserted),
                    NSUpdatedObjectIDsKey: NSSet(array: fetched.updated),
                    NSDeletedObjectIDsKey: NSSet(array: fetched.deleted)
                ]
                context.mergeChanges(fromContextDidSave: Notification(
                    name: .GraphEvoSimulatedRemoteChange,
                    object: context,
                    userInfo: mergeInfo
                ))
                try Graph.finalizePersistedDeletions(in: context, ids: Set(fetched.deleted))
            }
        }
    }

    private struct FetchedHistory {
        let records: [GraphWatchRemoteRecord]
        let inserted: [NSManagedObjectID]
        let updated: [NSManagedObjectID]
        let deleted: [NSManagedObjectID]
        let lastToken: NSPersistentHistoryToken?
        let historyGap: Bool
        let gapError: Error?
    }

    private func fetch(after token: NSPersistentHistoryToken?, in context: NSManagedObjectContext, historyGap: Bool = false, gapError: Error? = nil) throws -> FetchedHistory {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        let result = try context.execute(request) as! NSPersistentHistoryResult
        let transactions = (result.result as? [NSPersistentHistoryTransaction] ?? []).enumerated().sorted { lhs, rhs in
            if lhs.element.transactionNumber != rhs.element.transactionNumber { return lhs.element.transactionNumber < rhs.element.transactionNumber }
            if lhs.element.timestamp != rhs.element.timestamp { return lhs.element.timestamp < rhs.element.timestamp }
            return lhs.offset < rhs.offset
        }
        var records: [GraphWatchRemoteRecord] = []
        var inserted: [NSManagedObjectID] = []
        var updated: [NSManagedObjectID] = []
        var deleted: [NSManagedObjectID] = []
        var last: NSPersistentHistoryToken?
        var locallyDeleted = Set<NSManagedObjectID>()
        for (txIndex, pair) in transactions.enumerated() {
            let tx = pair.element
            last = tx.token
            if tx.author == GraphDeviceAuthor.current() {
                // Local changes do not produce cloud callbacks, but their deletions
                // prove that older remote events no longer have a surviving object.
                for change in tx.changes ?? [] {
                    if change.changeType == .delete { locallyDeleted.insert(change.changedObjectID) }
                    if change.changeType == .insert { locallyDeleted.remove(change.changedObjectID) }
                }
                continue
            }
            for (changeIndex, change) in (tx.changes ?? []).enumerated() {
                let operation: GraphWatchChangeOperation
                switch change.changeType {
                case .insert:
                    locallyDeleted.remove(change.changedObjectID)
                    operation = .insert
                    inserted.append(change.changedObjectID)
                case .update: operation = .update; updated.append(change.changedObjectID)
                case .delete: operation = .delete; deleted.append(change.changedObjectID)
                @unknown default: continue
                }
                records.append(GraphWatchRemoteRecord(objectID: change.changedObjectID, operation: operation, transactionIndex: txIndex, changeIndex: changeIndex))
            }
        }
        guard let last else { return FetchedHistory(records: [], inserted: [], updated: [], deleted: [], lastToken: token, historyGap: historyGap, gapError: gapError) }
        let allDeleted = locallyDeleted.union(deleted)
        return FetchedHistory(
            // Inserts/updates superseded by a retained deletion cannot be materialized
            // from today's store. Keep remote deletions for typed or reference delivery.
            records: records.filter {
                !locallyDeleted.contains($0.objectID) && ($0.operation == .delete || !allDeleted.contains($0.objectID))
            },
            inserted: inserted.filter { !allDeleted.contains($0) },
            updated: updated.filter { !allDeleted.contains($0) },
            deleted: deleted.filter { !locallyDeleted.contains($0) },
            lastToken: last, historyGap: historyGap, gapError: gapError
        )
    }

    private func isHistoryGap(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == 134301 || nsError.code == 134501
    }

    private func finishMaterializationFailure() {
        queue.async { [weak self] in
            guard let self else { return }
            self.processing = false
            self.startIfNeeded()
        }
    }

    private func finishWithoutReport() {
        queue.async { [weak self] in
            guard let self else { return }
            self.processing = false
            self.startIfNeeded()
        }
    }

    private func finishStructural(_ error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            self.processing = false
            self.emitStructuralError(error)
            self.startIfNeeded()
        }
    }
    private func emitStructuralError(_ error: Error) {
        guard let graph else { return }
        DispatchQueue.main.async { [weak graph] in graph?.watchReportCompletion?(nil, error) }
    }
    private func finishWith(report: GraphWatchReport?, error: Error?) {
        queue.async { [weak self, weak graph] in
            guard let self, let graph else { return }
            let completion = graph.watchReportCompletion
            self.processing = false
            DispatchQueue.main.async { [weak graph] in
                guard graph != nil else { return }
                completion?(report, error)
            }
            self.startIfNeeded()
        }
    }
}
