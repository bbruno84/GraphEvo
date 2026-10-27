import CoreData
import Foundation
import Testing
@testable import GraphEvo

@Suite(.timeLimit(.minutes(2))) struct GraphMetadataExperimentTests {
    @Test(arguments: [false, true]) func pendingChangesAcrossMetadataBatchesRetainEveryNodeKind(sqlite: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphMetadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await (sqlite ? GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite")) : GraphDatabase.inMemory())
        let graph = try await database.createGraph(), control = try await database.createGraph()
        let ids = (0..<129).map { _ in graph.makeNodeID() }, edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            for id in ids { try scope.insert(GraphRecord(id: id, type: "metadata.item")) }
            try scope.insert(GraphRecord(id: edge, type: "metadata.edge", endpoints: .relationship(subject: ids[0], object: ids[128])))
            try scope.insert(GraphRecord(id: action, type: "metadata.action", endpoints: .action(subjects: [ids[0]], objects: [ids[128]])))
            _ = try scope.patch(GraphRecordPatch(id: ids[128], properties: ["new": .set(.null)], addingTags: ["changed"], addingGroups: ["group"]))
            #expect(try scope.record(for: ids[128])?.properties["new"] == .null)
            #expect(try scope.record(for: edge)?.endpoints == .relationship(subject: ids[0], object: ids[128]))
            #expect(try scope.record(for: action)?.endpoints == .action(subjects: [ids[0]], objects: [ids[128]]))
        }
        let peer = try await database.openGraph(graph.id)
        #expect(try await peer.read { try $0.record(for: ids[128])?.tags } == ["changed"])
        try await peer.delete(ids[128])
        #expect(try await graph.read { try $0.record(for: edge) } == nil)
        #expect(try await graph.read { try $0.record(for: action)?.endpoints } == .action(subjects: [ids[0]], objects: []))
        #expect(try await control.read { try $0.record(for: GraphNodeID(graphID: control.id, rawValue: ids[0].rawValue)) } == nil)
        try await peer.close(); try await graph.close(); try await control.close(); try await database.close()
    }

    @Test func metadataCorruptionStillRejectsDuplicateMissingAndCrossGraphIdentity() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "A")); try scope.insert(GraphRecord(id: b, type: "B"))
        }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let target = try #require(session.nodes[b])
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = a.rawValue.uuidString
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = nil
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = b.rawValue.uuidString
                target[dynamicMember: GraphTypedStoreAdapter.graphKey] = GraphID().rawValue.uuidString
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
            }
        }
        #expect(try await graph.read { try $0.record(for: b)?.id } == b)
        try await graph.close(); try await database.close()
    }

    @Test func unrelatedGraphMalformedFormatsRemainIsolatedAndFreshReadsSeeRepairs() async throws {
        let database = try await GraphDatabase.inMemory(), a = try await database.createGraph(), b = try await database.createGraph()
        let first = a.makeNodeID(), second = b.makeNodeID()
        _ = try await a.transaction { try $0.insert(GraphRecord(id: first, type: "good")) }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: second, type: "other")) }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, b.id, database: true)
                let node = try #require(session.nodes[second])
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = "invalid"
                try context.save()
            }
        }
        #expect(try await a.read { try $0.record(for: first)?.id } == first)
        await #expect(throws: GraphStoreError.self) { try await b.read { try $0.record(for: second) } }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let facade = GraphTypedStoreAdapter.facade(context)
                let node = try #require(GraphTypedStoreAdapter.allNodes(facade).first { $0.runtimeTypeIfPresent == "other" })
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
                try context.save()
            }
        }
        #expect(try await b.read { try $0.record(for: second)?.id } == second)
        try await a.close(); try await b.close(); try await database.close()
    }
}
