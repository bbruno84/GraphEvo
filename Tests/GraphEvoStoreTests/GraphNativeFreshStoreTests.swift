import CoreData
import Foundation
import GraphEvoRuntime
import Testing
@testable import GraphEvo

private struct FreshNativeItem: GraphModel {
    static let graphType = "fresh.item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct GraphNativeFreshStoreTests {
    private func expectPreloadIncompatibility(_ body: @Sendable () async throws -> GraphDatabase) async throws {
        do {
            let opened = try await body()
            try await opened.close()
            Issue.record("An incompatible source was admitted for native loading.")
        } catch GraphStoreError.persistence(underlying: let cause) {
            guard let runtime = cause as? StoreRuntimeError, case .incompatibleStore = runtime else { throw cause }
        }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FreshNative-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func freshSQLiteCatalogFilesLeasesAndReopenUsePublicSchemaSelection() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Native.sqlite")
        let db = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        #expect(metadata[NSStoreModelVersionIdentifiersKey] as? [String] == ["GraphEvo.v2.schema.2"])
        #expect(try await db.graphIDs().isEmpty)
        let graph = try await db.createGraph(), second = try await db.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: FreshNativeItem.graphType, properties: ["value": .null]))
            try scope.insert(GraphRecord(id: b, type: FreshNativeItem.graphType))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b])))
        }
        let source = folder.appendingPathComponent("input.bin"); try Data([1,2,3]).write(to: source)
        let file = try await graph.importAttachment(from: source, ownedBy: edge)
        try await db.nativeOperation { native in
            await native.performBackgroundTask { context in
                for kind in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
                    #expect(context.persistentStoreCoordinator?.managedObjectModel
                        .entitiesByName[kind]?.attributesByName["ge2DataVersion"] == nil)
                }
            }
        }
        #expect(try await db.validateIntegrity(of: graph.id) == 5)
        #expect(try await db.validateIntegrity(of: second.id) == 0)
        let query = GraphQuery<FreshNativeItem>(budget: try GraphQueryBudget(maximumCandidates: 32)).where(.id(a))
        #expect(try await graph.query(query).items.first?.record.properties["value"] == .null)
        let lease = try await GraphDatabase.open(at: url, schema: .nativeIdentity), reader = try await lease.openGraph(graph.id)
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: url) }
        try await db.close(); try await graph.close(); try await second.close()
        #expect(try await reader.attachment(file.id)?.data == Data([1,2,3]))
        try await reader.close(); try await lease.close()
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: url) }
        let reopened = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        #expect(Set(try await reopened.graphIDs()) == [graph.id, second.id])
        let again = try await reopened.openGraph(graph.id)
        #expect(try await again.read { try $0.record(for: action)?.endpoints } == .action(subjects: [a], objects: [b]))
        #expect(try await again.attachment(file.id)?.metadata.ownerID == edge)
        #expect(try await reopened.validateIntegrity(of: graph.id) == 5)
        try await again.close(); try await reopened.close()
    }

    @Test func incompatibleCurrentAndHistoricalPrototypeStoresAreNotConvertedOrErased() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let oldURL = folder.appendingPathComponent("Current.sqlite")
        let current = try await GraphDatabase.open(at: oldURL), graph = try await current.createGraph(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "keep", properties: ["name": .string("old")])) }
        try await graph.close(); try await current.close()
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: oldURL, schema: .nativeIdentity) }
        // Model refusal occurs before native loading or any CloudKit service use.
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(at: oldURL, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        let sharedURL = folder.appendingPathComponent("NeverOpenedShared.sqlite")
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(privateStoreAt: oldURL, sharedStoreAt: sharedURL,
                                                 containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
        let old = try await GraphDatabase.open(at: oldURL), oldReader = try await old.openGraph(graph.id)
        #expect(try await oldReader.read { try $0.record(for: id)?.properties["name"] } == .string("old"))
        #expect(try await old.validateIntegrity(of: graph.id) == 1)
        try await oldReader.close(); try await old.close()

        let protoURL = folder.appendingPathComponent("Prototype.sqlite")
        let prototype = try await GraphNativeIdentityPrototype.openLab(at: protoURL, indexed: true)
        let protoGraph = try await prototype.createGraph(), protoID = protoGraph.makeNodeID()
        _ = try await protoGraph.transaction { try $0.insert(GraphRecord(id: protoID, type: "prototype")) }
        try await protoGraph.close(); try await prototype.close()
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: protoURL, schema: .nativeIdentity) }
        // Historical shape/protocol is rejected before mirroring starts.
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(at: protoURL, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        let protoShared = folder.appendingPathComponent("NeverOpenedPrototypeShared.sqlite")
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(privateStoreAt: protoURL, sharedStoreAt: protoShared,
                                                 containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        #expect(!FileManager.default.fileExists(atPath: protoShared.path))
        let neverOpenedPrimary = folder.appendingPathComponent("NeverOpenedPrimary.sqlite")
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(privateStoreAt: neverOpenedPrimary, sharedStoreAt: protoURL,
                                                 containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        #expect(!FileManager.default.fileExists(atPath: neverOpenedPrimary.path))
        let preserved = try await GraphNativeIdentityPrototype.openLab(at: protoURL, indexed: true), preservedGraph = try await preserved.openGraph(protoGraph.id)
        #expect(try await preservedGraph.read { try $0.record(for: protoID)?.id } == protoID)
        try await preservedGraph.close(); try await preserved.close()
    }

    @Test func corruptNativeProjectionFailsPointQueryIntegrityAndObservedStateThenRecovers() async throws {
        let db = try await GraphDatabase.inMemory(schema: .nativeIdentity), graph = try await db.createGraph(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: FreshNativeItem.graphType)) }
        try await db.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[id])
                node.node.setValue(nil, forKey: GraphNativeIdentityColumns.nodeAttribute)
                try context.save()
            }
        }
        let query = GraphQuery<FreshNativeItem>(budget: try GraphQueryBudget(maximumCandidates: 32))
        await #expect(throws: GraphStoreError.self) { try await graph.read { try $0.record(for: id) } }
        await #expect(throws: GraphStoreError.self) { try await graph.query(query) }
        await #expect(throws: GraphStoreError.self) { try await db.validateIntegrity(of: graph.id) }
        let observation = try await graph.observe(query)
        var iterator = observation.makeAsyncIterator()
        if case .failure(let error) = await iterator.next() { #expect(error is GraphStoreError) }
        else { Issue.record("An incomplete native projection must be visible as a failed refresh.") }
        try await db.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[id])
                // Simulated completion by the native producer; no library read performs this repair.
                node.node.setValue(id.rawValue.uuidString, forKey: GraphNativeIdentityColumns.nodeAttribute)
                try context.save()
            }
        }
        var recovered = false
        while let state = await iterator.next() {
            if case .value(let result) = state, result.items.map(\.id) == [id] { recovered = true; break }
        }
        #expect(recovered)
        #expect(try await db.validateIntegrity(of: graph.id) == 1)
        observation.cancel(); try await graph.close(); try await db.close()
    }

    private static func historicalModel(includingVersion: Bool, identifier: String) -> NSManagedObjectModel {
        let model = includingVersion ? GraphHistoricalVersionedModel.makeModel() : GraphNativeIdentityColumns.makeModel(indexed: true)
        model.versionIdentifiers = [identifier]
        return model
    }

    private func files(in folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test(arguments: [false, true], ["GraphEvo.nativeIdentity.alpha.2", "GraphEvo.v2.schema.1"])
    func oldAlphaAndSameShapeWrongMarkerAreRefusedWithoutChangingFiles(includingVersion: Bool, identifier: String) async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("OldAlpha.sqlite")
        let oldSchema = StoreSchema(identifier: identifier,
            entityVersionHashes: Self.historicalModel(includingVersion: includingVersion, identifier: identifier).entityVersionHashesByName,
            requiredModelVersionIdentifier: identifier) {
                Self.historicalModel(includingVersion: includingVersion, identifier: identifier)
            }
        let old = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: oldSchema,
                                               adapter: GraphNativeIdentityDatabaseAdapter.database)
        let graph = try await old.createGraph(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "preserve", properties: ["value": .integer(42)])) }
        try await graph.close(); try await old.close()
        let before = try files(in: folder)
        _ = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        let inspected = try files(in: folder)
        #expect(Set(inspected.keys) == Set(before.keys))
        // Even public metadata-only inspection can refresh SQLite's volatile SHM
        // coordination cache. Durable SQLite/WAL and every other artifact must match.
        let sharedMemory = url.lastPathComponent + "-shm"
        for (name, data) in before where name != sharedMemory { #expect(inspected[name] == data) }
        try await expectPreloadIncompatibility { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
        try await expectPreloadIncompatibility { try await GraphDatabase.openReadOnly(at: url, schema: .nativeIdentity) }
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(at: url, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        let missing = folder.appendingPathComponent("NeverCreated.sqlite")
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(privateStoreAt: url, sharedStoreAt: missing,
                                                containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        try await expectPreloadIncompatibility {
            try await GraphDatabase.openMirrored(privateStoreAt: missing, sharedStoreAt: url,
                                                containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
        }
        let after = try files(in: folder)
        #expect(Set(after.keys) == Set(before.keys))
        for (name, data) in before where name != sharedMemory {
            #expect(after[name] == data, "Durable source artifact changed: \(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let preserved = try await GraphDatabase.open(configuration: .init(location: .sqlite(url)), schema: oldSchema,
                                                     adapter: GraphNativeIdentityDatabaseAdapter.database)
        let view = try await preserved.openGraph(graph.id)
        #expect(try await view.read { try $0.record(for: id)?.properties["value"] } == .integer(42))
        try await view.close(); try await preserved.close()
    }

    @Test(arguments: [GraphDatabaseSchema.current, .nativeIdentity])
    func memorySchemaSelectionAndMissingGraphIntegrityHaveExplicitResults(schema: GraphDatabaseSchema) async throws {
        let db = try await GraphDatabase.inMemory(schema: schema)
        await #expect(throws: GraphStoreError.self) { try await db.validateIntegrity(of: GraphID()) }
        let graph = try await db.createGraph()
        #expect(try await db.validateIntegrity(of: graph.id) == 0)
        try await graph.close(); try await db.close()
    }
}
