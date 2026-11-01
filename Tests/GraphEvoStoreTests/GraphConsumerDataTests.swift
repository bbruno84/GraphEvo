import Foundation
import Testing
@testable import GraphEvo

private enum ConsumerDataError: Error { case unsupportedVersion }

private struct ConsumerDocument: GraphModel {
    static let graphType = "consumer.document"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

private struct CurrentDocument: GraphModel {
    static let graphType = ConsumerDocument.graphType
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws {
        guard graphRecord.properties["appDataVersion"] == .integer(2) else {
            throw ConsumerDataError.unsupportedVersion
        }
        record = graphRecord
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct GraphConsumerDataTests {
    @Test(arguments: [GraphDatabaseSchema.current, .nativeIdentity])
    func mixedApplicationVersionsRemainOrdinaryQueryablePersistentValues(schema: GraphDatabaseSchema) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConsumerData-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Graph.sqlite")
        let db = try await GraphDatabase.open(at: url, schema: schema)
        let graph = try await db.createGraph(), control = try await db.createGraph()
        let legacy = graph.makeNodeID(), current = graph.makeNodeID(), future = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: legacy, type: ConsumerDocument.graphType))
            try scope.insert(GraphRecord(id: current, type: ConsumerDocument.graphType,
                properties: ["appDataVersion": .integer(2), "name": .string("current")]))
            try scope.insert(GraphRecord(id: future, type: ConsumerDocument.graphType,
                properties: ["appDataVersion": .integer(99), "unknown": .data(Data([0, 255]))]))
        }
        let query = GraphQuery<ConsumerDocument>(budget: try GraphQueryBudget(maximumCandidates: 32))
        #expect(try await graph.count(query).value == 3)
        #expect(try await graph.project(query, properties: ["appDataVersion"]).rows.count == 3)
        #expect(try await graph.query(query.where(.property("appDataVersion", .equal, .integer(99)))).items.map(\.id) == [future])
        #expect(try await control.fetchAll(ConsumerDocument.self).isEmpty)
        await #expect(throws: ConsumerDataError.self) { try await graph.fetch(future, as: CurrentDocument.self) }
        #expect(try await graph.fetch(current, as: CurrentDocument.self)?.id == current)
        #expect(try await graph.read { try $0.record(for: future)?.properties["unknown"] } == .data(Data([0, 255])))
        let observation = try await graph.observe(query)
        var iterator = observation.makeAsyncIterator()
        if case .value(let result) = await iterator.next() { #expect(result.items.count == 3) }
        else { Issue.record("Raw model observation must not classify application versions.") }
        observation.cancel()
        try await graph.close(); try await control.close(); try await db.close()
        let reopened = try await GraphDatabase.open(at: url, schema: schema)
        let reader = try await reopened.openGraph(graph.id)
        #expect(try await reader.fetchAll(ConsumerDocument.self).count == 3)
        #expect(try await reader.read { try $0.record(for: legacy)?.properties["appDataVersion"] } == nil)
        #expect(try await reader.read { try $0.record(for: future)?.properties["appDataVersion"] } == .integer(99))
        try await reader.close(); try await reopened.close()
    }

    @Test func consumerValidationRejectsTypedPatchWithoutBlockingGenericEdits() async throws {
        let db = try await GraphDatabase.inMemory(schema: .nativeIdentity), graph = try await db.createGraph()
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ConsumerDocument.graphType,
            properties: ["appDataVersion": .integer(99), "name": .string("keep")])) }
        let patch = try GraphRecordPatch(id: id, properties: ["name": .set(.string("edit"))])
        await #expect(throws: ConsumerDataError.self) { try await graph.patch(patch, as: CurrentDocument.self) }
        #expect(try await graph.read { try $0.record(for: id)?.properties["name"] } == .string("keep"))
        let query = GraphQuery<CurrentDocument>(budget: try GraphQueryBudget(maximumCandidates: 16))
        // Count and projection inspect graph values; only materialization invokes the consumer.
        #expect(try await graph.count(query).value == 1)
        await #expect(throws: ConsumerDataError.self) { try await graph.query(query) }
        let raw = try await graph.transaction { try $0.patch(patch) }
        #expect(raw.properties["appDataVersion"] == .integer(99))
        #expect(raw.properties["name"] == .string("edit"))
        try await graph.close(); try await db.close()
    }
}
