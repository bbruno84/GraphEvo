import Foundation
import GraphEvo

private struct Profile: GraphModel {
    static let graphType = "example.profile.v1"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let displayName: String

    init(id: GraphNodeID, displayName: String) { self.id = id; self.displayName = displayName }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id
        displayName = try graphRecord.value(for: "display_name")
    }
    func graphRecord() throws -> GraphRecord {
        try GraphRecord(id: id, type: Self.graphType, properties: ["display_name": displayName.graphValue])
    }
}

@main struct ModelConsumer {
    static func main() async throws {
        let profile = Profile(id: .init(graphID: GraphID()), displayName: "Ada")
        let original = try await Task.detached { try GraphRecord(profile) }.value
        let future = try GraphEncodedValue(codec: "example.future", version: 7, data: Data([0, 255]))
        let enriched = try GraphRecordPatch(id: profile.id, properties: ["unknown": .set(.encoded(future))]).applying(to: original)
        let patch = try GraphRecordPatch(id: profile.id, properties: ["display_name": .set("Grace".graphValue)])
        let updated = try patch.applying(to: enriched)
        let decoded = try await MainActor.run { try updated.decoded(as: Profile.self) }
        guard decoded.id == profile.id, decoded.displayName == "Grace",
              updated.properties["unknown"] == .encoded(future) else {
            throw GraphModelError.invalidRecord("The model consumer did not preserve its values.")
        }
        print("GraphEvo Swift 6 model consumer passed")
    }
}
