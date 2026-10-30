import CoreData
import Foundation
import GraphEvoRuntime

/// PH01-only model/history reader. Never selected by public or coordinator openers.
enum GraphPersistentHistoryLaboratory {
    static let identifier = "GraphEvo.PH01.preserved.1"
    static let importAuthor = "GraphEvo.PH01.import"
    private static let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    static func model() -> NSManagedObjectModel {
        let model = GraphRuntimeSchema.makeNativeModel()
        for name in kinds {
            for key in [GraphNativeIdentityColumns.graphAttribute, GraphNativeIdentityColumns.nodeAttribute] {
                model.entitiesByName[name]!.attributesByName[key]!.preservesValueInHistoryOnDeletion = true
            }
        }
        model.versionIdentifiers = [identifier]
        return model
    }

    static func open(at url: URL) async throws -> GraphDatabase {
        let schema = StoreSchema(identifier: identifier, entityVersionHashes: model().entityVersionHashesByName,
                                 requiredModelVersionIdentifier: identifier, makeModel: { model() })
        GraphValueTransformer.register()
        return try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: schema,
                                            adapter: GraphNativeIdentityDatabaseAdapter.database)
    }

    struct Change: Sendable {
        let entity: String
        let object: String
        let operation: Int
        let properties: [String]
        let id: GraphNodeID?
        let owner: GraphNodeID?
        let preservedGraph: String?
        let preservedNode: String?
        var isNode: Bool { kinds.contains(entity) }
    }
    struct Transaction: Sendable {
        let number: Int64
        let author: String?
        let changes: [Change]
    }
    struct History: Sendable {
        let storeID: String
        let transactions: [Transaction]
        let token: Data?
    }
    enum Operation: String, Codable, Sendable { case save, delete }
    enum Failure: Error { case shape, identity, missingDeletionIdentity, unknownAuthor }

    private static func identity(_ graph: Any?, _ node: Any?) throws -> GraphNodeID? {
        guard let node else { return nil } // Hidden controls have no application node projection.
        guard let graph = graph as? String, let g = UUID(uuidString: graph),
              let node = node as? String, let n = UUID(uuidString: node) else { throw Failure.identity }
        return GraphNodeID(graphID: GraphID(rawValue: g), rawValue: n)
    }

    /// The native operation gate fixes the local writer cut for this bounded experiment.
    /// It does not establish a production history/data snapshot across external writers.
    static func history(_ database: GraphDatabase, after bytes: Data? = nil) async throws -> History {
        let token = try bytes.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0) }
        return try await database.nativeOperation { container in
            try await container.performBackgroundTask { context in
                guard container.persistentStoreCoordinator.persistentStores.count == 1,
                      let store = container.persistentStoreCoordinator.persistentStores.first,
                      let storeID = container.persistentStoreCoordinator.metadata(for: store)[NSStoreUUIDKey] as? String else { throw Failure.shape }
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.affectedStores = [store]
                guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction] else { throw Failure.shape }
                let graphKey = GraphNativeIdentityColumns.graphAttribute, nodeKey = GraphNativeIdentityColumns.nodeAttribute
                var output: [Transaction] = []
                for transaction in transactions {
                    var changes: [Change] = []
                    for change in transaction.changes ?? [] {
                        guard let name = change.changedObjectID.entity.name,
                              change.changedObjectID.persistentStore === store else { throw Failure.shape }
                        let tombstone = change.tombstone
                        let preservedGraph = tombstone?[graphKey] as? String, preservedNode = tombstone?[nodeKey] as? String
                        var id: GraphNodeID?, owner: GraphNodeID?
                        if change.changeType == .delete {
                            if kinds.contains(name) { id = try identity(preservedGraph, preservedNode) }
                        } else if let row = try? context.existingObject(with: change.changedObjectID) {
                            if kinds.contains(name) {
                                id = try identity(row.value(forKey: graphKey), row.value(forKey: nodeKey))
                            } else if row.entity.relationshipsByName["node"] != nil,
                                      let parent = row.value(forKey: "node") as? NSManagedObject {
                                owner = try identity(parent.value(forKey: graphKey), parent.value(forKey: nodeKey))
                            }
                        }
                        changes.append(Change(entity: name, object: change.changedObjectID.uriRepresentation().absoluteString,
                                              operation: change.changeType.rawValue, properties: (change.updatedProperties ?? []).map(\.name).sorted(),
                                              id: id, owner: owner, preservedGraph: preservedGraph, preservedNode: preservedNode))
                    }
                    output.append(Transaction(number: transaction.transactionNumber, author: transaction.author, changes: changes))
                }
                let next = try transactions.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) }
                return History(storeID: storeID, transactions: output, token: next ?? bytes)
            }
        }
    }

    /// Conservative fixture candidate reduction, not a production outbox or complete correlation proof.
    static func candidates(_ history: History) throws -> [GraphNodeID: Operation] {
        var result: [GraphNodeID: Operation] = [:]
        let identities = Dictionary(history.transactions.flatMap(\.changes).compactMap { change in
            change.id.map { (change.object, $0) }
        }, uniquingKeysWith: { first, _ in first })
        for transaction in history.transactions.sorted(by: { $0.number < $1.number }) {
            if transaction.author == importAuthor { continue }
            guard transaction.author == "GraphEvo.v2.local" else { throw Failure.unknownAuthor }
            var saves = Set<GraphNodeID>(), deletions = Set<GraphNodeID>()
            for change in transaction.changes {
                if change.isNode {
                    let id = change.id ?? identities[change.object]
                    if change.operation == NSPersistentHistoryChangeType.delete.rawValue {
                        guard change.preservedGraph != nil else { throw Failure.missingDeletionIdentity }
                        if let id { deletions.insert(id) }
                    } else if let id { saves.insert(id) }
                } else if let owner = change.owner { saves.insert(owner) }
            }
            for id in saves { result[id] = .save }
            for id in deletions { result[id] = .delete }
        }
        return result
    }

    static func importPatch(_ patch: GraphRecordPatch, into database: GraphDatabase) async throws {
        try await database.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                context.userInfo[StoreNativeContext.privateURLKey] = container.persistentStoreCoordinator.persistentStores.first?.url
                context.undoManager = nil
                context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
                context.transactionAuthor = importAuthor
                _ = try GraphNativeIdentityDatabaseAdapter.database.graph.patch(context, patch.id.graphID, patch)
                try context.save()
            }
        }
    }
}
