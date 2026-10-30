import Foundation
import GraphEvo

private struct Fixture: Codable {
    let a: GraphID; let b: GraphID
    let rootA: GraphNodeID; let childA: GraphNodeID; let edgeA: GraphNodeID; let actionA: GraphNodeID
    let rootB: GraphNodeID; let childB: GraphNodeID; let edgeB: GraphNodeID; let actionB: GraphNodeID
    let marker: String
}
private struct Envelope<Value: Codable>: Codable { let run: UUID; let value: Value }

/// Two brand-new local stacks: CloudKit is never configured in this control.
@main struct LocalControl {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        let dbA = try await GraphDatabase.open(at: directory.appendingPathComponent("A/private.sqlite"), schema: .nativeIdentity)
        let dbB = try await GraphDatabase.open(at: directory.appendingPathComponent("B/private.sqlite"), schema: .nativeIdentity)
        let a = try await dbA.createGraph(), b = try await dbB.createGraph(), run = UUID()
        let f = Fixture(a: a.id, b: b.id, rootA: a.makeNodeID(), childA: a.makeNodeID(), edgeA: a.makeNodeID(), actionA: a.makeNodeID(),
            rootB: b.makeNodeID(), childB: b.makeNodeID(), edgeB: b.makeNodeID(), actionB: b.makeNodeID(), marker: run.uuidString)
        for isA in [true, false] {
            let graph = isA ? a : b, root = isA ? f.rootA : f.rootB, child = isA ? f.childA : f.childB
            let edge = isA ? f.edgeA : f.edgeB, action = isA ? f.actionA : f.actionB, label = isA ? "A" : "B"
            try await graph.transaction { scope in
                try scope.insert(GraphRecord(id: root, type: "GI01.root", properties: ["graph": .string(label), "marker": .string(f.marker)]))
                try scope.insert(GraphRecord(id: child, type: "GI01.child", properties: ["value": .integer(isA ? 101 : 202)]))
                try scope.insert(GraphRecord(id: edge, type: "GI01.edge", endpoints: .relationship(subject: root, object: child)))
                try scope.insert(GraphRecord(id: action, type: "GI01.action", endpoints: .action(subjects: [root], objects: [child])))
            }
        }
        guard try await dbA.graphIDs() == [f.a], try await dbB.graphIDs() == [f.b] else { throw GraphStoreError.corruptIdentity }
        try await a.close(); try await b.close(); try await dbA.close(); try await dbB.close()
        try JSONEncoder().encode(Envelope(run: run, value: f)).write(to: directory.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
        print("PASS separate local catalogs before close; two closed local stores prepared for independent Core Data reads.")
    }
}
