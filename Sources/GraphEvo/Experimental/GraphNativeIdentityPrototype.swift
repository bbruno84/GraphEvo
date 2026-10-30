import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Local laboratory only. Never selected by the public store schema or opener.
package enum GraphNativeIdentityPrototype {
    package static let graphAttribute = GraphNativeIdentityColumns.graphAttribute
    package static let nodeAttribute = GraphNativeIdentityColumns.nodeAttribute
    private static let activationKey = GraphTypedStoreAdapter.prefix + "nativeIdentityPrototype"
    private static let activationVersion = "local.1"

    package static func makeModel(indexed: Bool) -> NSManagedObjectModel {
        GraphNativeIdentityColumns.makeModel(indexed: indexed, includingDataVersion: false)
    }

    /// Package-only local lab: retain the normal runtime owner, leases, scopes and commit guards.
    package static func openLab(at url: URL, indexed: Bool, fullAdapter: Bool = false) async throws -> GraphDatabase {
        GraphValueTransformer.register()
        let base = GraphTypedStoreAdapter.database
        let graph = GraphStoreAdapter(initialize: base.graph.initialize, fetch: { context, graphID, id in
            guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            return try record(context, id: id)
        }, fetchAll: base.graph.fetchAll, insert: { context, graphID, value in
            guard value.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            if fullAdapter { try base.graph.insert(context, graphID, value) }
            else { try insert(context, value) }
        }, patch: { context, graphID, value in
            guard value.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            if fullAdapter { return try base.graph.patch(context, graphID, value) }
            return try patch(context, value)
        }, delete: base.graph.delete, attachmentMetadata: base.graph.attachmentMetadata, query: base.graph.query)
        let adapter = GraphDatabaseAdapter(graph: graph, catalog: { try catalog($0) }, create: { context, id in
            try base.create(context, id)
            try backfill(context, graphID: id)
        }, upgrade: { _, _ in throw GraphStoreError.unsupportedLayout })
        let schema = StoreSchema(identifier: "c02b.local.identity.\(indexed ? "indexed" : "columns")",
            entityVersionHashes: makeModel(indexed: indexed).entityVersionHashesByName,
            makeModel: { makeModel(indexed: indexed) })
        return try await GraphDatabase.open(configuration: StoreConfiguration(location: .sqlite(url)), schema: schema, adapter: adapter)
    }

    /// Explicit copy-to-new-destination migration. The caller supplies an owned, closed source copy.
    package static func migrateCopy(from source: URL, to destination: URL, indexed: Bool) throws {
        guard source.isFileURL, destination.isFileURL,
              source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else { throw GraphStoreError.unsupportedLayout }
        GraphValueTransformer.register()
        let original = Model.makeModel(), candidate = makeModel(indexed: indexed)
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: original, destinationModel: candidate)
        let manager = NSMigrationManager(sourceModel: original, destinationModel: candidate)
        // Exercise a copy-to-new-store mapping rather than the store-specific in-place optimization.
        manager.usesStoreSpecificMigrationManager = false
        try manager.migrateStore(from: source, sourceType: NSSQLiteStoreType, options: nil, with: mapping,
            toDestinationURL: destination, destinationType: NSSQLiteStoreType, destinationOptions: nil)
    }

    private static let access = GraphNativeIdentityAccess(activationKey: activationKey, activationVersion: activationVersion)

    package static func backfill(_ context: NSManagedObjectContext, graphID: GraphID) throws { try access.backfill(context, graphID: graphID) }
    package static func record(_ context: NSManagedObjectContext, id: GraphNodeID) throws -> GraphRecord? { try access.record(context, id: id) }
    package static func validateIdentityInventory(_ context: NSManagedObjectContext, graphID: GraphID) throws -> Int { try access.validateIdentityInventory(context, graphID: graphID) }
    package static func validateAll(_ context: NSManagedObjectContext, graphID: GraphID) throws -> Int { try access.validateAll(context, graphID: graphID) }
    package static func insert(_ context: NSManagedObjectContext, _ record: GraphRecord) throws { try access.insert(context, record) }
    package static func patch(_ context: NSManagedObjectContext, _ patch: GraphRecordPatch) throws -> GraphRecord { try access.patch(context, patch) }
    private static func catalog(_ context: NSManagedObjectContext) throws -> [GraphID] { try access.catalog(context) }

}

extension Node {
    /// Trusted probe facade only; default-model nodes do not have these attributes.
    package func setPrototypeIdentity(_ id: GraphNodeID?) throws {
        guard node.entity.attributesByName[GraphNativeIdentityPrototype.graphAttribute] != nil,
              node.entity.attributesByName[GraphNativeIdentityPrototype.nodeAttribute] != nil else { throw GraphStoreError.unsupportedLayout }
        node.setValue(id?.graphID.rawValue.uuidString, forKey: GraphNativeIdentityPrototype.graphAttribute)
        node.setValue(id?.rawValue.uuidString, forKey: GraphNativeIdentityPrototype.nodeAttribute)
    }
}
