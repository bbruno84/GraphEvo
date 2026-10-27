import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoModel

@Suite struct GraphQueryMaterializationTests {
    private struct Item: GraphModel {
        static let graphType = "matrix.item"
        static let graphKind: GraphNodeKind = .entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) throws { record = graphRecord }
        func graphRecord() throws -> GraphRecord { record }
    }
    private func budget() throws -> GraphQueryBudget { try GraphQueryBudget(maximumCandidates: 100, maximumPropertyBytes: 16 * 1024) }

    @Test func completeModelsAndExplicitDependenciesStayChargedButUnrelatedBodiesDoNot() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let owner = graph.makeNodeID(), target = graph.makeNodeID(), edge = graph.makeNodeID()
        let payload = try GraphAttachmentPayload(id: target, ownerID: owner, fileName: "file.bin", contentType: "public.data", data: Data(repeating: 173, count: 1024 * 1024))
        let file = try payload.graphRecord()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, properties: ["rank": .integer(7), "optional": .null, "unrequested": .string("must survive full models")]))
            try scope.insert(file)
            try scope.insert(GraphRecord(id: edge, type: "matrix.edge", endpoints: .relationship(subject: owner, object: target)))
        }
        let query = GraphQuery<Item>(budget: try budget()).where(.property("rank", .equal, .integer(7)))
        #expect(try await graph.query(query).items.first?.record.properties["unrequested"] == .string("must survive full models"))
        #expect(try await graph.count(query).value == 1)
        #expect(try await graph.project(query, properties: ["rank", "optional", "missing"]).rows.first?.values == ["rank": .integer(7), "optional": .null])
        #expect(try await graph.aggregate(query, .sum("rank")).value == .integer(7))
        let traversal = try GraphTraversal(from: [owner], via: .outgoing("matrix.edge"), maximumDepth: 1, budget: budget())
        #expect(try await graph.traverse(traversal).visits.map(\.id) == [target])
        let fileQuery = GraphQuery<GraphAttachmentPayload>(budget: try budget())
        #expect(try await graph.count(fileQuery).value == 1)
        await #expect(throws: GraphQueryError.self) { try await graph.query(fileQuery) }
        await #expect(throws: GraphQueryError.self) { try await graph.project(fileQuery, properties: ["content"]) }
        let related = GraphQuery<Item>(budget: try budget()).where(.related(.outgoing("matrix.edge"), matching: .exists("content")))
        await #expect(throws: GraphQueryError.self) { try await graph.count(related) }
        let relatedID = GraphQuery<Item>(budget: try budget()).where(.related(.outgoing("matrix.edge"), matching: .id(target)))
        #expect(try await graph.count(relatedID).value == 1)
        try await graph.close(); try await database.close()
    }

    @Test func unusedCorruptBodiesAreNotCertifiedAndRequestedMissingEncodedValuesStillFail() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let owner = graph.makeNodeID()
        let payload = try GraphAttachmentPayload(id: graph.makeNodeID(), ownerID: owner, fileName: "file.bin", contentType: "public.data", data: Data([1, 2]))
        let file = try payload.graphRecord()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(file)
        }
        let query = GraphQuery<Item>(budget: try budget())
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[payload.id])
                node[dynamicMember: "content"] = Data([0])
                let adapter = GraphTypedStoreAdapter.database.graph
                let execute = try #require(adapter.query)
                #expect(try execute(context, graph.id, query.request).records.map(\.id) == [owner])
                #expect(throws: (any Error).self) { try session.record(payload.id) }
                #expect(throws: (any Error).self) { try GraphTypedStoreAdapter.mirroringRoot(context, id: graph.id) }
                let item = try #require(session.nodes[owner])
                item[dynamicMember: "rank"] = nil
                #expect(throws: GraphStoreError.self) { try execute(context, graph.id, query.request) }
            }
        }
        try await graph.close(); try await database.close()
    }
}
