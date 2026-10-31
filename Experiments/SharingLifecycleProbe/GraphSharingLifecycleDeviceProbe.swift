import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

@available(iOS 17, macOS 14, *)
public actor GraphSharingLifecycleDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, timeout, verification }
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Int: GraphStore] = [:]
    private var routes: [Int: GraphCloudBinding] = [:]
    private var run: UUID!
    private var root: URL!
    public init() {}
    private func uuid(_ salt: UInt8) -> UUID { var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes) }
    private func graphID(_ kind: Int) -> GraphID { GraphID(rawValue: uuid(UInt8(kind))) }
    private func nodeID(_ kind: Int, _ salt: UInt8 = 64) -> GraphNodeID { .init(graphID: graphID(kind), rawValue: uuid(salt)) }
    private func oldURL(_ kind: Int) -> URL { root.appendingPathComponent("G\(kind).sqlite") }
    private var rejoinedURL: URL { root.appendingPathComponent("A-Rejoined.sqlite") }
    private func invitations() throws -> [GraphCloudInvitation] {
        try JSONDecoder().decode([GraphCloudInvitation].self, from: Data(contentsOf: root.appendingPathComponent("invitations.json")))
    }
    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ["seed", "downgrade", "revoke", "reinvite", "stop", "audit"].contains(stage)) ||
              (replica == "peer" && ["identity", "accept", "pending", "read-only", "revoke-start", "recover-purge", "rejoin", "leave", "stop-all"].contains(stage)) else { throw Failure.request }
        self.run = run; root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        manager = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        config = .init(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        if stage == "identity" {
            try JSONEncoder().encode(await manager.cloudSharingIdentity(config)).write(to: root.appendingPathComponent("identity.json"), options: .withoutOverwriting)
            return ["Protected recipient identity prepared; no graph created."]
        }
        let owner = replica == "owner", create = ["seed", "accept"].contains(stage)
        let kinds = owner ? [0,1,2] : ["recover-purge", "rejoin", "stop-all"].contains(stage) ? [2] : [0,2]
        for kind in kinds {
            let url = kind == 0 && ["leave"].contains(stage) ? rejoinedURL : oldURL(kind)
            if create {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.fixture }
                graphs[kind] = try await manager.createGraph(id: graphID(kind), at: url)
            } else { graphs[kind] = try await manager.openGraph(id: graphID(kind), at: url) }
            if owner {
                let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T08-" + run.uuidString + "-\(kind)")
                try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
                routes[kind] = .init(zone: zone, graphID: graphID(kind))
            }
        }
        if !owner {
            for invite in try invitations() { routes[invite.graphID == graphID(0) ? 0 : 2] = .init(zone: invite.zone, graphID: invite.graphID) }
            if stage == "accept" { for invite in try invitations() { try await manager.acceptCloudInvitation(invite, configuration: config) } }
        }
        if stage == "seed" {
            for kind in kinds {
                let value = try GraphRecord(id: nodeID(kind), type: "Lifecycle.Item", properties: ["value": .integer(1)])
                _ = try await graphs[kind]!.transaction { try $0.insert(value) }
            }
            let file = try GraphAttachmentPayload(id: nodeID(0,65), ownerID: nodeID(0), fileName: "lifecycle.txt", contentType: "public.plain-text", data: Data("T08 attachment".utf8))
            _ = try await graphs[0]!.transaction { try $0.insert(file) }
            for kind in kinds { try await send(kind) }
        }
        if ["seed", "reinvite"].contains(stage) {
            let recipient = try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appendingPathComponent("identity.json")))
            var values = [try await manager.inviteCloudParticipant(recipient, to: graphID(0), configuration: config)]
            if stage == "seed" { values.append(try await manager.inviteCloudParticipant(recipient, to: graphID(2), permission: .readOnly, configuration: config)) }
            else { values += try invitations().filter { $0.graphID == graphID(2) } }
            try JSONEncoder().encode(values).write(to: root.appendingPathComponent(stage == "seed" ? "invitations.json" : "reinvitation.json"), options: .withoutOverwriting)
        }
        if ["downgrade", "revoke"].contains(stage) {
            let recipient = try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appendingPathComponent("identity.json")))
            let result = stage == "downgrade" ? try await manager.setCloudParticipantPermission(.readOnly, participant: recipient, for: graphID(0), configuration: config) : try await manager.removeCloudParticipant(recipient, from: graphID(0), configuration: config)
            guard !result.remoteOperationPending, result.failure == nil else { throw Failure.verification }
        }
        if stage == "pending" {
            try await manager.pauseCloudSynchronization(for: graphID(0))
            let patch = try GraphRecordPatch(id: nodeID(0), properties: ["value": .set(.integer(2))])
            let pending = try GraphRecord(id: nodeID(0,66), type: "Lifecycle.Pending")
            _ = try await graphs[0]!.transaction { scope in _ = try scope.patch(patch); return try scope.insert(pending) }
            guard try await graphs[0]!.collectSyncChanges() == 2 else { throw Failure.verification }
            return ["Two consumer changes remain local and pending; no upload was performed."]
        }
        if stage == "read-only" {
            _ = try await manager.refreshCloudSharing(for: graphID(0), configuration: config)
            _ = try await manager.sendCloudChanges(for: graphID(0), configuration: config)
            guard try await graphs[0]!.collectSyncChanges() == 2 else { throw Failure.verification }
            try await denied(0)
            try await recover([2])
            return ["Read-only downgrade preserved two pending changes while other imports progressed."]
        }
        if stage == "revoke-start" {
            #if DEBUG
            let root = root!, target = graphID(0)
            await manager.setPurgeProbeBarrier { id in
                guard id == target else { return }
                try Data().write(to: root.appendingPathComponent("revoke-start.ready"), options: .withoutOverwriting)
                while true { try await Task.sleep(for: .seconds(1)) }
            }
            #else
            throw Failure.request
            #endif
            do { _ = try await manager.refreshCloudSharing(for: graphID(0), configuration: config) } catch GraphCloudError.zoneUnavailable {}
            try await manager.registerCloudGraphLocation(graphID(0), at: oldURL(0), configuration: config)
            throw Failure.verification
        }
        if stage == "recover-purge" {
            guard try await manager.cloudSharingStatus(for: graphID(0), configuration: config).phase == .purging else { throw Failure.verification }
            try await manager.registerCloudGraphLocation(graphID(0), at: oldURL(0), configuration: config)
            try await absent(0, url: oldURL(0)); try await recover([2])
            return ["Process interrupted after durable revoke intent; restart purged A without exposing app data; C retained."]
        }
        if stage == "rejoin" {
            guard let invite = try invitations().first(where: { $0.graphID == graphID(0) }) else { throw Failure.fixture }
            graphs[0] = try await manager.acceptCloudInvitation(invite, at: rejoinedURL, configuration: config)
            try await recover([0,2]); try await verify(0, owner: false); try await verify(2, owner: false)
            let pending = nodeID(0,66)
            guard try await graphs[0]!.read({ try $0.record(for: pending) }) == nil else { throw Failure.verification }
            return ["Explicit new invitation rebuilt A from cloud into an empty store; discarded edits did not reappear; C survived engine replacement."]
        }
        if stage == "leave" {
            let result = try await manager.leaveCloudShare(for: graphID(0), configuration: config)
            guard !result.remoteOperationPending else { throw Failure.verification }
            try await absent(0, url: rejoinedURL); try await recover([2])
            return ["Participant deleted only the shared CKShare; local A removed, C retained, owner graph preserved for independent audit."]
        }
        if stage == "stop" {
            let result = try await manager.stopCloudSharing(for: graphID(2), configuration: config)
            guard !result.remoteOperationPending, result.failure == nil else { throw Failure.verification }
        }
        if stage == "stop-all" {
            try await manager.pauseCloudSynchronization(for: graphID(2))
            try await manager.setAutomaticCloudSynchronizationActive(true, configuration: config)
            let deadline = ContinuousClock.now + .seconds(90)
            while try await manager.cloudSharingStatus(for: graphID(2), configuration: config).phase != .removed {
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await absent(2, url: oldURL(2))
            return ["Foreground control worker detected owner stop and purged paused C, without a manual fetch/apply/refresh."]
        }
        if !owner { try await recover(kinds) }
        for kind in kinds { try await verify(kind, owner: owner) }
        return ["Exact local/cloud graph inventories, original contents and file bytes, empty queues and no sync failure.", "Owner's private A/B/C remain intact; read-only participant writes refused; no container reset or mutation replay."]
    }
    private func send(_ kind: Int) async throws {
        let result = try await manager.sendCloudChanges(for: graphID(kind), configuration: config)
        guard result.transportError == nil, result.failures.isEmpty, try await graphs[kind]!.collectSyncChanges() == 0 else { throw Failure.verification }
    }
    private func recover(_ kinds: [Int]) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            try await manager.fetchCloudChanges(.shared, configuration: config)
            for kind in kinds { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) }
            var complete = true
            for kind in kinds { let id = nodeID(kind); if try await graphs[kind]!.read({ try $0.record(for: id)?.properties["value"] }) != .integer(1) { complete = false } }
            if kinds.contains(0), try await graphs[0]!.attachment(nodeID(0,65)) == nil { complete = false }
            if complete { return }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func absent(_ kind: Int, url: URL) async throws {
        guard try await manager.cloudSharingStatus(for: graphID(kind), configuration: config).phase == .removed,
              ![url.path, url.path + "-wal", url.path + "-shm"].contains(where: { FileManager.default.fileExists(atPath: $0) }) else { throw Failure.verification }
    }
    private func denied(_ kind: Int) async throws {
        var denied = false; do { try await graphs[kind]!.transaction { _ in () } } catch { denied = true }
        guard denied else { throw Failure.verification }
    }
    private func verify(_ kind: Int, owner: Bool) async throws {
        let graph = graphs[kind]!, id = nodeID(kind), file = nodeID(0,65), graphID = graphID(kind)
        let expected: Set<GraphNodeID> = kind == 0 ? [id,file] : [id]
        try await graph.read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                guard Set(session.nodes.keys) == expected, try session.record(id)?.properties["value"] == .integer(1) else { throw Failure.verification }
            }
        }
        guard try await graph.collectSyncChanges() == 0 else { throw Failure.verification }
        if kind == 0 { guard try await graph.attachment(file)?.data == Data("T08 attachment".utf8) else { throw Failure.verification } }
        if !owner && kind == 2 { try await denied(kind) }
        let database = owner ? CKContainer(identifier: config.containerIdentifier).privateCloudDatabase : CKContainer(identifier: config.containerIdentifier).sharedCloudDatabase
        let route = routes[kind]!, zone = CKRecordZone.ID(zoneName: route.zone.name, ownerName: route.zone.owner)
        let inventory = try await database.recordZoneChanges(inZoneWith: zone, since: nil, resultsLimit: 100)
        guard !inventory.moreComing else { throw Failure.verification }
        let actual = try inventory.modificationResultsByID.values.compactMap { result -> GraphRecord? in
            let native = try result.get().record
            if native is CKShare { return nil }
            return try GraphCloudNodeCodec.decode(native, binding: route).record
        }
        guard Set(actual.map(\.id)) == expected, actual.count == expected.count,
              actual.first(where: { $0.id == id })?.properties["value"] == .integer(1) else { throw Failure.verification }
    }
}
