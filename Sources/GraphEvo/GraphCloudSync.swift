import CoreData

/// Details of a completed CloudKit import handled by GraphEvo.
public struct GraphCloudImportEvent {
    public let storeIdentifier: String
    public let isInitialImport: Bool
    public let succeeded: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let error: Error?

    public init(
        storeIdentifier: String,
        isInitialImport: Bool,
        succeeded: Bool,
        startDate: Date?,
        endDate: Date?,
        error: Error?
    ) {
        self.storeIdentifier = storeIdentifier
        self.isInitialImport = isInitialImport
        self.succeeded = succeeded
        self.startDate = startDate
        self.endDate = endDate
        self.error = error
    }
}

/// Receives completed import operations from a GraphEvo CloudKit container.
public protocol GraphCloudSyncDelegate: AnyObject {
    func graph(_ graph: Graph, didCompleteCloudImport event: GraphCloudImportEvent)
}

internal struct GraphCloudKitEventSnapshot {
    let identifier: UUID
    let storeIdentifier: String
    let type: NSPersistentCloudKitContainer.EventType
    let startDate: Date?
    let endDate: Date?
    let succeeded: Bool
    let error: Error?
}

internal extension Graph {
    /// Installs the observer before `loadPersistentStores` starts. Events are
    /// retained until the loaded store exposes its stable identifier.
    func installCloudSyncEventObserverIfNeeded(for _: NSPersistentCloudKitContainer) {
        guard cloudSyncEventObserver == nil, !Graph.isRunningUnderTests else { return }

        cloudSyncEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            // The SDK documents the event in userInfo but does not make the
            // notification object part of the contract. Filter by store ID
            // below instead of relying on the notification object.
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            self?.receiveCloudKitEvent(
                GraphCloudKitEventSnapshot(
                    identifier: event.identifier,
                    storeIdentifier: event.storeIdentifier,
                    type: event.type,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    succeeded: event.succeeded,
                    error: event.error
                )
            )
        }
    }

    func removeCloudSyncEventObserver() {
        if let observer = cloudSyncEventObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudSyncEventObserver = nil
        }
        pendingCloudImportEvents.removeAll()
        pendingCloudKitEvents.removeAll()
    }

    /// Binds event handling to the identifier of the store actually loaded by
    /// this Graph and records whether its replica is currently empty.
    func prepareCloudSyncTracking(for container: NSPersistentCloudKitContainer) {
        guard let store = container.persistentStoreCoordinator.persistentStores.first else { return }
        cloudSyncStoreIdentifier = store.identifier
        cloudSyncInitialImportPending = isLocallyEmptyStore()
        flushPendingCloudKitEvents()
    }

    private func isLocallyEmptyStore() -> Bool {
        guard let context = managedObjectContext else { return false }
        var isEmpty = true
        context.performAndWait {
            for entity in context.persistentStoreCoordinator?.managedObjectModel.entities ?? [] {
                guard let name = entity.name else { continue }
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                request.fetchLimit = 1
                do {
                    if try context.count(for: request) > 0 {
                        isEmpty = false
                        break
                    }
                } catch {
                    // An unsupported/abstract entity must not make the whole
                    // store appear populated; continue with the other entities.
                }
            }
        }
        return isEmpty
    }

    private func flushPendingCloudKitEvents() {
        guard let storeIdentifier = cloudSyncStoreIdentifier else { return }
        let matching = pendingCloudKitEvents.filter { $0.storeIdentifier == storeIdentifier }
        pendingCloudKitEvents.removeAll()
        matching.forEach { event in
            receiveCloudKitEvent(event)
        }
    }

    private func receiveCloudKitEvent(_ event: GraphCloudKitEventSnapshot) {
        guard event.type == .import, event.endDate != nil else { return }
        guard cloudSyncEventObserver != nil || Graph.isRunningUnderTests else { return }

        if cloudSyncStoreIdentifier == nil {
            if !pendingCloudKitEvents.contains(where: { $0.identifier == event.identifier }) {
                pendingCloudKitEvents.append(event)
            }
            return
        }

        guard !hasProcessedCloudEvent(event.identifier) else { return }
        guard cloudSyncStoreIdentifier == event.storeIdentifier else { return }

        let isInitialImport = cloudSyncInitialImportPending
        let importEvent = GraphCloudImportEvent(
            storeIdentifier: event.storeIdentifier,
            isInitialImport: isInitialImport,
            succeeded: event.succeeded,
            startDate: event.startDate,
            endDate: event.endDate,
            error: event.error
        )

        if event.succeeded {
            cloudSyncInitialImportPending = false
        }
        deliverCloudImportEvent(importEvent)
    }

    private func deliverCloudImportEvent(_ event: GraphCloudImportEvent) {
        if Thread.isMainThread {
            if let delegate = cloudSyncDelegate {
                delegate.graph(self, didCompleteCloudImport: event)
            } else {
                pendingCloudImportEvents.append(event)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let delegate = self.cloudSyncDelegate {
                    delegate.graph(self, didCompleteCloudImport: event)
                } else {
                    self.pendingCloudImportEvents.append(event)
                }
            }
        }
    }

    func flushPendingCloudImportEvents() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.flushPendingCloudImportEvents() }
            return
        }
        guard let delegate = cloudSyncDelegate else { return }
        let events = pendingCloudImportEvents
        pendingCloudImportEvents.removeAll()
        events.forEach { delegate.graph(self, didCompleteCloudImport: $0) }
    }

    private func hasProcessedCloudEvent(_ identifier: UUID) -> Bool {
        cloudSyncStateLock.lock()
        defer { cloudSyncStateLock.unlock() }
        return !processedCloudImportEventIdentifiers.insert(identifier).inserted
    }
}

#if DEBUG
internal extension Graph {
    /// Offline seam used by unit tests; it models the system event without
    /// constructing a real CloudKit container or contacting the network.
    func configureCloudSyncTrackingForTesting(storeIdentifier: String, initialImportPending: Bool) {
        cloudSyncStoreIdentifier = storeIdentifier
        cloudSyncInitialImportPending = initialImportPending
    }

    func receiveCloudKitEventForTesting(
        identifier: UUID = UUID(),
        storeIdentifier: String,
        type: NSPersistentCloudKitContainer.EventType,
        startDate: Date? = Date(),
        endDate: Date? = Date(),
        succeeded: Bool,
        error: Error? = nil
    ) {
        receiveCloudKitEvent(GraphCloudKitEventSnapshot(
            identifier: identifier,
            storeIdentifier: storeIdentifier,
            type: type,
            startDate: startDate,
            endDate: endDate,
            succeeded: succeeded,
            error: error
        ))
    }
}
#endif
