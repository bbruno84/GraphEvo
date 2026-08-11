import CoreData

/// Details of a CloudKit import operation.
public struct GraphCloudImportEvent {
    /// The CloudKit event identifier, when supplied by Core Data.
    public let identifier: UUID?
    public let storeIdentifier: String
    public let isInitialImport: Bool
    public let succeeded: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let error: Error?

    public init(
        identifier: UUID? = nil,
        storeIdentifier: String,
        isInitialImport: Bool,
        succeeded: Bool,
        startDate: Date?,
        endDate: Date?,
        error: Error?
    ) {
        self.identifier = identifier
        self.storeIdentifier = storeIdentifier
        self.isInitialImport = isInitialImport
        self.succeeded = succeeded
        self.startDate = startDate
        self.endDate = endDate
        self.error = error
    }
}

/// Lifecycle updates for a CloudKit import operation.
public enum GraphCloudImportState {
    case started(GraphCloudImportEvent)
    case finished(GraphCloudImportEvent)
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
        pendingCloudKitEvents.removeAll()
        cloudSyncUploadStartedEventIdentifiers.removeAll()
        cloudSyncUploadFinishedEventIdentifiers.removeAll()
        cloudSyncImportStartedEventIdentifiers.removeAll()
        cloudSyncImportFinishedEventIdentifiers.removeAll()
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
        guard event.type == .import || event.type == .export else { return }
        guard cloudSyncEventObserver != nil || Graph.isRunningUnderTests else { return }

        if cloudSyncStoreIdentifier == nil {
            if let index = pendingCloudKitEvents.firstIndex(where: { $0.identifier == event.identifier }) {
                pendingCloudKitEvents[index] = event
            } else {
                pendingCloudKitEvents.append(event)
            }
            return
        }

        guard cloudSyncStoreIdentifier == event.storeIdentifier else { return }

        if event.type == .export {
            receiveCloudExportEvent(event)
            return
        }

        let isInitialImport = cloudSyncInitialImportPending
        let importEvent = GraphCloudImportEvent(
            identifier: event.identifier,
            storeIdentifier: event.storeIdentifier,
            isInitialImport: isInitialImport,
            succeeded: event.succeeded,
            startDate: event.startDate,
            endDate: event.endDate,
            error: event.error
        )

        if event.endDate == nil {
            guard markCloudImportStarted(event.identifier) else { return }
            emit(.stateChanged(.cloudImport(.started(importEvent))))
            return
        }

        if markCloudImportFinished(event.identifier) {
            emit(.stateChanged(.cloudImport(.finished(importEvent))))
        }

        if event.succeeded {
            cloudSyncInitialImportPending = false
        }
    }

    private func receiveCloudExportEvent(_ event: GraphCloudKitEventSnapshot) {
        let uploadEvent = GraphCloudUploadEvent(
            identifier: event.identifier,
            storeIdentifier: event.storeIdentifier,
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            error: event.error
        )

        if event.endDate == nil {
            guard markCloudUploadStarted(event.identifier) else { return }
            emit(.stateChanged(.cloudUpload(.started(uploadEvent))))
        } else {
            guard markCloudUploadFinished(event.identifier) else { return }
            emit(.stateChanged(.cloudUpload(.finished(uploadEvent))))
        }
    }

    private func markCloudUploadStarted(_ identifier: UUID) -> Bool {
        cloudSyncStateLock.lock()
        defer { cloudSyncStateLock.unlock() }
        guard !cloudSyncUploadStartedEventIdentifiers.contains(identifier) else { return false }
        cloudSyncUploadStartedEventIdentifiers.insert(identifier)
        return true
    }

    private func markCloudUploadFinished(_ identifier: UUID) -> Bool {
        cloudSyncStateLock.lock()
        defer { cloudSyncStateLock.unlock() }
        guard !cloudSyncUploadFinishedEventIdentifiers.contains(identifier) else { return false }
        cloudSyncUploadFinishedEventIdentifiers.insert(identifier)
        return true
    }

    private func markCloudImportStarted(_ identifier: UUID) -> Bool {
        cloudSyncStateLock.lock()
        defer { cloudSyncStateLock.unlock() }
        guard !cloudSyncImportStartedEventIdentifiers.contains(identifier) else { return false }
        cloudSyncImportStartedEventIdentifiers.insert(identifier)
        return true
    }

    private func markCloudImportFinished(_ identifier: UUID) -> Bool {
        cloudSyncStateLock.lock()
        defer { cloudSyncStateLock.unlock() }
        guard !cloudSyncImportFinishedEventIdentifiers.contains(identifier) else { return false }
        cloudSyncImportFinishedEventIdentifiers.insert(identifier)
        return true
    }
}

#if DEBUG
internal extension Graph {
    /// Offline seam used by unit tests; it models the system event without
    /// constructing a real CloudKit container or contacting the network.
    func configureCloudSyncTrackingForTesting(storeIdentifier: String, initialImportPending: Bool) {
        cloudSyncStoreIdentifier = storeIdentifier
        cloudSyncInitialImportPending = initialImportPending
        flushPendingCloudKitEvents()
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
