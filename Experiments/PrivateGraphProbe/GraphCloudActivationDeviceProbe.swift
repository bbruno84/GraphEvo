import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// External signed-host probe of ordinary private discovery and replica recovery.
@available(iOS 17, macOS 14, *)
public actor GraphCloudActivationDeviceProbe {
    private enum Failure: Error { case failed, unsupportedStage }
    public init() {}
    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard stage == "private-roundtrip" else { throw Failure.unsupportedStage }
        let root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        func phase(_ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent("phase.txt"), options: .atomic) }
        let first = GraphContext.localFiles(), graphID = GraphID(rawValue: run)
        try await first.setForegroundActive(true)
        let graph = try await first.createGraph(id: graphID, at: root.appendingPathComponent("Owner.sqlite"))
        let note = graph.makeNodeID(), edge = graph.makeNodeID(), cover = Data(repeating: 51, count: 128 * 1024)
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "PrivateProbe.Note",
            properties: ["title": .string("Created locally")], attachments: ["cover": .init(data: cover)])) }
        let source = root.appendingPathComponent("Input.bin"), bytes = Data(repeating: 97, count: 256 * 1024)
        try bytes.write(to: source)
        let file = try await graph.importFile(from: source) { scope, file in
            try scope.insert(GraphRecord(id: edge, type: "PrivateProbe.File", endpoints: .relationship(subject: note, object: file.id)))
        }
        let attachment = try await graph.attachments(ownedBy: note).first!
        let zoneName = "GraphEvoPrivateProbe-" + run.uuidString
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: zoneName)
        let binding = GraphCloudBinding(zone: zone, graphID: graphID)
        let database = CKContainer(identifier: container).privateCloudDatabase
        try phase("connect owner")
        let ownerConfig = try GraphCloudConnectionConfiguration(containerIdentifier: container, environment: .development,
            directory: root.appendingPathComponent("OwnerCloud"))
        let cloud = try await first.connectCloud(using: ownerConfig)
        for _ in 0..<90 { if try await cloud.state == .ready { break }; try await Task.sleep(for: .seconds(1)) }
        guard try await cloud.state == .ready else { throw Failure.failed }
        try phase("bind and publish ordinary graph")
        try await cloud.bindPrivateGraph(graph, zoneName: zoneName)
        var observed = false
        for _ in 0..<60 {
            try await cloud.requestSynchronization()
            do {
                for nodeID in [note, edge, attachment.id, file.id] {
                    let native = try await database.record(for: GraphCloudNodeCodec.recordID(for: nodeID, binding: binding))
                    let decoded = try GraphCloudNodeCodec.decode(native, binding: binding)
                    guard decoded.record.id == nodeID else { throw Failure.failed }
                    if nodeID == file.id, let asset = native["asset"] as? CKAsset, let url = asset.fileURL {
                        guard SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw Failure.failed }
                    }
                }
                observed = true; break
            } catch { try await Task.sleep(for: .seconds(2)) }
        }
        guard observed else { throw Failure.failed }
        try phase("server independently verified; close owner before new session")
        try await graph.close(); try await cloud.close()
        let peer = GraphContext.localFiles()
        try await peer.setForegroundActive(true)
        let peerConfig = try GraphCloudConnectionConfiguration(containerIdentifier: container, environment: .development,
            directory: root.appendingPathComponent("FreshCatalogueCloud"))
        let peerCloud = try await peer.connectCloud(using: peerConfig)
        for _ in 0..<90 { if try await peerCloud.state == .ready { break }; try await Task.sleep(for: .seconds(1)) }
        guard try await peerCloud.state == .ready else { throw Failure.failed }
        try phase("discover ordinary private graph with fresh catalogue")
        let discovery = try await peerCloud.discoverPrivateGraphs(zoneNamePrefix: zoneName)
        guard discovery.issues.isEmpty, let reference = discovery.graphs.first,
              reference.id == graphID, reference.supportsFiles else { throw Failure.failed }
        try phase("recover complete empty private replica")
        let recovered = try await peerCloud.openPrivateGraph(reference, at: root.appendingPathComponent("Fresh.sqlite"))
        guard let record = try await recovered.read({ try $0.record(for: note) }),
              record.properties["title"] == .string("Created locally"), record.attachments["cover"]?.data == cover,
              try await recovered.read({ try $0.record(for: edge)?.endpoints }) == .relationship(subject: note, object: file.id),
              try await recovered.file(file.id) == file,
              try await recovered.withFileURL(file.id, { try Data(contentsOf: $0) }) == bytes,
              try await recovered.collectSyncChanges() == 0 else { throw Failure.failed }
        try await recovered.close()
        try phase("reopen recovered replica")
        let reopened = try await peerCloud.openPrivateGraph(reference, at: root.appendingPathComponent("Fresh.sqlite"))
        guard try await reopened.read({ try $0.record(for: note)?.attachments["cover"]?.data }) == cover else { throw Failure.failed }
        try await reopened.close(); try await peerCloud.close()
        try phase("complete")
        return ["Ordinary private graph published without v1 provenance.",
                "Server independently verified before owner closure.",
                "Fresh catalogue discovered exact GraphID and File capability.",
                "Empty replica recovered note, cover, File and relationship; zero outgoing feedback.",
                "Recovered replica reopened; all owners and connections closed.",
                "Same physical device with independent sessions; not a two-device same-account certificate."]
    }
}
