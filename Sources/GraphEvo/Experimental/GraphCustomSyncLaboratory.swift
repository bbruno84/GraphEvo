import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// CS01-only local factory and wire codec. Never selected by public openers.
enum GraphCustomSyncLaboratory {
    static func model(_ version: Int) -> NSManagedObjectModel {
        let model = GraphRuntimeSchema.makeNativeModel()
        if version == 2 {
            let column = NSAttributeDescription(); column.name = "cs01Probe"; column.attributeType = .stringAttributeType; column.isOptional = true
            model.entitiesByName[ModelIdentifier.entityName]!.properties.append(column)
        }
        model.versionIdentifiers = ["GraphEvo.CS01.local.\(version)"]
        return model
    }
    static func version(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 1 }
        let values = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        for version in [1, 2] where values[NSStoreModelVersionIdentifiersKey] as? [String] == ["GraphEvo.CS01.local.\(version)"] { return version }
        throw GraphStoreError.unsupportedLayout
    }
    static func open(at url: URL, graphID: GraphID) async throws -> (GraphDatabase, GraphStore) {
        let v = try version(at: url)
        let schema = StoreSchema(identifier: "GraphEvo.CS01.local.\(v)", entityVersionHashes: model(v).entityVersionHashesByName,
            requiredModelVersionIdentifier: "GraphEvo.CS01.local.\(v)", makeModel: { model(v) })
        GraphValueTransformer.register()
        let db = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: schema, adapter: GraphNativeIdentityDatabaseAdapter.database)
        do {
            let ids = try await db.graphIDs()
            if ids.isEmpty {
                // Controlled lab bootstrap only. Native admission retains the writer gate.
                try await db.nativeOperation { native in
                    guard !(native is NSPersistentCloudKitContainer) else { throw GraphStoreError.unsupportedLayout }
                    try await native.performBackgroundTask { context in
                        try GraphNativeIdentityDatabaseAdapter.database.create(context, graphID)
                        try context.save()
                    }
                }
            } else { guard ids == [graphID] else { throw GraphStoreError.foreignGraph } }
            return (db, try await db.openGraph(graphID))
        } catch { try? await db.close(); throw error }
    }
    static func migrateClosed(at url: URL) throws {
        guard try version(at: url) == 1 else { throw GraphStoreError.unsupportedLayout }
        let backup = url.deletingLastPathComponent().appendingPathExtension("backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw GraphStoreError.unsupportedLayout }
        try FileManager.default.copyItem(at: url.deletingLastPathComponent(), to: backup)
        let next = url.deletingLastPathComponent().appendingPathComponent("migrated.sqlite")
        guard !FileManager.default.fileExists(atPath: next.path) else { throw GraphStoreError.unsupportedLayout }
        let source = model(1), target = model(2)
        let manager = NSMigrationManager(sourceModel: source, destinationModel: target)
        manager.usesStoreSpecificMigrationManager = false
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil,
            with: NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: target),
            toDestinationURL: next, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: target)
        try coordinator.replacePersistentStore(at: url, destinationOptions: nil, withPersistentStoreFrom: next, sourceOptions: nil, ofType: NSSQLiteStoreType)
    }
    private struct Row: Codable {
        let graph: GraphID; let node: GraphNodeID; let type: String; let kind: String
        let subjects: [GraphNodeID]; let objects: [GraphNodeID]
        let values: [String: Data]; let tags: Set<String>; let groups: Set<String>; let created: Date?
    }
    static func encode(_ record: GraphRecord) throws -> Data {
        let kind: String, subjects: [GraphNodeID], objects: [GraphNodeID]
        switch record.endpoints {
        case .entity: kind = "entity"; subjects = []; objects = []
        case .relationship(let a, let b): kind = "relationship"; subjects = a.map { [$0] } ?? []; objects = b.map { [$0] } ?? []
        case .action(let a, let b): kind = "action"; subjects = a.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }; objects = b.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Row(graph: record.id.graphID, node: record.id, type: record.type, kind: kind, subjects: subjects, objects: objects,
            values: record.properties.mapValues(GraphValueCodec.encode), tags: record.tags, groups: record.groups, created: record.createdDate))
    }
    static func decode(_ bytes: Data) throws -> GraphRecord {
        guard bytes.count <= 262_144 else { throw GraphStoreError.unsupportedLayout }
        let row = try JSONDecoder().decode(Row.self, from: bytes)
        guard row.graph == row.node.graphID else { throw GraphStoreError.foreignGraph }
        let endpoints: GraphEndpoints
        switch row.kind {
        case "entity": guard row.subjects.isEmpty, row.objects.isEmpty else { throw GraphStoreError.unsupportedLayout }; endpoints = .entity
        case "relationship": guard row.subjects.count <= 1, row.objects.count <= 1 else { throw GraphStoreError.unsupportedLayout }; endpoints = .relationship(subject: row.subjects.first, object: row.objects.first)
        case "action": endpoints = .action(subjects: Set(row.subjects), objects: Set(row.objects))
        default: throw GraphStoreError.unsupportedLayout
        }
        return try GraphRecord(id: row.node, type: row.type, endpoints: endpoints, properties: row.values.mapValues(GraphValueCodec.decode),
            tags: row.tags, groups: row.groups, createdDate: row.created)
    }
}
