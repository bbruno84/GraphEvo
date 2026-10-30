import CoreData
import Foundation
import Testing
import GraphEvoModel
import GraphEvoStore
import GraphEvoRuntime
@testable import GraphEvo

private struct AdmissionItem: GraphModel {
    static let graphType = "admission.item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

private enum AdmissionAbort: Error { case rollback }
private struct LegacyReadableItem: GraphModel {
    static let graphType = AdmissionItem.graphType
    static let graphKind: GraphNodeKind = .entity
    static let graphDataFormat = try! GraphDataFormat(currentVersion: 2, acceptsUndeclared: true)
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

private struct StrictFormatItem: GraphModel {
    static let graphType = AdmissionItem.graphType
    static let graphKind: GraphNodeKind = .entity
    static let graphDataFormat = try! GraphDataFormat(currentVersion: 2)
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct GraphDataFormatAdmissionTests {
    private func refused<Value>(_ body: () async throws -> Value) async throws {
        do { _ = try await body(); Issue.record("A version-unaware persistence operation was admitted.") }
        catch GraphStoreError.dataFormatAdmissionRequired { }
    }

    /// Injects native metadata, modeling bytes already imported by a native producer.
    /// This is not a public writer, format converter or CloudKit acceptance test.
    private func nativeVersion(_ version: Int64?, node id: GraphNodeID, database: GraphDatabase) async throws {
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
                    let request = NSFetchRequest<NSManagedObject>(entityName: name)
                    request.predicate = NSPredicate(format: "%K == %@", GraphNativeIdentityColumns.nodeAttribute, id.rawValue.uuidString)
                    for row in try context.fetch(request) {
                        row.setValue(version.map(NSNumber.init(value:)), forKey: GraphNativeIdentityColumns.dataVersionAttribute)
                    }
                }
                try context.save()
            }
        }
    }

    @Test(arguments: [GraphDatabaseSchema.current, .nativeIdentity])
    func versionedInsertionRollsBackTheBatchAndSharedPreparationRefusesBeforeNativeWork(schema: GraphDatabaseSchema) async throws {
        let database = try await GraphDatabase.inMemory(schema: schema), graph = try await database.createGraph()
        let first = graph.makeNodeID(), declared = try GraphRecord(id: graph.makeNodeID(), type: AdmissionItem.graphType, dataVersion: 0)
        try await refused {
            try await graph.transaction { scope in
                try scope.insert(GraphRecord(id: first, type: AdmissionItem.graphType))
                try scope.insert(declared)
            }
        }
        #expect(try await graph.read { try $0.record(for: first) } == nil)
        try await refused { try await graph.insertShared([declared]) }
        #expect(try await graph.fetchAll(AdmissionItem.self).isEmpty)
        try await graph.close(); try await database.close()
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func nativeFormatsBlockReadsQueriesFilesAndMutationsWithoutReturningPartialResults(kind: Int, sqlite: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FormatAdmission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await sqlite ? GraphDatabase.open(at: folder.appendingPathComponent("Store.sqlite"), schema: .nativeIdentity)
            : GraphDatabase.inMemory(schema: .nativeIdentity)
        let graph = try await database.createGraph(), other = try await database.createGraph()
        let owner = graph.makeNodeID(), target = graph.makeNodeID(), otherID = other.makeNodeID()
        let endpoints: GraphEndpoints = kind == 0 ? .entity : kind == 1 ? .relationship(subject: owner, object: nil) : .action(subjects: [owner], objects: [])
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: AdmissionItem.graphType))
            try scope.insert(GraphRecord(id: target, type: "admission.dependency", endpoints: endpoints))
        }
        _ = try await other.transaction { try $0.insert(GraphRecord(id: otherID, type: AdmissionItem.graphType)) }
        let query = GraphQuery<AdmissionItem>(budget: try GraphQueryBudget(maximumCandidates: 64))
        let traversal = try GraphTraversal(from: [owner], via: .outgoing(nil), maximumDepth: 2, budget: query.request.budget)
        // Even declared zero needs admission. A later graph-scoped registry will narrow this resource-wide refusal.
        try await nativeVersion(0, node: target, database: database)
        try await refused { try await graph.read { try $0.record(for: owner) } }
        try await refused { try await graph.read { try $0.record(for: graph.makeNodeID()) } }
        try await refused { try await graph.fetchAll(AdmissionItem.self) }
        try await refused { try await graph.query(query) }
        try await refused { try await graph.count(query) }
        try await refused { try await graph.project(query, properties: []) }
        try await refused { try await graph.traverse(traversal) }
        try await refused { try await graph.read { try $0.attachments(ownedBy: owner) } }
        try await refused { try await graph.read { try $0.attachment(target) } }
        try await refused { try await graph.transaction { try $0.patch(GraphRecordPatch(id: owner, addingTags: ["edited"])) } }
        try await refused { try await graph.delete(owner) }
        try await refused { try await database.validateIntegrity(of: graph.id) }
        try await refused { try await other.read { try $0.record(for: otherID) } }
        // Status/access reduction uses only controls, even while data access is refused.
        #expect(try await graph.read { scope in
            try scope.withContext { context, _ in
                try GraphTypedStoreAdapter.controlRoot(context, id: graph.id).runtimeTypeIfPresent
            }
        } == GraphTypedStoreAdapter.rootType)
        try await nativeVersion(nil, node: target, database: database)
        #expect(try await graph.read { try $0.record(for: owner)?.tags.isEmpty } == true)
        #expect(try await graph.read { try $0.record(for: target)?.dataVersion } == nil)
        #expect(try await other.read { try $0.record(for: otherID)?.id } == otherID)
        try await graph.close(); try await other.close(); try await database.close()
    }

    @Test func observationReportsNativeFormatRefusalAndCanRecoverAfterExplicitProducerRepair() async throws {
        let database = try await GraphDatabase.inMemory(schema: .nativeIdentity), graph = try await database.createGraph()
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: AdmissionItem.graphType)) }
        try await nativeVersion(Int64.max, node: id, database: database)
        let observation = try await graph.observe(GraphQuery<AdmissionItem>(budget: try GraphQueryBudget(maximumCandidates: 32)))
        var iterator = observation.makeAsyncIterator()
        if case .failure(let error) = await iterator.next(), case GraphStoreError.dataFormatAdmissionRequired = error { }
        else { Issue.record("An incompatible native format was hidden from observation.") }
        try await nativeVersion(nil, node: id, database: database)
        observation.refresh()
        var recovered = false
        while let state = await iterator.next() {
            if case .value(let result) = state, result.items.map(\.id) == [id] { recovered = true; break }
        }
        #expect(recovered)
        observation.cancel(); try await graph.close(); try await database.close()
    }

    @Test func pendingVersionIsRefusedBeforeMalformedBodyAndRollbackPreservesTheSource() async throws {
        let database = try await GraphDatabase.inMemory(schema: .nativeIdentity), graph = try await database.createGraph()
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: AdmissionItem.graphType, properties: ["value": .integer(1)])) }
        do {
            try await graph.transaction { scope in
                try scope.withContext { context, _ in
                    let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                    let node = try #require(session.nodes[id])
                    node[dynamicMember: "value"] = Data([0xff])
                    node.node.setValue(NSNumber(value: 1), forKey: GraphNativeIdentityColumns.dataVersionAttribute)
                    do { _ = try scope.record(for: id); Issue.record("Pending version metadata was ignored.") }
                    catch GraphStoreError.dataFormatAdmissionRequired { }
                    throw AdmissionAbort.rollback
                }
            }
        } catch AdmissionAbort.rollback { }
        let retained = try await graph.read { try $0.record(for: id) }
        #expect(retained?.dataVersion == nil && retained?.properties["value"] == .integer(1))
        try await graph.close(); try await database.close()
    }

    @Test func readCompatibilityDoesNotAuthorizeATypedPatchOfAnUndeclaredRecord() async throws {
        let graph = try await GraphStore.inMemory(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: AdmissionItem.graphType)) }
        #expect(try await graph.fetch(id, as: LegacyReadableItem.self)?.id == id)
        await #expect(throws: GraphDataFormatError.unwritableVersion(nil)) {
            try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, addingTags: ["changed"]), as: LegacyReadableItem.self) }
        }
        #expect(try await graph.read { try $0.record(for: id)?.tags.isEmpty } == true)
        try await graph.close()
    }

    @Test func secondaryStoreWithUnroutedVersionedRowCannotBeIgnored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PairedFormatAdmission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let primary = folder.appendingPathComponent("Primary.sqlite"), secondary = folder.appendingPathComponent("Secondary.sqlite")
        let database = try await GraphDatabase.open(configuration: StoreConfiguration(location: .sqlite(primary), sharedStoreURL: secondary),
            schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphNativeIdentityDatabaseAdapter.database)
        let graph = try await database.createGraph(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: AdmissionItem.graphType)) }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let store = try #require(context.persistentStoreCoordinator?.persistentStores.first { $0.url?.lastPathComponent == "Secondary.sqlite" })
                let row = Entity("unrouted.native", graph: session.graph)
                context.assign(row.node, to: store)
                row.node.setValue(NSNumber(value: 7), forKey: GraphNativeIdentityColumns.dataVersionAttribute)
                try context.save()
            }
        }
        try await refused { try await graph.read { try $0.record(for: id) } }
        try await graph.close(); try await database.close()
    }

    @Test func nonRecordQueriesCheckTheModelFormatBeforeInterpretingProperties() async throws {
        let graph = try await GraphStore.inMemory(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: AdmissionItem.graphType, properties: ["rank": .integer(1)])) }
        let strict = GraphQuery<StrictFormatItem>(budget: try GraphQueryBudget(maximumCandidates: 32))
        await #expect(throws: GraphDataFormatError.unreadableVersion(nil)) { try await graph.query(strict) }
        await #expect(throws: GraphDataFormatError.unreadableVersion(nil)) { try await graph.count(strict) }
        await #expect(throws: GraphDataFormatError.unreadableVersion(nil)) { try await graph.project(strict, properties: ["rank"]) }
        await #expect(throws: GraphDataFormatError.unreadableVersion(nil)) { try await graph.aggregate(strict, .sum("rank")) }
        let compatible = GraphQuery<LegacyReadableItem>(budget: strict.request.budget)
        #expect(try await graph.count(compatible).value == 1)
        try await graph.close()
    }
}
