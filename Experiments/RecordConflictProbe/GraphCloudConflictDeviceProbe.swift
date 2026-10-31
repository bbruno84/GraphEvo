import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// External-only bridge over the integrated runtime; no conflict resolver is installed.
@available(iOS 17, macOS 14, *)
public actor GraphCloudConflictDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, pending, report, metadata, snapshot, importGuard, transport }
    private enum Kind: String, CaseIterable { case update = "U", delete = "D", removed = "R", control = "B" }
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Kind: GraphStore] = [:]
    private var bindings: [Kind: GraphCloudTransportBinding] = [:]
    private var root: URL!
    private var run: UUID!
    private var database: CKDatabase!
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        let ownerStages = ["seed", "owner-compete", "observe-owner"]
        let peerStages = ["read-baseline", "prepare-peer", "submit-update", "submit-delete", "submit-after-delete", "independent-progress", "retry-peer", "fetch-conflicts", "reopen-peer"]
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ownerStages.contains(stage)) || (replica == "peer" && peerStages.contains(stage)) ||
              (replica == "fresh" && stage == "read-final") else { throw Failure.request }
        self.run = run
        root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        manager = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let create = ["seed", "read-baseline", "read-final"].contains(stage)
        for kind in Kind.allCases {
            let url = root.appendingPathComponent(kind.rawValue + ".sqlite")
            if create {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.fixture }
                graphs[kind] = try await manager.createGraph(id: graphID(kind), at: url)
            } else { graphs[kind] = try await manager.openGraph(id: graphID(kind), at: url) }
        }
        config = GraphCloudConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        let native = CKContainer(identifier: container)
        database = native.privateCloudDatabase
        let identity = GraphCloudSessionIdentity(container: container, environment: .development, account: try await native.userRecordID().recordName)
        for kind in Kind.allCases {
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-C01-" + run.uuidString + "-" + kind.rawValue)
            try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
            guard let route = try await manager.cloudBinding(for: zone, configuration: config) else { throw Failure.fixture }
            bindings[kind] = GraphCloudTransportBinding(identity: identity, route: route)
        }
        var checks: [String] = []
        switch stage {
        case "seed":
            for kind in Kind.allCases {
                let record = try record(kind, value: kind == .control ? 99 : 1)
                try await graphs[kind]!.transaction { try $0.insert(record) }
                try success(try await send(kind), count: 1)
            }
            try await baseline()
            checks.append("Four private zones seeded with real server versions; no pending upload work.")
        case "read-baseline":
            for kind in Kind.allCases { guard try await queue(kind).isEmpty else { throw Failure.pending } }
            try await fetchAndApply()
            try await baseline()
            checks.append("Independent empty stores recovered the same server baseline without upload feedback.")
        case "prepare-peer":
            try await baseline()
            try await patch(.update, value: 3)
            let leaf = try leafRecord()
            try await graphs[.update]!.transaction { try $0.insert(leaf) }
            let deleted = target(.delete)
            try await graphs[.delete]!.transaction { try $0.delete(deleted) }
            try await patch(.removed, value: 3)
            for kind in [Kind.update, .delete, .removed] {
                let batch = try await graphs[kind]!.prepareTransport(bindings[kind]!)
                guard batch.items.count == (kind == .update ? 2 : 1) else { throw Failure.pending }
                if kind != .delete {
                    guard let archive = batch.items.first(where: { $0.change.id == target(kind) })?.recordArchive,
                          let candidate = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: archive),
                          let tag = candidate.recordChangeTag,
                          let server = try await nativeRecord(kind), server.recordChangeTag == tag else { throw Failure.metadata }
                }
                try JSONEncoder().encode(batch).write(to: frozenURL(kind), options: .withoutOverwriting)
            }
            try await assertServer(.update, value: 1); try await assertServer(.delete, value: 1); try await assertServer(.removed, value: 1)
            checks.append("Peer writes frozen against the shared baseline before competing server writes; nothing sent.")
        case "owner-compete":
            try await patch(.update, value: 2); try await patch(.delete, value: 2)
            let deleted = target(.removed)
            try await graphs[.removed]!.transaction { try $0.delete(deleted) }
            for kind in [Kind.update, .delete, .removed] { try success(try await send(kind), count: 1) }
            try await assertLocal(.update, value: 2); try await assertLocal(.delete, value: 2); try await assertLocal(.removed, value: nil)
            try await assertServer(.update, value: 2); try await assertServer(.delete, value: 2); try await assertServer(.removed, value: nil)
            checks.append("Owner published conflicting values and a deletion after the peer had frozen its original base.")
        case "submit-update":
            let original = try frozen(.update)
            guard try await graphs[.update]!.prepareTransport(bindings[.update]!) == original,
                  let bytes = original.items.first(where: { $0.change.id == target(.update) })?.recordArchive,
                  let client = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes),
                  let server = try await nativeRecord(.update), client.recordChangeTag != server.recordChangeTag else { throw Failure.metadata }
            let result = try await send(.update)
            try conflict(result, kind: .update, code: .serverRecordChanged, succeeded: 1)
            try await assertLocal(.update, value: 3, leaf: true); try await assertServer(.update, value: 2)
            try await assertLeafOnServer()
            try await pendingOnly(.update); try await remainingFrozen(.update)
            checks.append("Real serverRecordChanged retained the local edit; the unrelated leaf in the same non-atomic batch succeeded and was acknowledged alone.")
        case "submit-delete":
            try await assertServer(.delete, value: 2)
            try success(try await send(.delete), count: 1)
            try await assertLocal(.delete, value: nil); try await assertServer(.delete, value: nil)
            guard try await queue(.delete).isEmpty else { throw Failure.pending }
            checks.append("A stale record-ID deletion removed the newer server value: deletion has no save change-tag comparison.")
        case "submit-after-delete":
            try await assertServer(.removed, value: nil)
            let result = try await send(.removed)
            try conflict(result, kind: .removed, code: .unknownItem, succeeded: 0)
            try await assertLocal(.removed, value: 3); try await assertServer(.removed, value: nil)
            try await pendingOnly(.removed); try await remainingFrozen(.removed)
            checks.append("A stale save after remote deletion failed with unknownItem; local edit retained and no server resurrection.")
        case "independent-progress":
            try await pendingOnly(.update); try await pendingOnly(.removed)
            try await patch(.control, value: 100)
            try success(try await send(.control), count: 1)
            try await assertLocal(.control, value: 100); try await assertServer(.control, value: 100)
            try await pendingOnly(.update); try await pendingOnly(.removed)
            checks.append("The same private engine advanced another graph while two graphs retained unresolved work.")
        case "retry-peer":
            try await patch(.update, value: 4)
            try await remainingFrozen(.update)
            do { try conflict(try await send(.update), kind: .update, code: .serverRecordChanged, succeeded: 0) }
            catch GraphSyncError.pendingImport { checks.append("Retained incoming conflict prevented network admission on retry.") }
            try await assertLocal(.update, value: 4, leaf: true); try await assertServer(.update, value: 2)
            let pending = try await queue(.update), prior = try frozen(.update)
            guard pending.count == 1, let attempted = prior.items.first(where: { $0.change.id == target(.update) }),
                  pending[0].generation > attempted.change.generation else { throw Failure.pending }
            try await remainingFrozen(.update); try await remainingFrozen(.removed)
            checks.append("Restart/retry preserved frozen bytes and a newer local generation without acknowledgement or automatic merge.")
        case "fetch-conflicts":
            try await manager.fetchCloudChanges(.private, configuration: config)
            for kind in [Kind.update, .removed] {
                do {
                    _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config)
                    throw Failure.importGuard
                } catch GraphSyncError.pendingImport { }
            }
            for kind in [Kind.delete, .control] { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) }
            try await peerState()
            guard try await manager.cloudStatus(config).inboxCount > 0 else { throw Failure.importGuard }
            checks.append("Incoming conflicting value/deletion rolled back and remained retained; peer values and pending writes survived.")
        case "observe-owner", "read-final":
            try await fetchAndApply()
            try await finalState()
            checks.append("Independent replica matches complete server inventories: winner plus partial-success leaf, no deleted records, independent graph advanced; no feedback.")
        case "reopen-peer":
            try await peerState()
            try await remainingFrozen(.update); try await remainingFrozen(.removed)
            guard try await manager.cloudStatus(config).inboxCount > 0 else { throw Failure.importGuard }
            checks.append("Pending generations, frozen attempts and refused incoming envelopes survived another process restart unchanged.")
        default: throw Failure.request
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.transport }
        return checks + ["Native engine used; no prototype/resolver or implicit conflict policy installed.", "Owners retained; raw payloads and account identity omitted from report."]
    }

    private func shifted(_ salt: UInt8) -> UUID {
        var bytes = run.uuid
        withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }
        return UUID(uuid: bytes)
    }
    private func index(_ kind: Kind) -> UInt8 { UInt8(Kind.allCases.firstIndex(of: kind)!) }
    private func graphID(_ kind: Kind) -> GraphID { GraphID(rawValue: shifted(index(kind))) }
    private func target(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: shifted(64 + index(kind))) }
    private func leafID() -> GraphNodeID { GraphNodeID(graphID: graphID(.update), rawValue: shifted(80)) }
    private func record(_ kind: Kind, value: Int64) throws -> GraphRecord {
        try GraphRecord(id: target(kind), type: "Conflict.Item", properties: ["value": .integer(value)], createdDate: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func leafRecord() throws -> GraphRecord {
        try GraphRecord(id: leafID(), type: "Conflict.Leaf", properties: ["value": .integer(30)], createdDate: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func patch(_ kind: Kind, value: Int64) async throws {
        let patch = try GraphRecordPatch(id: target(kind), properties: ["value": .set(.integer(value))])
        _ = try await graphs[kind]!.transaction { try $0.patch(patch) }
    }
    private func send(_ kind: Kind) async throws -> GraphCloudSendReport { try await manager.sendCloudChanges(for: graphID(kind), configuration: config) }
    private func success(_ result: GraphCloudSendReport, count: Int) throws {
        if let error = result.transportError { throw error }
        guard result.succeeded == count, result.failures.isEmpty, !result.cleanupPending else { throw Failure.report }
    }
    private func conflict(_ result: GraphCloudSendReport, kind: Kind, code: CKError.Code, succeeded: Int) throws {
        if let error = result.transportError {
            guard let native = error as? CKError, native.code == .partialFailure || native.code == code else { throw error }
        }
        let name = try GraphCloudNodeCodec.recordID(for: target(kind), binding: bindings[kind]!.route).recordName
        guard result.succeeded == succeeded, result.failures.count == 1, result.failures[0].recordName == name,
              result.failures[0].code == code.rawValue, !result.cleanupPending else { throw Failure.report }
    }
    private func queue(_ kind: Kind) async throws -> [GraphSyncChange] {
        let graph = graphs[kind]!, id = graph.id
        _ = try await graph.collectSyncChanges()
        return try await graph.read { scope in try scope.withContext { context, _ in try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state.pending } }
    }
    private func pendingOnly(_ kind: Kind) async throws {
        let pending = try await queue(kind)
        guard pending.count == 1, pending[0].id == target(kind), pending[0].operation == .save else { throw Failure.pending }
    }
    private func frozenURL(_ kind: Kind) -> URL { root.appendingPathComponent("Frozen-" + kind.rawValue + ".json") }
    private func frozen(_ kind: Kind) throws -> GraphCloudOutgoingBatch { try JSONDecoder().decode(GraphCloudOutgoingBatch.self, from: Data(contentsOf: frozenURL(kind))) }
    private func remainingFrozen(_ kind: Kind) async throws {
        let original = try frozen(kind), current = try await graphs[kind]!.prepareTransport(bindings[kind]!)
        guard current.id == original.id, current.graphID == original.graphID, current.zone == original.zone,
              current.items == original.items.filter({ $0.change.id == target(kind) }) else { throw Failure.snapshot }
    }
    private func assertLocal(_ kind: Kind, value: Int64?, leaf: Bool = false) async throws {
        var expected: [GraphRecord] = []
        if let value { expected.append(try record(kind, value: value)) }
        if leaf { expected.append(try leafRecord()) }
        let id = graphID(kind), desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        try await graphs[kind]!.read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                guard Set(session.nodes.keys) == Set(desired.keys) else { throw Failure.fixture }
            }
            for (id, record) in desired { guard try scope.record(for: id) == record else { throw Failure.fixture } }
        }
    }
    private func nativeRecord(_ kind: Kind) async throws -> CKRecord? {
        let id = try GraphCloudNodeCodec.recordID(for: target(kind), binding: bindings[kind]!.route)
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
    private func assertServer(_ kind: Kind, value: Int64?) async throws {
        let native = try await nativeRecord(kind)
        if let value {
            guard let native, let tag = native.recordChangeTag, !tag.isEmpty,
                  try GraphCloudNodeCodec.decode(native, binding: bindings[kind]!.route).record == record(kind, value: value) else { throw Failure.fixture }
        } else { guard native == nil else { throw Failure.fixture } }
    }
    private func assertLeafOnServer() async throws {
        let route = bindings[.update]!.route
        let native = try await database.record(for: GraphCloudNodeCodec.recordID(for: leafID(), binding: route))
        guard try GraphCloudNodeCodec.decode(native, binding: route).record == leafRecord() else { throw Failure.fixture }
    }
    private func fetchAndApply() async throws {
        try await manager.fetchCloudChanges(.private, configuration: config)
        for kind in Kind.allCases { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) }
    }
    private func baseline() async throws {
        for kind in Kind.allCases {
            let value: Int64 = kind == .control ? 99 : 1
            try await assertLocal(kind, value: value); try await assertServer(kind, value: value)
            guard try await queue(kind).isEmpty else { throw Failure.pending }
        }
    }
    private func peerState() async throws {
        try await assertLocal(.update, value: 4, leaf: true); try await assertLocal(.removed, value: 3)
        try await assertLocal(.delete, value: nil); try await assertLocal(.control, value: 100)
        try await pendingOnly(.update); try await pendingOnly(.removed)
        guard try await queue(.delete).isEmpty, try await queue(.control).isEmpty else { throw Failure.pending }
        try await assertServer(.update, value: 2); try await assertServer(.removed, value: nil)
    }
    private func finalState() async throws {
        for kind in Kind.allCases {
            let value: Int64? = kind == .update ? 2 : (kind == .control ? 100 : nil)
            try await assertLocal(kind, value: value, leaf: kind == .update)
            try await assertServer(kind, value: value)
            guard try await queue(kind).isEmpty else { throw Failure.pending }
            var expected: [GraphRecord] = []
            if let value { expected.append(try record(kind, value: value)) }
            if kind == .update { expected.append(try leafRecord()) }
            let route = bindings[kind]!.route, zone = CKRecordZone.ID(zoneName: route.zone.name, ownerName: route.zone.owner)
            let inventory = try await database.recordZoneChanges(inZoneWith: zone, since: nil, resultsLimit: 100)
            guard !inventory.moreComing, inventory.modificationResultsByID.count == expected.count else { throw Failure.fixture }
            let records = try inventory.modificationResultsByID.values.map { try GraphCloudNodeCodec.decode($0.get().record, binding: route).record }
            guard records.allSatisfy({ expected.contains($0) }) else { throw Failure.fixture }
        }
    }
}
