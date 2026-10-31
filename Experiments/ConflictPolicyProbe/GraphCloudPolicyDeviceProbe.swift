import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

private final class ProbeEditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10)
    func set(_ seconds: Double) { lock.withLock { value = Date(timeIntervalSince1970: seconds) } }
    func now() -> Date { lock.withLock { value } }
}

/// External-only bridge. The real mutation hook stamps dates using this controlled clock.
@available(iOS 17, macOS 14, *)
public actor GraphCloudPolicyDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, pending, report, metadata }
    private enum Kind: String, CaseIterable { case older = "U", newer = "L", cloud = "C", tie = "T", delete = "D", removed = "R", control = "B" }
    private let clock = ProbeEditClock()
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Kind: GraphStore] = [:]
    private var bindings: [Kind: GraphCloudTransportBinding] = [:]
    private var root: URL!
    private var run: UUID!
    private var database: CKDatabase!
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ["seed", "owner-compete", "observe-owner"].contains(stage)) ||
              (replica == "peer" && ["read-baseline", "prepare-peer", "resolve-peer", "reopen-peer"].contains(stage)) ||
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
            guard try await graphs[kind]!.conflictPolicy == (kind == .cloud ? .cloudWins : .lastEditWins) else { throw Failure.metadata }
        }
        config = GraphCloudConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        let native = CKContainer(identifier: container)
        database = native.privateCloudDatabase
        let identity = GraphCloudSessionIdentity(container: container, environment: .development, account: try await native.userRecordID().recordName)
        for kind in Kind.allCases {
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T03-" + run.uuidString + "-" + kind.rawValue)
            try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
            guard let route = try await manager.cloudBinding(for: zone, configuration: config) else { throw Failure.metadata }
            bindings[kind] = GraphCloudTransportBinding(identity: identity, route: route)
        }
        var checks: [String] = []
        switch stage {
        case "seed":
            for kind in Kind.allCases {
                let record = try record(kind, value: kind == .control ? 99 : 1)
                _ = try await graphs[kind]!.transaction { try $0.insert(record) }
                try success(try await send(kind), succeeded: 1, resolved: 0)
            }
            try await verify(baseline: true)
            checks.append("Seven private fixtures published with Graph-stamped date 10 and real native server tags.")
        case "read-baseline":
            try await fetchAndApply(); try await verify(baseline: true)
            checks.append("Empty peer stores recovered exact payloads, dates and configured local policies without feedback.")
        case "prepare-peer":
            for kind in [Kind.older, .newer, .cloud, .tie, .removed] {
                clock.set(kind == .older ? 100 : (kind == .tie ? 200 : 300))
                let patch = try GraphRecordPatch(id: target(kind), properties: ["value": .set(.integer(3))])
                if kind == .older {
                    let leaf = try leafRecord()
                    try await graphs[kind]!.transaction { _ = try $0.patch(patch); try $0.insert(leaf) }
                } else { _ = try await graphs[kind]!.transaction { try $0.patch(patch) } }
            }
            let deleted = target(.delete)
            try await graphs[.delete]!.delete(deleted)
            for kind in Kind.allCases where kind != .control {
                let frozen = try await graphs[kind]!.prepareTransport(bindings[kind]!)
                try JSONEncoder().encode(frozen).write(to: root.appendingPathComponent("Frozen-" + kind.rawValue + ".json"), options: .withoutOverwriting)
            }
            checks.append("Consumer mutations frozen against baseline; timestamp ordering controlled through the injected clock, not metadata edits.")
        case "owner-compete":
            clock.set(200)
            for kind in [Kind.older, .newer, .cloud, .tie, .delete] {
                try await patch(kind, value: 2); try success(try await send(kind), succeeded: 1, resolved: 0)
            }
            try await graphs[.removed]!.delete(target(.removed))
            try success(try await send(.removed), succeeded: 1, resolved: 0)
            checks.append("Owner updates/date 200 and deletion published after peer attempts were frozen.")
        case "resolve-peer":
            clock.set(400); try await patch(.newer, value: 4)
            for kind in [Kind.older, .newer, .cloud, .tie, .delete, .removed] {
                let report = try await send(kind)
                try success(report, succeeded: [.older, .newer, .delete].contains(kind) ? 1 : 0, resolved: kind == .delete ? 0 : 1)
            }
            clock.set(500); try await patch(.control, value: 100)
            try success(try await send(.control), succeeded: 1, resolved: 0)
            try await verify(baseline: false)
            checks.append("Both policies, equal dates, current local 4 over frozen 3, partial success, bounded rebase and both deletion orders converged automatically.")
        case "observe-owner", "read-final":
            try await fetchAndApply(); try await verify(baseline: false)
            checks.append("Independent replica matches complete final local/server inventories and dates; no upload feedback or recreation.")
        case "reopen-peer":
            try await verify(baseline: false)
            checks.append("Policies, resolved payloads, dates and empty queues survived native/session reopen.")
        default: throw Failure.request
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.report }
        return checks + ["Real CloudKit transport; test clock controls only automatic consumer timestamps.", "Owners retained; no raw account identity or payload logged."]
    }
    private func shifted(_ salt: UInt8) -> UUID { var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes) }
    private func graphID(_ kind: Kind) -> GraphID { GraphID(rawValue: shifted(UInt8(Kind.allCases.firstIndex(of: kind)!))) }
    private func target(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: shifted(64)) }
    private func leafID() -> GraphNodeID { GraphNodeID(graphID: graphID(.older), rawValue: shifted(80)) }
    private func record(_ kind: Kind, value: Int64) throws -> GraphRecord { try GraphRecord(id: target(kind), type: "Policy.Item", properties: ["value": .integer(value)], createdDate: Date(timeIntervalSince1970: 1)) }
    private func leafRecord() throws -> GraphRecord { try GraphRecord(id: leafID(), type: "Policy.Leaf", properties: ["value": .integer(30)], createdDate: Date(timeIntervalSince1970: 1)) }
    private func patch(_ kind: Kind, value: Int64) async throws { let patch = try GraphRecordPatch(id: target(kind), properties: ["value": .set(.integer(value))]); _ = try await graphs[kind]!.transaction { try $0.patch(patch) } }
    private func send(_ kind: Kind) async throws -> GraphCloudSendReport { try await manager.sendCloudChanges(for: graphID(kind), configuration: config) }
    private func success(_ report: GraphCloudSendReport, succeeded: Int, resolved: Int) throws {
        if let error = report.transportError { throw error }
        guard report.succeeded == succeeded, report.resolvedConflicts == resolved, report.failures.isEmpty, !report.pendingRetry, !report.cleanupPending else { throw Failure.report }
    }
    private func fetchAndApply() async throws { try await manager.fetchCloudChanges(.private, configuration: config); for kind in Kind.allCases { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) } }
    private func verify(baseline: Bool) async throws {
        for kind in Kind.allCases {
            let value: Int64? = baseline ? (kind == .control ? 99 : 1) : (kind == .control ? 100 : (kind == .newer ? 4 : ([.delete, .removed].contains(kind) ? nil : 2)))
            let date: Double = baseline ? 10 : (kind == .control ? 500 : (kind == .newer ? 400 : 200))
            var expected: [GraphRecord] = []
            if let value { expected.append(try record(kind, value: value)) }
            if !baseline && kind == .older { expected.append(try leafRecord()) }
            let desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) }), id = graphID(kind)
            try await graphs[kind]!.read { scope in
                try scope.withContext { context, _ in
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard Set(session.nodes.keys) == Set(desired.keys) else { throw Failure.fixture }
                    for (nodeID, record) in desired {
                        guard try scope.record(for: nodeID) == record, let node = try session.node(nodeID),
                              try GraphMutationMetadata.modifiedAt(node) == Date(timeIntervalSince1970: nodeID == record.id && record.type == "Policy.Leaf" ? 100 : date) else { throw Failure.fixture }
                    }
                }
            }
            guard try await graphs[kind]!.collectSyncChanges() == 0 else { throw Failure.pending }
            let route = bindings[kind]!.route, zone = CKRecordZone.ID(zoneName: route.zone.name, ownerName: route.zone.owner)
            let inventory = try await database.recordZoneChanges(inZoneWith: zone, since: nil, resultsLimit: 100)
            guard !inventory.moreComing, inventory.modificationResultsByID.count == expected.count else { throw Failure.fixture }
            for result in inventory.modificationResultsByID.values {
                let native = try result.get().record, decoded = try GraphCloudNodeCodec.decode(native, binding: route)
                guard expected.contains(decoded.record), decoded.modifiedAt == Date(timeIntervalSince1970: decoded.record.type == "Policy.Leaf" ? 100 : date),
                      native.recordChangeTag?.isEmpty == false else { throw Failure.metadata }
            }
        }
    }
}
