import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoRuntime

@Suite(.timeLimit(.minutes(2))) struct GraphHistoryIdentitySchemaTests {
    private let kinds = ["ManagedEntity", "ManagedRelationship", "ManagedAction"]
    private let identityKeys = ["ge2GraphID", "ge2NodeID"]

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("S03-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @Test func exactDeltaIsSixPreservationFlagsAndThreeEntityHashes() throws {
        let s02 = GraphNativeIdentityColumns.makeModel(indexed: true)
        s02.versionIdentifiers = ["GraphEvo.v2.schema.2"]
        let s03 = GraphRuntimeSchema.makeNativeModel(), other = GraphRuntimeSchema.makeNativeModel()
        #expect(s03.versionIdentifiers == [AnyHashable("GraphEvo.v2.schema.3")])
        #expect(s03.entityVersionHashesByName == other.entityVersionHashesByName)
        #expect(s02.entities.count == 12 && s03.entities.count == 12)
        var changed = 0
        for old in s02.entities {
            let entity = try #require(s03.entitiesByName[old.name!])
            #expect(old.properties.map(\.name) == entity.properties.map(\.name))
            #expect(old.indexes.map(\.name) == entity.indexes.map(\.name))
            for key in old.attributesByName.keys {
                let before = try #require(old.attributesByName[key]), after = try #require(entity.attributesByName[key])
                #expect(before.attributeType == after.attributeType)
                #expect(before.isOptional == after.isOptional)
                #expect(before.isTransient == after.isTransient)
                #expect(before.allowsExternalBinaryDataStorage == after.allowsExternalBinaryDataStorage)
                let preserve = kinds.contains(old.name!) && identityKeys.contains(key)
                #expect(!before.preservesValueInHistoryOnDeletion)
                #expect(after.preservesValueInHistoryOnDeletion == preserve)
                if preserve { changed += 1 }
            }
            #expect((old.versionHash != entity.versionHash) == kinds.contains(old.name!))
        }
        #expect(changed == 6)
        #expect(s03.entitiesByName["ManagedEntity"]?.attributesByName["ge2DataVersion"] == nil)
    }

    @Test(arguments: [false, true]) func partiallyPreservedIdentityModelsAreRefused(_ splitKinds: Bool) throws {
        let model = GraphRuntimeSchema.makeNativeModel()
        model.entitiesByName["ManagedEntity"]!.attributesByName["ge2GraphID"]!.preservesValueInHistoryOnDeletion = false
        if splitKinds { model.entitiesByName["ManagedEntity"]!.attributesByName["ge2NodeID"]!.preservesValueInHistoryOnDeletion = false }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.performAndWait {
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityColumns.validateModel(in: context) }
        }
    }

    private struct Deleted: Sendable, Equatable {
        let kind: String
        let graph: String
        let node: String
        let keys: Set<String>
    }
    private struct History: Sendable { let token: Data?; let deleted: [Deleted] }
    private func history(_ db: GraphDatabase, after data: Data? = nil) async throws -> History {
        return try await db.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let token = try data.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0) }
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.affectedStores = container.persistentStoreCoordinator.persistentStores
                let result = try #require(try context.execute(request) as? NSPersistentHistoryResult)
                let transactions = try #require(result.result as? [NSPersistentHistoryTransaction])
                var deleted: [Deleted] = []
                for change in transactions.flatMap({ $0.changes ?? [] }) where change.changeType == .delete {
                    guard ["ManagedEntity", "ManagedRelationship", "ManagedAction"].contains(change.changedObjectID.entity.name ?? "") else { continue }
                    let tombstone = try #require(change.tombstone)
                    deleted.append(Deleted(kind: try #require(change.changedObjectID.entity.name),
                                           graph: try #require(tombstone["ge2GraphID"] as? String),
                                           node: try #require(tombstone["ge2NodeID"] as? String),
                                           keys: Set(tombstone.keys.compactMap { $0 as? String })))
                }
                let next = try transactions.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) }
                return History(token: next ?? data, deleted: deleted.sorted { $0.node < $1.node })
            }
        }
    }

    @Test func selectedModelPreservesDeletedIdsIncludingAttachmentCascadeAndTokenReopen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Native.sqlite")
        let db = try await GraphDatabase.open(at: url, schema: .nativeIdentity), graph = try await db.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction {
            try $0.insert(GraphRecord(id: a, type: "owner", properties: ["private-payload": .string("not-a-tombstone")]))
            try $0.insert(GraphRecord(id: b, type: "child"))
            try $0.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b])))
        }
        let source = root.appendingPathComponent("content.bin"); try Data([0, 1, 255]).write(to: source)
        let file = try await graph.importAttachment(from: source, ownedBy: edge)
        let checkpoint = try #require(try await history(db).token)
        try await graph.delete(a)
        try await graph.delete(action)
        let recorded = try await history(db, after: checkpoint)
        #expect(Set(recorded.deleted.map(\.node)) == Set([a, edge, action, file.id].map { $0.rawValue.uuidString }))
        #expect(Set(recorded.deleted.map(\.kind)) == Set(kinds))
        for deletion in recorded.deleted {
            #expect(deletion.graph == graph.id.rawValue.uuidString)
            #expect(deletion.keys == Set(identityKeys))
        }
        #expect(try await graph.read { try $0.record(for: b) } != nil)
        try await graph.close(); try await db.close()
        let reopened = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        #expect(try await history(reopened, after: checkpoint).deleted == recorded.deleted)
        try await reopened.close()
    }

    @Test func previousS02IsRefusedBeforeLoadingAndRetainsReadableData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("S02.sqlite")
        let oldID = "GraphEvo.v2.schema.2"
        let make: @Sendable () -> NSManagedObjectModel = {
            let model = GraphNativeIdentityColumns.makeModel(indexed: true)
            model.versionIdentifiers = [oldID]; return model
        }
        let schema = StoreSchema(identifier: oldID, entityVersionHashes: make().entityVersionHashesByName,
                                 requiredModelVersionIdentifier: oldID, makeModel: make)
        let old = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: schema,
                                               adapter: GraphNativeIdentityDatabaseAdapter.database)
        let graph = try await old.createGraph(), node = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "retained", properties: ["value": .integer(42)])) }
        try await graph.close(); try await old.close()
        let before = try Data(contentsOf: url)
        let wal = URL(fileURLWithPath: url.path + "-wal"), beforeWAL = try? Data(contentsOf: wal)
        let absent = root.appendingPathComponent("NeverCreated.sqlite")
        for role in 0..<4 {
            do {
                let unexpected: GraphDatabase
                switch role {
                case 0: unexpected = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
                case 1: unexpected = try await GraphDatabase.openReadOnly(at: url, schema: .nativeIdentity)
                case 2: unexpected = try await GraphDatabase.openMirrored(at: url, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
                default: unexpected = try await GraphDatabase.openMirrored(privateStoreAt: absent, sharedStoreAt: url,
                    containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
                }
                try await unexpected.close(); Issue.record("S02 was admitted without explicit conversion.")
            } catch GraphStoreError.persistence(underlying: let cause) {
                guard let failure = cause as? StoreRuntimeError, case .incompatibleStore = failure else { throw cause }
            }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect((try? Data(contentsOf: wal)) == beforeWAL)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        let retained = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: schema,
                                                    adapter: GraphNativeIdentityDatabaseAdapter.database)
        let reader = try await retained.openGraph(graph.id)
        #expect(try await reader.read { try $0.record(for: node)?.properties["value"] } == .integer(42))
        try await reader.close(); try await retained.close()
    }
}
