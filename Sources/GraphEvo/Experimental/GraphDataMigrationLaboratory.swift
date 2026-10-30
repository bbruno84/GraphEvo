import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Local-only M2a laboratory. Its model identifier prevents normal public opening
/// of versioned records before public data-format admission is implemented.
package actor GraphDataMigrationLaboratory {
    package static let modelIdentifier = "GraphEvo.dataMigration.lab.1"
    package let graphID: GraphID
    private let database: GraphDatabase
    private let graph: GraphStore

    private init(database: GraphDatabase, graph: GraphStore) {
        self.database = database; self.graph = graph; graphID = graph.id
    }

    package static func open(at url: URL, graphID: GraphID? = nil) async throws -> GraphDataMigrationLaboratory {
        let schema = StoreSchema(identifier: modelIdentifier,
            entityVersionHashes: GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
            requiredModelVersionIdentifier: modelIdentifier) {
                GraphValueTransformer.register()
                let model = GraphRuntimeSchema.makeNativeModel()
                model.versionIdentifiers = [modelIdentifier]
                return model
            }
        let database = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: schema,
                                                     adapter: GraphNativeIdentityDatabaseAdapter.database)
        do {
            let graph: GraphStore
            if let graphID { graph = try await database.openGraph(graphID) }
            else {
                guard try await database.graphIDs().isEmpty else { throw GraphDataMigrationError.invalidDefinition }
                graph = try await database.createGraph()
            }
            return GraphDataMigrationLaboratory(database: database, graph: graph)
        } catch { try await database.close(); throw error }
    }

    package func seed(_ rows: [GraphDataMigrationRow]) async throws {
        let id = graphID
        try await graph.transaction { scope in
            try scope.withContext { context, adapter in
                try Self.checkLocal(context)
                guard try GraphTypedStoreAdapter.Session(context, id, database: true).nodes.isEmpty else {
                    throw GraphDataMigrationError.invalidDefinition
                }
                for row in rows {
                    try adapter.insert(context, id, row.record)
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard let node = session.nodes[row.record.id] else { throw GraphStoreError.missingNode }
                    // Seed an archived source shape, including an actually absent date.
                    // Ordinary insertion's generated timestamp remains unchanged.
                    if row.record.createdDate == nil { node.node.setValue(nil, forKey: "createdDate") }
                    node.node.setValue(row.dataVersion.map(NSNumber.init(value:)), forKey: GraphNativeIdentityColumns.dataVersionAttribute)
                }
            }
        }
    }

    private static func checkLocal(_ context: NSManagedObjectContext) throws {
        guard !(context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer),
              let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
              coordinator.managedObjectModel.versionIdentifiers == [modelIdentifier],
              try GraphNativeIdentityColumns.validateModel(in: context) else { throw GraphStoreError.unsupportedLayout }
    }

    private static func rows(_ context: NSManagedObjectContext, graphID: GraphID, ids: [GraphNodeID]) throws -> [GraphDataMigrationRow] {
        try checkLocal(context)
        let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
        return try ids.map { id in
            guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            guard let node = session.nodes[id] else { throw GraphStoreError.missingNode }
            let version = (node.node.value(forKey: GraphNativeIdentityColumns.dataVersionAttribute) as? NSNumber)?.int64Value
            return try GraphDataMigrationRow(record: session.snapshot(node, id: id), dataVersion: version)
        }
    }

    private static func markerKey(_ intent: GraphMigrationIntent) -> String {
        GraphTypedStoreAdapter.prefix + "dataMigration." + intent.operationID.uuidString
    }

    package func adapter() async throws -> GraphDataMigrationAdapter {
        let graph = graph, id = graphID
        let destination = try await graph.read { scope in
            try scope.withContext { context, _ in
                try Self.checkLocal(context)
                let coordinator = context.persistentStoreCoordinator!
                let store = coordinator.persistentStores[0]
                guard let url = store.url,
                      let uuid = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String else {
                    throw GraphDataMigrationError.destinationMismatch
                }
                return url.standardizedFileURL.resolvingSymlinksInPath().path + ":" + uuid + ":" + id.rawValue.uuidString
            }
        }
        return GraphDataMigrationAdapter(destinationIdentity: destination, snapshot: { ids in
            try await graph.read { scope in try scope.withContext { context, _ in try Self.rows(context, graphID: id, ids: ids) } }
        }, publish: { publication, intent in
            guard publication.plan.destinationIdentity == destination, publication.plan.scope == id.rawValue.uuidString else {
                throw GraphDataMigrationError.destinationMismatch
            }
            return try await graph.transaction { scope in
                try scope.withContext { context, adapter in
                    let ids = publication.rows.map { $0.record.id }
                    let current = try Self.rows(context, graphID: id, ids: ids)
                    guard intent.resultFingerprint == publication.targetFingerprint,
                          try GraphDataMigrationPublication.fingerprint(current, maximumBytes: publication.maximumArtifactBytes) == publication.plan.sourceFingerprint else {
                        throw GraphDataMigrationError.sourceChanged
                    }
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard let root = session.root, root[dynamicMember: Self.markerKey(intent)] == nil else {
                        throw GraphDataMigrationError.reconciliationRequired
                    }
                    for (old, next) in zip(current, publication.rows) {
                        let record = next.record
                        guard old.record.id == record.id, old.record.type == record.type,
                              old.record.endpoints == record.endpoints, old.record.createdDate == record.createdDate else {
                            throw GraphDataMigrationError.invalidTransformation
                        }
                        var changes: [String: GraphPropertyChange] = [:]
                        for key in Set(old.record.properties.keys).union(record.properties.keys) where old.record.properties[key] != record.properties[key] {
                            changes[key] = record.properties[key].map(GraphPropertyChange.set) ?? .remove
                        }
                        _ = try adapter.patch(context, id, GraphRecordPatch(id: record.id, properties: changes,
                            addingTags: record.tags.subtracting(old.record.tags), removingTags: old.record.tags.subtracting(record.tags),
                            addingGroups: record.groups.subtracting(old.record.groups), removingGroups: old.record.groups.subtracting(record.groups)))
                        guard let node = session.nodes[record.id] else { throw GraphStoreError.missingNode }
                        node.node.setValue(next.dataVersion.map(NSNumber.init(value:)), forKey: GraphNativeIdentityColumns.dataVersionAttribute)
                    }
                    let actual = try Self.rows(context, graphID: id, ids: ids)
                    guard try GraphDataMigrationPublication.fingerprint(actual, maximumBytes: publication.maximumArtifactBytes) == publication.targetFingerprint else {
                        throw GraphDataMigrationError.invalidTransformation
                    }
                    root[dynamicMember: Self.markerKey(intent)] = try JSONEncoder().encode(intent)
                    return intent
                }
            }
        }, reconcile: { publication, intent in
            guard publication.plan.destinationIdentity == destination, publication.plan.scope == id.rawValue.uuidString else {
                throw GraphDataMigrationError.destinationMismatch
            }
            return try await graph.read { scope in
                try scope.withContext { context, _ in
                    let actual = try Self.rows(context, graphID: id, ids: publication.rows.map { $0.record.id })
                    let fingerprint = try GraphDataMigrationPublication.fingerprint(actual, maximumBytes: publication.maximumArtifactBytes)
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard let root = session.root else { throw GraphStoreError.missingGraph }
                    if let raw = root[dynamicMember: Self.markerKey(intent)] {
                        guard let bytes = raw as? Data, let marker = try? JSONDecoder().decode(GraphMigrationIntent.self, from: bytes),
                              marker == intent, marker.resultFingerprint == publication.targetFingerprint,
                              fingerprint == publication.targetFingerprint else { return .unresolved }
                        return .committed(marker)
                    }
                    // Only this isolated local adapter can prove the unchanged full preimage.
                    // Absence of a marker alone is never the classification.
                    return fingerprint == publication.plan.sourceFingerprint ? .notApplied : .unresolved
                }
            }
        })
    }

    /// Controlled local edit for stale-analysis/postcondition experiments, never a public version-aware writer.
    package func edit(_ patch: GraphRecordPatch) async throws {
        _ = try await graph.transaction { try $0.patch(patch) }
    }

    package func close() async throws { try await graph.close(); try await database.close() }
}
