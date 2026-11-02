import CoreData
import Foundation

/// An explicit native migration admitted only for one isolated workspace owner.
/// Model construction, stage callbacks and completion stay within native ownership.
package struct StoreNativeMigration: Sendable {
    package let sourceSchema: StoreSchema
    package let seedURL: URL
    package let document: Data
    package let prepare: (@Sendable (NSPersistentContainer) throws -> Void)?
    package let configure: @Sendable (NSPersistentStoreDescription, NSManagedObjectModel) throws -> Void
    package let finish: @Sendable (NSPersistentContainer) throws -> Void

    package init(sourceSchema: StoreSchema, seedURL: URL, document: Data,
                 prepare: (@Sendable (NSPersistentContainer) throws -> Void)? = nil,
                 configure: @escaping @Sendable (NSPersistentStoreDescription, NSManagedObjectModel) throws -> Void,
                 finish: @escaping @Sendable (NSPersistentContainer) throws -> Void) {
        self.sourceSchema = sourceSchema; self.seedURL = seedURL; self.document = document
        self.prepare = prepare
        self.configure = configure; self.finish = finish
    }

    package static let documentKey = "GraphEvo.nativeV1Migration"

    func seed(_ resolved: ResolvedStore, beforeStamp: (() throws -> Void)? = nil) throws {
        guard let url = resolved.url, let operation = resolved.configuration.workspaceID,
              let graph = resolved.configuration.exclusiveGraphID,
              resolved.configuration.access == .readWrite,
              resolved.configuration.workspaceSessionID != nil,
              resolved.configuration.cloudKitContainerIdentifier == nil,
              resolved.configuration.sharedStoreURL == nil, !document.isEmpty else {
            throw StoreRuntimeError.invalidConfiguration("Native migration requires an isolated local workspace.")
        }
        let sourceModel = sourceSchema.makeModel()
        guard !sourceSchema.identifier.isEmpty, !sourceSchema.entityVersionHashes.isEmpty,
              sourceModel.entityVersionHashesByName == sourceSchema.entityVersionHashes,
              sourceSchema.requiredModelVersionIdentifier.map({ sourceModel.versionIdentifiers == [AnyHashable($0)] }) ?? true else {
            throw StoreRuntimeError.invalidModel(sourceSchema.identifier)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".graphevo-native-seed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try autoreleasepool {
            let prepared = staging.appendingPathComponent("Graph.sqlite")
            let copier = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
            let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true]
            try copier.replacePersistentStore(at: prepared, destinationOptions: options, withPersistentStoreFrom: seedURL,
                                             sourceOptions: options, ofType: NSSQLiteStoreType)
            try beforeStamp?()
            var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: prepared)
            metadata[StoreNativeContext.workspaceKey] = operation.uuidString
            metadata[StoreNativeContext.historySyncGraphKey] = graph.uuidString
            metadata[Self.documentKey] = document
            try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: prepared, options: options)
            // Publish only a fully marked source. A failed metadata write must
            // never leave an ordinary v1 store at the requested destination.
            try copier.replacePersistentStore(at: url, destinationOptions: options, withPersistentStoreFrom: prepared,
                                             sourceOptions: options, ofType: NSSQLiteStoreType)
        }
    }
}
