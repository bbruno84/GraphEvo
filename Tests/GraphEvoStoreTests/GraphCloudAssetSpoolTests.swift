import Foundation
import Testing
@testable import GraphEvoStore
@testable import GraphEvoModel

@Suite struct GraphCloudAssetSpoolTests {
    @Test func durableReferenceSurvivesReopenAndRejectsTamperingOrWrongRoute() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvoSpoolTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("GraphEvoCloudAssets")
        let spool = try GraphCloudAssetSpool(root: root)
        let identity = GraphCloudSessionIdentity(container: "iCloud.fixture", environment: .development, account: "fixture")
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: GraphID())
        let payload = Data(repeating: 0x31, count: 128 * 1024 + 1)
        let reference = try await spool.stage(payload, role: .incoming, namespace: UUID(), identity: identity,
                                              binding: binding, recordName: "node.fixture")
        let encoded = try JSONEncoder().encode(reference)
        let restored = try JSONDecoder().decode(GraphCloudAssetReference.self, from: encoded)
        #expect(try await GraphCloudAssetSpool(root: root).read(restored, role: .incoming, identity: identity,
                                                binding: binding, recordName: "node.fixture") == payload)
        let wrong = GraphCloudBinding(zone: binding.zone, graphID: GraphID())
        await #expect(throws: GraphCloudError.invalidState) {
            try await spool.read(restored, role: .incoming, identity: identity, binding: wrong, recordName: "node.fixture")
        }
        let path = root.appendingPathComponent(reference.namespace.uuidString).appendingPathComponent(reference.file.uuidString)
        let handle = try FileHandle(forWritingTo: path)
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: GraphCloudError.invalidState) {
            try await spool.read(restored, role: .incoming, identity: identity, binding: binding, recordName: "node.fixture")
        }
    }

    @Test func unknownFormatAndOversizeBodyAreRefused() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvoSpoolTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let spool = try GraphCloudAssetSpool(root: base.appendingPathComponent("GraphEvoCloudAssets"))
        let identity = GraphCloudSessionIdentity(container: "iCloud.fixture", environment: .development, account: "fixture")
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: GraphID())
        let ref = try await spool.stage(Data(), role: .incoming, namespace: UUID(), identity: identity,
                                        binding: binding, recordName: "node.fixture")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ref)) as? [String: Any])
        object["format"] = 2
        let future = try JSONDecoder().decode(GraphCloudAssetReference.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: GraphCloudError.invalidState) {
            try future.validate(role: .incoming, identity: identity, binding: binding, recordName: "node.fixture")
        }
        await #expect(throws: GraphCloudError.inboxLimit) {
            try await spool.stage(Data(repeating: 1, count: GraphAttachmentPayload.maximumByteCount + 1),
                                  role: .incoming, namespace: UUID(), identity: identity, binding: binding,
                                  recordName: "node.fixture")
        }
    }

    @Test func terminalPurgeCanResumeAfterRemovingItsLastMarker() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvoSpoolPurge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = GraphCloudAssetSpool.outgoingRoot(storeURL: base.appendingPathComponent("Graph.sqlite"), storeID: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spool = try GraphCloudAssetSpool(root: root)
        try spool.removeOwnedRoot()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try spool.removeOwnedRoot()
    }

    @Test func reconciliationPrunesOnlyUnreferencedOwnedFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvoSpoolTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let spool = try GraphCloudAssetSpool(root: base.appendingPathComponent("GraphEvoCloudAssets"))
        let identity = GraphCloudSessionIdentity(container: "iCloud.fixture", environment: .development, account: "fixture")
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: GraphID())
        let retained = try await spool.stage(Data([1, 2]), role: .incoming, namespace: UUID(),
            identity: identity, binding: binding, recordName: "node.one")
        let orphan = try await spool.stage(Data([3, 4]), role: .incoming, namespace: UUID(),
            identity: identity, binding: binding, recordName: "node.two")
        try await spool.reconcile(retaining: [retained])
        #expect(try await spool.read(retained, role: .incoming, identity: identity,
                                     binding: binding, recordName: "node.one") == Data([1, 2]))
        await #expect(throws: GraphCloudError.invalidState) {
            try await spool.read(orphan, role: .incoming, identity: identity,
                                 binding: binding, recordName: "node.two")
        }
    }
}
