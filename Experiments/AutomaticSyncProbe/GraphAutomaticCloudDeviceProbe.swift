import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

private final class AutomaticEditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10)
    func set(_ seconds: Double) { lock.withLock { value = Date(timeIntervalSince1970: seconds) } }
    func now() -> Date { lock.withLock { value } }
}

@available(iOS 17, macOS 14, *)
public actor GraphAutomaticCloudDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, report, timeout }
    private enum Kind: String, CaseIterable { case a = "A", b = "B" }
    private let clock = AutomaticEditClock()
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Kind: GraphStore] = [:]
    private var routes: [Kind: GraphCloudBinding] = [:]
    private var database: CKDatabase!
    private var root: URL!
    private var run: UUID!
    public init() {}

    private var applicationActive = false
    private var armed = false
    private var forwardsNotifications = true

    public func setApplicationActive(_ active: Bool) async {
        applicationActive = active
        if armed { try? await manager.setAutomaticCloudSynchronizationActive(active, configuration: config) }
    }
    public func remoteHint(container: String, scope: String) async {
        guard armed, forwardsNotifications, container == config.containerIdentifier,
              let scope = GraphCloudScope(rawValue: scope) else { return }
        try? await manager.notifyRemoteCloudChanges(in: scope, configuration: config)
    }

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ["seed", "update-owner", "update-control-owner", "observe-owner"].contains(stage)) ||
              (replica == "peer" && ["read-baseline", "periodic-peer", "pause-peer", "reopen-peer"].contains(stage)) ||
              (["fresh", "current"].contains(replica) && stage == "read-final") else { throw Failure.request }
        self.run = run
        forwardsNotifications = stage != "periodic-peer" && stage != "pause-peer"
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
            let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T06-" + run.uuidString + "-" + kind.rawValue)
            try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
            routes[kind] = try await manager.cloudBinding(for: zone, configuration: config)
        }
        if stage == "seed" {
            for kind in Kind.allCases {
                let record = try record(kind, value: 1)
                _ = try await graphs[kind]!.transaction { try $0.insert(record) }
            }
        }
        if ["update-owner", "update-control-owner"].contains(stage) {
            let control = stage == "update-control-owner"
            clock.set(control ? 400 : 200)
            for kind in Kind.allCases { try await patch(kind, value: control ? 3 : 2) }
        }
        if stage == "pause-peer" { try await manager.pauseCloudSynchronization(for: graphID(.a)) }
        armed = true
        try await manager.setAutomaticCloudSynchronizationActive(applicationActive, configuration: config)
        var checks: [String] = []
        switch stage {
        case "seed", "read-baseline":
            try await waitFor(1, 1); try await verify(1, 1, dates: [10, 10])
            checks.append("Automatic publication or genuinely empty baseline recovery; exact inventories and empty queues.")
        case "update-owner", "update-control-owner":
            let control = stage == "update-control-owner", value: Int64 = control ? 3 : 2
            try await waitFor(value, value); try await verify(value, value, dates: control ? [400, 400] : [200, 200])
            checks.append("Consumer updates published automatically without manual send/fetch/apply.")
        case "periodic-peer":
            try await waitFor(1, 1)
            let began = ContinuousClock.now
            try Data().write(to: root.appendingPathComponent(stage + ".ready"), options: .withoutOverwriting)
            try await waitFor(2, 2, timeout: 125)
            guard began.duration(to: .now) >= .seconds(35) else { throw Failure.report }
            try await verify(2, 2, dates: [200, 200])
            checks.append("A remote update after initial catch-up arrived through the real 60-second timer, with notification forwarding disabled.")
        case "pause-peer":
            try await waitFor(2, 2, pausedA: true)
            try Data().write(to: root.appendingPathComponent(stage + ".ready"), options: .withoutOverwriting)
            // External control acknowledges the independent owner's update; it does not trigger synchronization.
            let deadline = ContinuousClock.now + .seconds(180)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent(stage + ".continue").path) {
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
            clock.set(500); try await patch(.a, value: 4)
            try await waitFor(4, 3, pausedA: true, timeout: 125)
            guard try await graphs[.a]!.collectSyncChanges() == 1 else { throw Failure.report }
            let inbox = try await manager.cloudInbox(config)
            guard !inbox.contains(where: { $0.change.zone == routes[.a]!.zone && [.recordChanged, .recordDeleted].contains($0.change.kind) }) else { throw Failure.report }
            try await manager.resumeCloudSynchronization(for: graphID(.a))
            try await waitFor(4, 3); try await verify(4, 3, dates: [500, 400])
            try await manager.pauseCloudSynchronization(for: graphID(.a))
            checks.append("Paused A retained local A4 while automatic B reached3; resume automatically converged A4/B3. A paused again for restart.")
        case "observe-owner", "reopen-peer", "read-final":
            try await waitFor(4, 3); try await verify(4, 3, dates: [500, 400])
            checks.append("Automatic independent convergence/restart/fresh recovery to A4/B3, exact records and empty queues.")
        default: throw Failure.request
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.report }
        return checks + ["Actual aggregate scene activity gates the scheduler; no native automatic scheduling or manual transport calls.", "New zones and stores, no reset/purge/copied stores or consumed-stage replay; owners retained."]
    }

    private func waitFor(_ a: Int64, _ b: Int64, pausedA: Bool = false, timeout: Double = 45) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            var ready = true
            for (index, kind) in Kind.allCases.enumerated() {
                let id = nodeID(kind), expected = index == 0 ? a : b
                if try await graphs[kind]!.read({ try $0.record(for: id)?.properties["value"] }) != .integer(expected) { ready = false }
                let status = try await manager.automaticCloudSynchronizationStatus(for: graphID(kind), configuration: config)
                guard status.phase != .blocked else { throw Failure.report }
                if kind == .a && pausedA {
                    guard try await manager.cloudSynchronizationState(for: graphID(kind)) == .paused else { throw Failure.report }
                } else if status.phase != .idle || status.pendingWork { ready = false }
            }
            if ready { return }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func uuid(_ salt: UInt8) -> UUID { var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes) }
    private func graphID(_ kind: Kind) -> GraphID { GraphID(rawValue: uuid(kind == .a ? 0 : 1)) }
    private func nodeID(_ kind: Kind) -> GraphNodeID { GraphNodeID(graphID: graphID(kind), rawValue: uuid(64)) }
    private func record(_ kind: Kind, value: Int64) throws -> GraphRecord { try GraphRecord(id: nodeID(kind), type: "Automatic.Item", properties: ["value": .integer(value)], createdDate: Date(timeIntervalSince1970: 1)) }
    private func patch(_ kind: Kind, value: Int64) async throws {
        let patch = try GraphRecordPatch(id: nodeID(kind), properties: ["value": .set(.integer(value))])
        _ = try await graphs[kind]!.transaction { try $0.patch(patch) }
    }
    private func verify(_ a: Int64, _ b: Int64, dates: [Double]) async throws {
        for (index, kind) in Kind.allCases.enumerated() {
            let expected = try record(kind, value: kind == .a ? a : b), id = graphID(kind)
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
                      decoded.modifiedAt == Date(timeIntervalSince1970: dates[index]) else { throw Failure.fixture }
            }
        }
    }
}
