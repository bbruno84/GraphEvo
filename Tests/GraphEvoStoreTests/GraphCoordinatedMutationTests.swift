import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoModel
@testable import GraphEvoRuntime
@testable import GraphEvoStore

@Suite(.timeLimit(.minutes(1))) struct GraphCoordinatedMutationTests {
    @Test func pendingOwnersCascadesCaughtRefusalsAndFollowingTransactionsUseTheCurrentView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
                                          adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let owner = GraphNodeID(graphID: graph.id), other = GraphNodeID(graphID: graph.id)
        let edge = GraphNodeID(graphID: graph.id), action = GraphNodeID(graphID: graph.id)
        let file = GraphNodeID(graphID: graph.id)
        let bytes = Data([1, 2, 3])
        let payload = try GraphAttachmentPayload(id: file, ownerID: edge, fileName: "sample.bin", contentType: "public.data", data: bytes)
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: "owner"))
            try scope.insert(GraphRecord(id: other, type: "other"))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: owner, object: other)))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [owner], objects: [other])))
            try scope.insert(payload.graphRecord(in: graph.id))
            #expect(throws: GraphStoreError.self) { try scope.insert(GraphRecord(id: other, type: "duplicate")) }
            _ = try scope.patch(.init(id: other, properties: ["value": .set(.integer(7))]))
            try scope.delete(owner)
            #expect(try scope.record(for: edge) == nil)
            #expect(try scope.record(for: file) == nil)
            #expect(try scope.record(for: action)?.endpoints == .action(subjects: [], objects: [other]))
        }
        #expect(try await graph.read { try $0.record(for: other)?.properties["value"] } == .integer(7))
        struct Abort: Error {}
        let rolledBack = GraphNodeID(graphID: graph.id)
        await #expect(throws: Abort.self) {
            try await graph.transaction { scope in
                try scope.insert(GraphRecord(id: rolledBack, type: "discarded"))
                throw Abort()
            }
        }
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: rolledBack, type: "kept")) }
        #expect(try await graph.read { try $0.record(for: rolledBack)?.type } == "kept")
        _ = try await graph.validateIntegrity()
        try await graph.close()
    }
}
