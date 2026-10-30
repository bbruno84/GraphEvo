import Foundation
import GraphEvo

struct Fixture: Decodable {
    let a: GraphID; let b: GraphID
    let rootA: GraphNodeID; let childA: GraphNodeID; let edgeA: GraphNodeID; let actionA: GraphNodeID
    let rootB: GraphNodeID; let childB: GraphNodeID; let edgeB: GraphNodeID; let actionB: GraphNodeID
    let marker: String
}
struct Envelope<Value: Decodable>: Decodable { let run: UUID; let value: Value }
@main struct Inspector {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let fixture = try JSONDecoder().decode(Envelope<Fixture>.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))).value
        for path in arguments.dropFirst(2) {
            let db = try await GraphDatabase.openReadOnly(at: URL(fileURLWithPath: path), schema: .nativeIdentity)
            let catalog = try await db.graphIDs()
            var verified: [String: Bool] = [:]
            for isA in [true, false] {
                let graphID = isA ? fixture.a : fixture.b, label = isA ? "A" : "B"
                guard catalog.contains(graphID) else { verified[label] = false; continue }
                let graph = try await db.openGraph(graphID)
                let root = isA ? fixture.rootA : fixture.rootB
                let child = isA ? fixture.childA : fixture.childB
                let edge = isA ? fixture.edgeA : fixture.edgeB
                let action = isA ? fixture.actionA : fixture.actionB
                let valid = try await graph.read { scope in
                    try scope.record(for: root)?.properties == ["graph": .string(label), "marker": .string(fixture.marker)]
                    && scope.record(for: child)?.properties == ["value": .integer(isA ? 101 : 202)]
                    && scope.record(for: edge)?.endpoints == .relationship(subject: root, object: child)
                    && scope.record(for: action)?.endpoints == .action(subjects: [root], objects: [child])
                }
                let count = try await db.validateIntegrity(of: graphID)
                verified[label] = valid && count == 4
                try await graph.close()
            }
            try await db.close()
            let label = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent + "/" + URL(fileURLWithPath: path).lastPathComponent
            let output: [String: Any] = ["resource": label, "completeA": verified["A"] ?? false, "completeB": verified["B"] ?? false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
