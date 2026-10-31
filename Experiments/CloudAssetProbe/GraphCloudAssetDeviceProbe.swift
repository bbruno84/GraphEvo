import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

private final class AssetEditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10)
    func set(_ value: Double) { lock.withLock { self.value = Date(timeIntervalSince1970: value) } }
    func now() -> Date { lock.withLock { value } }
}

/// External signed bridge over the committed package-only production asset transport.
@available(iOS 17, macOS 14, *)
public actor GraphCloudAssetDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, report, pending }
    private enum Kind: String, CaseIterable { case local = "A", cloud = "C", control = "B" }
    private let clock = AssetEditClock()
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Kind: GraphStore] = [:]
    private var routes: [Kind: GraphCloudBinding] = [:]
    private var database: CKDatabase!
    private var root: URL!
    private var run: UUID!
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ["seed", "seed-remaining", "owner-replace", "observe-owner", "delete-owner"].contains(stage)) ||
              (replica == "peer" && ["read-baseline", "prepare-peer", "resolve-peer", "resolve-remaining", "reopen-peer", "read-deleted"].contains(stage)) ||
              (replica == "fresh" && stage == "read-final") else { throw Failure.request }
        self.run = run
        root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        let clock = clock
        manager = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.makeAdapter(clock: { clock.now() }))
        let create = ["seed", "read-baseline", "read-final"].contains(stage)
        for kind in Kind.allCases {
            let url = root.appendingPathComponent(kind.rawValue + ".sqlite")
            if create {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.fixture }
                graphs[kind] = try await manager.createGraph(id: graphID(kind), at: url, conflictPolicy: kind == .cloud ? .cloudWins : .lastEditWins)
            } else { graphs[kind] = try await manager.openGraph(id: graphID(kind), at: url) }
            guard try await graphs[kind]!.conflictPolicy == (kind == .cloud ? .cloudWins : .lastEditWins) else { throw Failure.fixture }
        }
        config = GraphCloudConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        database = CKContainer(identifier: container).privateCloudDatabase
        let identity = GraphCloudSessionIdentity(container: container, environment: .development, account: try await CKContainer(identifier: container).userRecordID().recordName)
        for kind in Kind.allCases {
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T04-" + run.uuidString + "-" + kind.rawValue)
            try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
            routes[kind] = try await manager.cloudBinding(for: zone, configuration: config)
        }
        var checks: [String] = []
        switch stage {
        case "seed", "seed-remaining":
            for kind in Kind.allCases {
                if stage == "seed-remaining" {
                    let count = try await graphs[kind]!.read { scope in
                        try scope.withContext { context, _ in
                            try GraphTypedStoreAdapter.Session(context, scope.graphID, database: true).nodes.count
                        }
                    }
                    guard count == (kind == .local ? 3 : 0) else { throw Failure.fixture }
                    if kind == .local { continue }
                }
                let owner = try GraphRecord(id: ownerID(kind), type: "AssetProbe.Owner", createdDate: Date(timeIntervalSince1970: 1))
                let payload = try GraphAttachmentPayload(id: fileID(kind), ownerID: owner.id, fileName: "photo.bin", contentType: "public.data", data: data(kind, mode: 0))
                let file = try payload.graphRecord()
                let empty = kind == .local ? try GraphAttachmentPayload(id: emptyID(), ownerID: owner.id, fileName: "empty.bin", contentType: "public.data", data: Data()).graphRecord() : nil
                try await graphs[kind]!.transaction { scope in
                    try scope.insert(owner); try scope.insert(file)
                    if let empty { try scope.insert(empty) }
                }
                try success(try await send(kind), succeeded: kind == .local ? 3 : 2, resolved: 0)
            }
            try await verify(mode: 0)
            checks.append("Real CKAssets published: exact 10-MiB, 512-byte and empty files; full server/local inventories and tags agree.")
        case "read-baseline":
            for kind in Kind.allCases {
                let destination = root.appendingPathComponent("Export-" + kind.rawValue)
                _ = try await manager.exportCloudAttachment(fileID(kind), to: destination, configuration: config, timeout: .seconds(180))
                guard try Data(contentsOf: destination) == data(kind, mode: 0) else { throw Failure.fixture }
            }
            try await verify(mode: 0)
            checks.append("Genuinely empty peer stores recovered via async export; exact bytes and metadata verified without upload feedback.")
        case "prepare-peer":
            clock.set(300)
            for kind in [Kind.local, .cloud] {
                try await replace(kind, value: 3, count: 4096)
                let binding = GraphCloudTransportBinding(identity: identity, route: routes[kind]!)
                let frozen = try await graphs[kind]!.prepareTransport(binding)
                guard frozen.items.count == 1 else { throw Failure.pending }
                try JSONEncoder().encode(frozen).write(to: root.appendingPathComponent("Frozen-" + kind.rawValue), options: .withoutOverwriting)
            }
            checks.append("Two complete replacements frozen at date300 against real baseline tags; no send.")
        case "owner-replace":
            clock.set(200)
            for kind in [Kind.local, .cloud] { try await replace(kind, value: 2, count: 2048); try success(try await send(kind), succeeded: 1, resolved: 0) }
            checks.append("Competing owner replacements/date200 published after peer snapshots; control file unchanged.")
        case "resolve-peer", "resolve-remaining":
            if stage == "resolve-remaining" {
                for kind in [Kind.local, .cloud] {
                    let original = try JSONDecoder().decode(GraphCloudOutgoingBatch.self, from: Data(contentsOf: root.appendingPathComponent("Frozen-" + kind.rawValue)))
                    let binding = GraphCloudTransportBinding(identity: identity, route: routes[kind]!)
                    guard try await graphs[kind]!.prepareTransport(binding) == original,
                          try await graphs[kind]!.collectSyncChanges() == 1 else { throw Failure.pending }
                }
            }
            for kind in [Kind.local, .cloud] { try success(try await send(kind), succeeded: kind == .local ? 1 : 0, resolved: 1) }
            try await verify(mode: 1)
            checks.append("Real asset conflicts: lastEditWins publishes peer bytes/revision in one targeted retry; cloudWins imports owner bytes/revision.")
        case "observe-owner":
            try await fetch(); try await verify(mode: 1)
            checks.append("Owner independently recovered final complete attachments; exact inventories and no feedback.")
        case "reopen-peer":
            try await verify(mode: 1)
            checks.append("Data, policies, empty queues and portable receipts survived process/session reopen without a fetch.")
        case "delete-owner":
            try await graphs[.local]!.delete(ownerID(.local))
            try success(try await send(.local), succeeded: 3, resolved: 0)
            try await verify(mode: 2)
            checks.append("Owner deletion cascaded to both assets; other graphs unchanged.")
        case "read-deleted", "read-final":
            try await fetch(); try await verify(mode: 2)
            checks.append("Independent deletion/fresh recovery: A empty, C/B exact; no resurrection or upload feedback.")
        default: throw Failure.request
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.report }
        return checks + ["Native production engine/provider; no path, account identity or application payload logged.", "Original zones/stores retained; no reset or stage replay."]
    }
    private func uuid(_ salt: UInt8) -> UUID { var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes) }
    private func graphID(_ kind: Kind) -> GraphID { GraphID(rawValue: uuid(UInt8(Kind.allCases.firstIndex(of: kind)!))) }
    private func ownerID(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: uuid(64)) }
    private func fileID(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: uuid(80)) }
    private func emptyID() -> GraphNodeID { GraphNodeID(graphID: graphID(.local), rawValue: uuid(96)) }
    private func data(_ kind: Kind, mode: Int) -> Data {
        if kind == .control { return Data(repeating: 1, count: 512) }
        if mode == 0 { return Data(repeating: 1, count: kind == .local ? GraphAttachmentPayload.maximumByteCount : 512) }
        return Data(repeating: kind == .local ? 3 : 2, count: kind == .local ? 4096 : 2048)
    }
    private func replace(_ kind: Kind, value: UInt8, count: Int) async throws {
        let source = root.appendingPathComponent("Source-" + kind.rawValue + "-" + String(value))
        try Data(repeating: value, count: count).write(to: source, options: .withoutOverwriting)
        _ = try await graphs[kind]!.replaceAttachment(fileID(kind), from: source)
    }
    private func send(_ kind: Kind) async throws -> GraphCloudSendReport { try await manager.sendCloudChanges(for: graphID(kind), configuration: config) }
    private func success(_ report: GraphCloudSendReport, succeeded: Int, resolved: Int) throws {
        if let error = report.transportError { throw error }
        guard report.succeeded == succeeded, report.resolvedConflicts == resolved, report.failures.isEmpty, !report.pendingRetry, !report.cleanupPending else { throw Failure.report }
    }
    private func fetch() async throws { try await manager.fetchCloudChanges(.private, configuration: config); for kind in Kind.allCases { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) } }
    private func verify(mode: Int) async throws {
        for kind in Kind.allCases {
            let graph = graphs[kind]!, deleted = mode == 2 && kind == .local
            let expected: Set<GraphNodeID> = deleted ? [] : (kind == .local ? [ownerID(kind), fileID(kind), emptyID()] : [ownerID(kind), fileID(kind)])
            let id = graphID(kind)
            let local = try await graph.read { scope in
                try scope.withContext { context, _ -> [GraphNodeID: GraphRecord] in
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    return try Dictionary(uniqueKeysWithValues: session.nodes.keys.map { ($0, try scope.record(for: $0)!) })
                }
            }
            guard Set(local.keys) == expected, try await graph.collectSyncChanges() == 0 else { throw Failure.pending }
            let zone = routes[kind]!.zone
            let result = try await database.recordZoneChanges(inZoneWith: .init(zoneName: zone.name, ownerName: zone.owner), since: nil, resultsLimit: 100)
            guard !result.moreComing, result.modificationResultsByID.count == expected.count else { throw Failure.fixture }
            for item in result.modificationResultsByID.values {
                let native = try item.get().record, decoded = try GraphCloudNodeCodec.decode(native, binding: routes[kind]!)
                guard native.recordChangeTag?.isEmpty == false, local[decoded.record.id] == decoded.record else { throw Failure.fixture }
                if decoded.record.type == GraphAttachmentPayload.graphType {
                    guard native["asset"] is CKAsset else { throw Failure.fixture }
                    let payload = try GraphAttachmentPayload(graphRecord: decoded.record)
                    let bytes = decoded.record.id == emptyID() ? Data() : data(kind, mode: mode)
                    guard payload.content.data == bytes, payload.ownerID == ownerID(kind) else { throw Failure.fixture }
                    let date: Double = mode == 0 || kind == .control || decoded.record.id == emptyID() ? 10 : (kind == .local ? 300 : 200)
                    guard decoded.modifiedAt == Date(timeIntervalSince1970: date) else { throw Failure.fixture }
                }
            }
        }
    }
}
