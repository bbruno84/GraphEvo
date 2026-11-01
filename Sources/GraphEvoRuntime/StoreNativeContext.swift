import CoreData
import Foundation

/// Native routing metadata remains confined to trusted context operations.
package enum StoreNativeContext {
    package static let privateURLKey = "GraphEvo.v2.privateStoreURL"
    package static let sharedURLKey = "GraphEvo.v2.sharedStoreURL"
    package typealias CancellationCheck = @Sendable () throws -> Void
    package static let cancellationKey = "GraphEvo.v2.cancellationCheck"
    package static func cancellationCheck(in context: NSManagedObjectContext) -> CancellationCheck {
        (context.userInfo[cancellationKey] as? CancellationCheck) ?? {}
    }
    package static let containerKey = "GraphEvo.v2.container"
    /// Persistent store purpose, not an application format or a synchronization certificate.
    package static let workspaceKey = "GraphEvo.v2.migrationWorkspace"
    package static let historySyncGraphKey = "GraphEvo.v2.historySyncGraphID"

    package static func privateStore(in context: NSManagedObjectContext) -> NSPersistentStore? {
        guard let url = context.userInfo[privateURLKey] as? URL else {
            return context.persistentStoreCoordinator?.persistentStores.first
        }
        return context.persistentStoreCoordinator?.persistentStores.first { $0.url == url }
    }

    package static func isShared(_ store: NSPersistentStore?, in context: NSManagedObjectContext) -> Bool {
        guard let store, let url = context.userInfo[sharedURLKey] as? URL else { return false }
        return store.url == url
    }
}
