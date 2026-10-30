import Foundation
import Testing
@testable import GraphEvo

@Suite struct GraphCustomSyncLaboratoryTests {
    @Test func knownGraphIdentityWireAndClosedModelMigrationRemainLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CS01-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A/graph.sqlite"), graphID = GraphID()
        let (db, graph) = try await GraphCustomSyncLaboratory.open(at: url, graphID: graphID)
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "CS01.root", properties: ["label": .string("baseline"), "unknown": .null, "uuid": .uuid(UUID()), "bytes": .data(Data([0,255]))]))
            try scope.insert(GraphRecord(id: b, type: "CS01.child"))
            try scope.insert(GraphRecord(id: edge, type: "CS01.edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "CS01.action", endpoints: .action(subjects: [a], objects: [b])))
        }
        let before = try await graph.read { scope in try [a,b,edge,action].map { id -> GraphRecord in guard let row = try scope.record(for: id) else { throw GraphStoreError.missingNode }; return row } }
        for record in before { #expect(try GraphCustomSyncLaboratory.decode(GraphCustomSyncLaboratory.encode(record)) == record) }
        try await graph.close(); try await db.close()
        try GraphCustomSyncLaboratory.migrateClosed(at: url)
        #expect(try GraphCustomSyncLaboratory.version(at: url) == 2)
        let (newDB, newGraph) = try await GraphCustomSyncLaboratory.open(at: url, graphID: graphID)
        #expect(try await newDB.graphIDs() == [graphID])
        #expect(try await newDB.validateIntegrity(of: graphID) == 4)
        let after = try await newGraph.read { scope in try [a,b,edge,action].compactMap { try scope.record(for: $0) } }
        #expect(after == before)
        try await newGraph.close(); try await newDB.close()
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
    }
}
