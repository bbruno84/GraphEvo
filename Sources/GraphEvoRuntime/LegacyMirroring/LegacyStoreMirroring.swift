import CloudKit
import CoreData
import Foundation
import os

/// Transitional native mirror support, confined to its StoreResources owner.
/// New custom sync must not reuse native share assignments, tokens or setup state.
final class LegacyStoreMirroring {
    private let tracker = StoreCloudSetupTracker()
    private var observers: [NSObjectProtocol] = []

    static func makeContainer(name: String, model: NSManagedObjectModel,
                              descriptions: [NSPersistentStoreDescription],
                              configuration: StoreConfiguration) throws -> NSPersistentCloudKitContainer {
        guard let identifier = configuration.cloudKitContainerIdentifier,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .sqlite = configuration.location, configuration.access == .readWrite else {
            throw StoreRuntimeError.invalidConfiguration("Mirroring requires writable SQLite resources and a container identifier.")
        }
        for (index, description) in descriptions.enumerated() {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
            options.databaseScope = index == 0 ? .private : .shared
            description.cloudKitContainerOptions = options
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        return NSPersistentCloudKitContainer(name: name, managedObjectModel: model)
    }

    init?(container: NSPersistentContainer, invalidations: StoreInvalidationHub) {
        guard let cloud = container as? NSPersistentCloudKitContainer else { return nil }
        let tracker = tracker
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged,
            object: nil, queue: nil) { _ in invalidations.publish(.accountChange) })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: cloud, queue: nil) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            // Share metadata can change without a persistent-history transaction.
            invalidations.publish(.nativeOperation)
            if event.type == .setup {
                let failure = event.error.map { (($0 as NSError).domain, ($0 as NSError).code) }
                tracker.record(event.storeIdentifier, success: event.succeeded, failure: failure)
            }
        })
    }

    func snapshot(identifiers: [String]) -> StoreCloudSetup {
        tracker.snapshot(configured: true, identifiers: identifiers)
    }

    /// Called after every owned store detaches successfully; failed detachment retains observers.
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit { stop() }
}

/// Notifications update state synchronously, avoiding reordering through unstructured actor tasks.
final class StoreCloudSetupTracker: Sendable {
    private struct State: Sendable {
        var ready = Set<String>()
        var failure: (String, Int)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ identifier: String, success: Bool, failure: (String, Int)?) {
        state.withLock { state in
            if success { state.ready.insert(identifier) }
            else { state.ready.remove(identifier); state.failure = failure }
        }
    }

    func snapshot(configured: Bool, identifiers: [String]) -> StoreCloudSetup {
        state.withLock { state in
            StoreCloudSetup(configured: configured, storeCount: identifiers.count,
                readyStoreCount: identifiers.filter { state.ready.contains($0) }.count,
                latestFailureDomain: state.failure?.0, latestFailureCode: state.failure?.1)
        }
    }
}
