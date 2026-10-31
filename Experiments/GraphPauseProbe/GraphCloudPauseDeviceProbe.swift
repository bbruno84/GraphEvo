import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

private final class PauseEditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10)
    func set(_ seconds: Double) { lock.withLock { value = Date(timeIntervalSince1970: seconds) } }
    func now() -> Date { lock.withLock { value } }
}

@available(iOS 17, macOS 14, *)
public actor GraphCloudPauseDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, report, timeout }
    private enum Kind: String, CaseIterable { case a = "A", b = "B" }
    private let clock = PauseEditClock()
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
              (replica == "owner" && ["seed", "update-owner", "observe-owner"].contains(stage)) ||
              (replica == "peer" && ["read-baseline", "pause-peer", "reopen-peer"].contains(stage)) ||
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
                graphs[kind] = try await manager.createGraph(id: graphID(kind), at: url)
            } else { graphs[kind] = try await manager.openGraph(id: graphID(kind), at: url) }
            guard try await manager.cloudSynchronizationState(for: graphID(kind)) == .active else { throw Failure.fixture }
        }
        config = GraphCloudConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        database = CKContainer(identifier: container).privateCloudDatabase
        for kind in Kind.allCases {
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T05-" + run.uuidString + "-" + kind.rawValue)
            try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
            routes[kind] = try await manager.cloudBinding(for: zone, configuration: config)
        }
        var checks: [String] = []
        switch stage {
        case "seed":
            for kind in Kind.allCases {
                let record = try record(kind, value: 1)
                _ = try await graphs[kind]!.transaction { try $0.insert(record) }
                try success(try await send(kind), expected: 1)
            }
            try await verify(final: false)
            checks.append("Two private baseline zones published and full local/server inventories verified.")
        case "read-baseline":
            try await fetchAndApply(); try await verify(final: false)
            checks.append("Independent empty peer stores recovered the exact baseline without feedback.")
        case "update-owner":
            clock.set(200)
            for kind in Kind.allCases { try await patch(kind, value: 2); try success(try await send(kind), expected: 1) }
            checks.append("Owner published A2/B2 only after peer announced A paused.")
        case "pause-peer":
            try await manager.pauseCloudSynchronization(for: graphID(.a))
            try await manager.pauseCloudSynchronization(for: graphID(.a))
            guard try await manager.cloudSynchronizationState(for: graphID(.a)) == .paused,
                  try await manager.cloudSynchronizationState(for: graphID(.b)) == .active else { throw Failure.report }
            try Data().write(to: root.appendingPathComponent(stage + ".ready"), options: .withoutOverwriting)
            // Lab-only external barrier: no graph or network work until the owner's update report is verified.
            let deadline = ContinuousClock.now + .seconds(180)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent(stage + ".continue").path) {
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
            clock.set(300); try await patch(.a, value: 3)
            guard try await graphs[.a]!.collectSyncChanges() == 1 else { throw Failure.fixture }
            do { _ = try await send(.a); throw Failure.report } catch GraphCloudError.graphPaused { }
            do { _ = try await manager.applyCloudInbox(for: graphID(.a), configuration: config); throw Failure.report } catch GraphCloudError.graphPaused { }
            try await manager.fetchCloudChanges(.private, configuration: config)
            _ = try await manager.applyCloudInbox(for: graphID(.b), configuration: config)
            let aID = nodeID(.a), bID = nodeID(.b)
            guard try await graphs[.a]!.read({ try $0.record(for: aID)?.properties["value"] }) == .integer(3),
                  try await graphs[.b]!.read({ try $0.record(for: bID)?.properties["value"] }) == .integer(2) else { throw Failure.fixture }
            let inbox = try await manager.cloudInbox(config)
            guard !inbox.contains(where: { $0.change.zone == routes[.a]!.zone && [.recordChanged, .recordDeleted].contains($0.change.kind) }) else { throw Failure.report }
            try await manager.resumeCloudSynchronization(for: graphID(.a))
            try await fetchAndApply()
            try success(try await send(.a), expected: 1)
            try await verify(final: true)
            try await manager.pauseCloudSynchronization(for: graphID(.a))
            checks.append("A paused excludes real record fetch/send/import while B reaches2; local A3 stays pending then publishes after resume. Final idle A pause retained for reopen check.")
        case "observe-owner", "read-final":
            try await fetchAndApply(); try await verify(final: true)
            checks.append("Independent complete recovery converged to A3/B2 with empty upload queues.")
        case "reopen-peer":
            try await verify(final: true)
            checks.append("Process/session reopen reset the process-local pause to active, preserving data and empty queues.")
        default: throw Failure.request
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.report }
        return checks + ["One native private engine, independent graph zones; no payload or account identifiers logged.", "No reset, purge, copied stores or stage replay; owners retained."]
    }
    private func uuid(_ salt: UInt8) -> UUID { var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes) }
    private func graphID(_ kind: Kind) -> GraphID { GraphID(rawValue: uuid(kind == .a ? 0 : 1)) }
    private func nodeID(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: uuid(64)) }
    private func record(_ kind: Kind, value: Int64) throws -> GraphRecord { try GraphRecord(id: nodeID(kind), type: "Pause.Item", properties: ["value": .integer(value)], createdDate: Date(timeIntervalSince1970: 1)) }
    private func patch(_ kind: Kind, value: Int64) async throws {
        let patch = try GraphRecordPatch(id: nodeID(kind), properties: ["value": .set(.integer(value))])
        _ = try await graphs[kind]!.transaction { try $0.patch(patch) }
    }
    private func send(_ kind: Kind) async throws -> GraphCloudSendReport { try await manager.sendCloudChanges(for: graphID(kind), configuration: config) }
    private func success(_ report: GraphCloudSendReport, expected: Int) throws {
        if let error = report.transportError { throw error }
        guard report.succeeded == expected, report.failures.isEmpty, !report.pendingRetry, !report.cleanupPending else { throw Failure.report }
    }
    private func fetchAndApply() async throws {
        try await manager.fetchCloudChanges(.private, configuration: config)
        for kind in Kind.allCases { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) }
    }
    private func verify(final: Bool) async throws {
        for kind in Kind.allCases {
            let expected = try record(kind, value: final ? (kind == .a ? 3 : 2) : 1), id = graphID(kind)
            let graph = graphs[kind]!
            try await graph.read { scope in
                try scope.withContext { context, _ in
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard Set(session.nodes.keys) == [expected.id], try scope.record(for: expected.id) == expected else { throw Failure.fixture }
                }
            }
            guard try await graph.collectSyncChanges() == 0 else { throw Failure.fixture }
            let zone = routes[kind]!.zone
            let remote = try await database.recordZoneChanges(inZoneWith: .init(zoneName: zone.name, ownerName: zone.owner), since: nil, resultsLimit: 100)
            guard !remote.moreComing, remote.modificationResultsByID.count == 1 else { throw Failure.fixture }
            for result in remote.modificationResultsByID.values {
                let native = try result.get().record, decoded = try GraphCloudNodeCodec.decode(native, binding: routes[kind]!)
                guard native.recordChangeTag?.isEmpty == false, decoded.record == expected,
                      decoded.modifiedAt == Date(timeIntervalSince1970: final ? (kind == .a ? 300 : 200) : 10) else { throw Failure.fixture }
            }
        }
    }
}
