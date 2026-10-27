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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-TypedConsumer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Graph.sqlite")
        let store = try await GraphStore.open(at: url)
        let graphID = store.id
        let profile = Profile(id: store.makeNodeID(), displayName: "Ada")
        try await store.insert(profile)
        let original = try await Task.detached { try await store.fetch(profile.id, as: Profile.self) }.value
        guard original?.displayName == "Ada" else { throw GraphStoreError.missingNode }
        let future = try GraphEncodedValue(codec: "example.future", version: 7, data: Data([0, 255]))
        try await store.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: profile.id, properties: ["unknown": .set(.encoded(future))]))
        }
        let patch = try GraphRecordPatch(id: profile.id, properties: ["display_name": .set("Grace".graphValue)])
        let updated = try await store.patch(patch, as: Profile.self)
        let name = await MainActor.run { updated.displayName }
        guard name == "Grace" else { throw GraphModelError.invalidValue }
        try await store.close()
        let reopened = try await GraphStore.open(at: url)
        let retained = try await reopened.read { try $0.record(for: profile.id) }
        guard reopened.id == graphID, retained?.id == profile.id,
              retained?.properties["unknown"] == .encoded(future) else { throw GraphStoreError.corruptIdentity }
        try await reopened.delete(profile.id)
        guard try await reopened.fetchAll(Profile.self).isEmpty else { throw GraphModelError.invalidValue }
        try await reopened.close()
        print("GraphEvo Swift 6 typed store consumer passed")
    }
}
