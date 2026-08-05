import CoreData
import CloudKit

/// Errors raised before GraphEvo starts a remote CloudKit purge.
public enum GraphCloudPurgeError: LocalizedError, Equatable {
    case notSupportedDuringTests
    case cloudKitNotConfigured
    case cloudContainerUnavailable
    case cloudStoreUnavailable
    case purgeAlreadyInProgress
    case invalidCompletion

    public var errorDescription: String? {
        switch self {
        case .notSupportedDuringTests:
            return "CloudKit purge is disabled while running under tests."
        case .cloudKitNotConfigured:
            return "A CloudKit container identifier is required to purge the store."
        case .cloudContainerUnavailable:
            return "The effective persistent container is not an NSPersistentCloudKitContainer or is not ready."
        case .cloudStoreUnavailable:
            return "No loaded persistent store configured for CloudKit was found."
        case .purgeAlreadyInProgress:
            return "A CloudKit purge is already in progress for this graph."
        case .invalidCompletion:
            return "CloudKit reported an incomplete purge result."
        }
    }
}

extension Graph {
    /// Purges GraphEvo's Core Data CloudKit zone from the remote private
    /// database. This does not delete or recreate the local SQLite store.
    ///
    /// The completion is delivered on the main queue after Core Data invokes
    /// its purge completion. A nil error is considered success only when the
    /// expected zone ID is also returned. After a successful purge, the
    /// caller must reopen or recreate its local store and clear any local
    /// persistent-history token before using the graph again.
    public func purgeCloudStore(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        purgeCloudStore(allowDuringTests: false, completion: completion)
    }

    private func purgeCloudStore(
        allowDuringTests: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard allowDuringTests || !Self.isRunningUnderTests else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.notSupportedDuringTests), completion: completion)
            return
        }

        guard configuration.cloudKitContainerIdentifier != nil else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudKitNotConfigured), completion: completion)
            return
        }

        guard let container = persistentContainer as? NSPersistentCloudKitContainer else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudContainerUnavailable), completion: completion)
            return
        }

        guard let store = cloudKitPersistentStore(in: container) else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudStoreUnavailable), completion: completion)
            return
        }

        guard beginCloudPurge() else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.purgeAlreadyInProgress), completion: completion)
            return
        }

        // Flush the graph context before starting the remote administrative
        // operation. The operation lock also makes Graph.sync/async wait until
        // the purge's Core Data/CloudKit completion has arrived.
        persistenceOperationLock.lock()
        guard let context = managedObjectContext else {
            persistenceOperationLock.unlock()
            endCloudPurge()
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudContainerUnavailable), completion: completion)
            return
        }

        context.perform { [weak self, weak context] in
            guard let self, let context else { return }
            do {
                if context.hasChanges {
                    try context.save()
                }
                let zoneID = CKRecordZone.ID(
                    zoneName: "com.apple.coredata.cloudkit.zone",
                    ownerName: CKCurrentUserDefaultName
                )
                self.invokeCloudPurge(
                    container: container,
                    zoneID: zoneID,
                    store: store
                ) { [weak self] purgedZoneID, error in
                    guard let self else { return }
                    let result: Result<Void, Error>
                    if let error {
                        result = .failure(error)
                    } else if purgedZoneID != zoneID {
                        result = .failure(GraphCloudPurgeError.invalidCompletion)
                    } else {
                        result = .success(())
                    }
                    self.endCloudPurge()
                    self.persistenceOperationLock.unlock()
                    self.deliverPurgeResult(result, completion: completion)
                }
            } catch {
                self.endCloudPurge()
                self.persistenceOperationLock.unlock()
                self.deliverPurgeResult(.failure(error), completion: completion)
            }
        }
    }

    private func cloudKitPersistentStore(
        in container: NSPersistentCloudKitContainer
    ) -> NSPersistentStore? {
        let cloudDescriptions = container.persistentStoreDescriptions.filter {
            $0.cloudKitContainerOptions != nil
        }
        guard !cloudDescriptions.isEmpty else { return nil }

        return container.persistentStoreCoordinator.persistentStores.first { store in
            guard let storeURL = store.url else { return false }
            return cloudDescriptions.contains { description in
                description.url?.standardizedFileURL == storeURL.standardizedFileURL
            }
        }
    }

    private func invokeCloudPurge(
        container: NSPersistentCloudKitContainer,
        zoneID: CKRecordZone.ID,
        store: NSPersistentStore,
        completion: @escaping (CKRecordZone.ID?, Error?) -> Void
    ) {
        container.purgeObjectsAndRecordsInZone(with: zoneID, in: store, completion: completion)
    }

    private func deliverPurgeResult(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

#if DEBUG
extension Graph {
    /// Internal validation seam used by offline tests. It deliberately keeps
    /// the public API's production/test guard intact.
    internal func validateCloudPurgeForTesting(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        purgeCloudStore(allowDuringTests: true, completion: completion)
    }

    /// Test-only seam for exercising completion/error handling without a real
    /// CloudKit container. It is not part of the public API.
    internal func purgeCloudStoreForTesting(
        container: NSPersistentCloudKitContainer,
        store: NSPersistentStore,
        executor: @escaping (NSPersistentCloudKitContainer, CKRecordZone.ID, NSPersistentStore, @escaping (CKRecordZone.ID?, Error?) -> Void) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let identifier = configuration.cloudKitContainerIdentifier, !identifier.isEmpty else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudKitNotConfigured), completion: completion)
            return
        }
        guard beginCloudPurge() else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.purgeAlreadyInProgress), completion: completion)
            return
        }
        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        executor(container, zoneID, store) { [weak self] purgedZoneID, error in
            guard let self else { return }
            defer { self.endCloudPurge() }
            if let error {
                self.deliverPurgeResult(.failure(error), completion: completion)
            } else if purgedZoneID == zoneID {
                self.deliverPurgeResult(.success(()), completion: completion)
            } else {
                self.deliverPurgeResult(.failure(GraphCloudPurgeError.invalidCompletion), completion: completion)
            }
        }
    }
}
#endif
