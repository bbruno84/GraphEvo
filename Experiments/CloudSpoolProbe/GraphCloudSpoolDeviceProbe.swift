import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// External signed laboratory bridge. The shipping runtime is exported unchanged.
@available(iOS 17, macOS 14, *)
public actor GraphCloudSpoolDeviceProbe {
    private enum Failure: Error { case request, fixture, transport, inventory, spool }
    private struct ConsumerPayload: Codable { let name: String; let values: [Int] }
    private var manager: GraphContextManager!
    private var configuration: GraphCloudConfiguration!
    private var graphs: [GraphStore] = []
    private var bindings: [GraphCloudBinding] = []
    private var identity: GraphCloudSessionIdentity!
    private var root: URL!
    private var run: UUID!
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (stage == "account" && ["owner", "peer"].contains(replica)) ||
              (replica == "owner" && ["prepare-owner", "resume-owner", "verify-owner"].contains(stage)) ||
              (replica == "peer" && ["fetch-peer", "apply-peer", "verify-applied-peer"].contains(stage)) ||
              (replica == "fresh" && stage == "recover-fresh") else { throw Failure.request }
        self.run = run
        root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        manager = GraphContextManager(schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        configuration = GraphCloudConfiguration(containerIdentifier: container, environment: .development,
                                               directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(configuration)
        let account = try await manager.cloudSharingIdentity(configuration)
        identity = GraphCloudSessionIdentity(container: container, environment: .development, account: account)
        if stage == "account" {
            try Data(SHA256.hash(data: Data((run.uuidString + account).utf8)))
                .write(to: root.appendingPathComponent("account.digest"), options: .withoutOverwriting)
            return ["Salted account comparison retained privately; no graph or cloud mutation."]
        }
        let creating = ["prepare-owner", "fetch-peer", "recover-fresh"].contains(stage)
        for index in 0..<2 {
            let url = storeURL(index)
            if creating {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.fixture }
                graphs.append(try await manager.createGraph(id: graphID(index), at: url))
            } else { graphs.append(try await manager.openGraph(id: graphID(index), at: url)) }
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName,
                                      name: "GE2-Spool-" + run.uuidString + "-" + String(index))
            try await manager.bindCloudZone(zone, to: graphID(index), configuration: configuration)
            bindings.append(GraphCloudBinding(zone: zone, graphID: graphID(index)))
        }
        switch stage {
        case "prepare-owner":
            for index in 0..<2 {
                let records = try expected(index)
                try await graphs[index].transaction { scope in for record in records { try scope.insert(record) } }
            }
            try await publish(1)
            let frozen = try await graphs[0].prepareTransport(.init(identity: identity, route: bindings[0]))
            let assets = frozen.items.compactMap(\.assetReference)
            guard assets.filter({ $0.byteCount > 0 }).count == 3,
                  assets.reduce(0, { $0 + $1.byteCount }) == 30 * 1024 * 1024,
                  try await graphs[0].collectSyncChanges() == 6 else { throw Failure.spool }
            let bytes = try JSONEncoder().encode(frozen)
            guard bytes.count < 256 * 1024 else { throw Failure.spool }
            try bytes.write(to: root.appendingPathComponent("frozen.json"), options: .withoutOverwriting)
            try await snapshotOutgoing(frozen, saving: true)
            return ["40 MiB native attachment fixture plus empty file and independent control committed.",
                    "First 30 MiB attempt frozen with compact references; no main-graph send. Control published.",
                    "Ready for acknowledged-process termination before send; frozen bytes and references retained."]
        case "resume-owner":
            let retained = try JSONDecoder().decode(GraphCloudOutgoingBatch.self,
                from: Data(contentsOf: root.appendingPathComponent("frozen.json")))
            let reopened = try await graphs[0].prepareTransport(.init(identity: identity, route: bindings[0]))
            guard reopened == retained else { throw Failure.spool }
            try await snapshotOutgoing(reopened, saving: false)
            try await publish(0)
            try await verify()
            guard try outgoingFiles().isEmpty else { throw Failure.spool }
            return ["Frozen attempt and all owned files survived process restart exactly.",
                    "40 MiB published across bounded send windows; full server/local inventory, CKAssets and hashes agree.",
                    "Outgoing bodies retired after durable receipts; control unchanged; writer owners retained."]
        case "fetch-peer":
            guard try await local(0).isEmpty, try await local(1).isEmpty else { throw Failure.fixture }
            try await manager.fetchCloudChanges(.private, configuration: configuration)
            let inbox = try await manager.cloudInbox(configuration, limit: 100)
            guard inbox.filter({ $0.change.kind == .recordChanged }).count == 8,
                  inbox.compactMap({ $0.change.assetReference }).count == 6,
                  try await local(0).isEmpty, try await local(1).isEmpty else { throw Failure.inventory }
            let bytes = try JSONEncoder().encode(inbox)
            guard bytes.count < 256 * 1024,
                  try Data(contentsOf: configuration.directory.appendingPathComponent("session.json")).count < 256 * 1024 else { throw Failure.spool }
            try bytes.write(to: root.appendingPathComponent("inbox.json"), options: .withoutOverwriting)
            try incomingSnapshot().write(to: root.appendingPathComponent("incoming-files.json"), options: .withoutOverwriting)
            return ["Genuinely empty S04 peer fetched 40 MiB plus control/empty assets into owned spool, before import.",
                    "Inbox/session archives remain below 256 KiB; all references retained for restart before application."]
        case "apply-peer":
            let saved = try JSONDecoder().decode([GraphCloudInboxEntry].self,
                from: Data(contentsOf: root.appendingPathComponent("inbox.json")))
            let inbox = try await manager.cloudInbox(configuration, limit: 100)
            guard inbox == saved,
                  try incomingSnapshot() == Data(contentsOf: root.appendingPathComponent("incoming-files.json")),
                  try await local(0).isEmpty, try await local(1).isEmpty else { throw Failure.spool }
            try await apply()
            try await verify()
            try await checkEmptyInbox()
            return ["Durable inbox IDs/references and every file digest survived termination exactly.",
                    "Reopened inbox applied without a fetch; exact 40 MiB, empty file, complex payloads and control verified.",
                    "No outgoing feedback or duplicates; incoming spool empty after durable consumption."]
        case "verify-owner":
            try await manager.fetchCloudChanges(.private, configuration: configuration)
            try await apply(); try await verify(); try await checkEmptyInbox()
            guard try outgoingFiles().isEmpty else { throw Failure.spool }
            return ["Original owner reopened and independently verified complete server/local state and empty queues."]
        case "verify-applied-peer":
            let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apply-peer.report.json"))) as? [String: Any]
            guard prior?["status"] as? String == "failed" else { throw Failure.request }
            // Do not replay fetch/import. A complete persisted replica is a prerequisite.
            try await verify(); try await checkEmptyInbox()
            return ["Read-only continuation verified already imported exact data after the original global-queue assertion failure.",
                    "No fetch or import replay; this fixture's inbox and asset spool are empty; unrelated zone events preserved."]
        case "recover-fresh":
            try await manager.fetchCloudChanges(.private, configuration: configuration)
            try await apply(); try await verify(); try await checkEmptyInbox()
            return ["Second genuinely empty replica recovered all 40 MiB and exact IDs/payloads/control from CloudKit.",
                    "No store copying, duplicate nodes, feedback or retained incoming files."]
        default: throw Failure.request
        }
    }

    private func uuid(_ salt: UInt8) -> UUID {
        var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes)
    }
    private func graphID(_ index: Int) -> GraphID { GraphID(rawValue: uuid(UInt8(index))) }
    private func nodeID(_ index: Int, _ salt: UInt8) -> GraphNodeID { .init(graphID: graphID(index), rawValue: uuid(salt)) }
    private func storeURL(_ index: Int) -> URL { root.appendingPathComponent("Graph-" + String(index) + ".sqlite") }
    private func expected(_ index: Int) throws -> [GraphRecord] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try GraphEncodedValue(codec: "SpoolProbe.Payload", version: 1,
            data: encoder.encode(ConsumerPayload(name: "fixture", values: [1, 2, 3])))
        let owner = try GraphRecord(id: nodeID(index, 32), type: "SpoolProbe.Owner",
            properties: ["array": .array([.integer(1), .string("two")]),
                         "dictionary": .object(["key": .boolean(true)]), "codable": .encoded(encoded)],
            createdDate: Date(timeIntervalSince1970: 1))
        var records = [owner]
        for number in 0..<(index == 0 ? 5 : 1) {
            let count = index == 1 ? 512 : (number == 4 ? 0 : 10 * 1024 * 1024)
            let payload = try GraphAttachmentPayload(id: nodeID(index, UInt8(64 + number)), ownerID: owner.id,
                fileName: "fixture-" + String(number) + ".bin", contentType: "public.data",
                data: Data(repeating: UInt8(number + 11), count: count))
            guard var object = try JSONSerialization.jsonObject(with: encoder.encode(payload.content.metadata)) as? [String: Any] else { throw Failure.fixture }
            object["revision"] = uuid(UInt8(128 + number + index * 8)).uuidString
            let metadata = try JSONDecoder().decode(GraphAttachmentMetadata.self, from: JSONSerialization.data(withJSONObject: object))
            records.append(try GraphAttachmentPayload(metadata: metadata, data: payload.content.data).graphRecord())
        }
        return records
    }
    private func local(_ index: Int) async throws -> [GraphNodeID: GraphRecord] {
        let id = graphID(index)
        return try await graphs[index].read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                return try Dictionary(uniqueKeysWithValues: session.nodes.keys.map { ($0, try scope.record(for: $0)!) })
            }
        }
    }
    private func publish(_ index: Int) async throws {
        for _ in 0..<4 {
            guard try await graphs[index].collectSyncChanges() > 0 else { return }
            let report = try await manager.sendCloudChanges(for: graphID(index), configuration: configuration)
            if let error = report.transportError { throw error }
            guard report.succeeded > 0, report.failures.isEmpty, !report.pendingRetry, !report.cleanupPending,
                  report.resolvedConflicts == 0 else { throw Failure.transport }
        }
        guard try await graphs[index].collectSyncChanges() == 0 else { throw Failure.transport }
    }
    private func apply() async throws {
        for index in 0..<2 { _ = try await manager.applyCloudInbox(for: graphID(index), configuration: configuration) }
    }
    private func verify() async throws {
        let database = CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase
        for index in 0..<2 {
            let local = try await local(index), wanted = try expected(index)
            guard Set(local.keys) == Set(wanted.map(\.id)), try await graphs[index].collectSyncChanges() == 0 else { throw Failure.inventory }
            for record in wanted {
                guard let actual = local[record.id], actual.properties == record.properties,
                      actual.type == record.type, actual.endpoints == record.endpoints else { throw Failure.fixture }
            }
            let zone = bindings[index].zone
            let page = try await database.recordZoneChanges(inZoneWith: .init(zoneName: zone.name, ownerName: zone.owner), since: nil, resultsLimit: 100)
            guard !page.moreComing, page.modificationResultsByID.count == wanted.count else { throw Failure.inventory }
            for result in page.modificationResultsByID.values {
                let native = try result.get().record
                let decoded = try GraphCloudNodeCodec.decode(native, binding: bindings[index])
                guard native.recordChangeTag?.isEmpty == false, local[decoded.record.id] == decoded.record else { throw Failure.inventory }
                if decoded.record.type == GraphAttachmentPayload.graphType {
                    guard native["asset"] is CKAsset else { throw Failure.fixture }
                    _ = try GraphAttachmentPayload(graphRecord: decoded.record)
                }
            }
        }
    }
    private func snapshotOutgoing(_ batch: GraphCloudOutgoingBatch, saving: Bool) async throws {
        guard let root = batch.assetRoot else { throw Failure.spool }
        let spool = try GraphCloudAssetSpool(root: root)
        var hashes: [String: String] = [:]
        for reference in batch.items.compactMap(\.assetReference) {
            let data = try await spool.read(reference, role: .outgoing, identity: identity,
                binding: bindings[0], recordName: reference.recordName, storeID: reference.storeID, epoch: reference.epoch)
            hashes[reference.file.uuidString] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(hashes), path = self.root.appendingPathComponent("outgoing-files.json")
        if saving { try bytes.write(to: path, options: .withoutOverwriting) }
        else { guard bytes == (try Data(contentsOf: path)) else { throw Failure.spool } }
    }
    private func files(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { throw Failure.spool }
        return try iterator.compactMap { item in
            guard let url = item as? URL, UUID(uuidString: url.lastPathComponent) != nil,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }
    private func outgoingFiles() throws -> [URL] { try files(root.appendingPathComponent("GraphEvoCloudAssets")) }
    private func incomingSnapshot() throws -> Data {
        var hashes: [String: String] = [:]
        for url in try files(configuration.directory.appendingPathComponent("GraphEvoCloudAssets")) {
            hashes[url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent] =
                SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        guard hashes.count == 6 else { throw Failure.spool }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(hashes)
    }
    private func checkEmptyInbox() async throws {
        let status = try await manager.cloudStatus(configuration)
        let zones = Set(bindings.map(\.zone))
        let inbox = try await manager.cloudInbox(configuration, limit: configuration.maximumEvents)
        guard status.failure == nil, inbox.allSatisfy({ !zones.contains($0.change.zone) }), status.outgoingReceiptCount == 0,
              try files(configuration.directory.appendingPathComponent("GraphEvoCloudAssets")).isEmpty else { throw Failure.spool }
    }
}
