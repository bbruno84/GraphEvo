import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// External-only physical protocol. Never imported into a production target or CI.
@available(iOS 17, macOS 14, *)
public actor GraphZoneSharingDeviceProbe {
    private enum Failure: Int, Error { case request = 1, fixture, timeout, verification }
    private var manager: GraphContextManager!
    private var config: GraphCloudConfiguration!
    private var graphs: [Int: GraphStore] = [:]
    private var routes: [Int: GraphCloudBinding] = [:]
    private var run: UUID!
    private var root: URL!
    public init() {}
    private func uuid(_ salt: UInt8) -> UUID {
        var bytes = run.uuid; withUnsafeMutableBytes(of: &bytes) { $0[15] ^= salt }; return UUID(uuid: bytes)
    }
    private func graphID(_ kind: Int) -> GraphID { GraphID(rawValue: uuid(UInt8(kind))) }
    private func nodeID(_ kind: Int, _ salt: UInt8 = 64) -> GraphNodeID { .init(graphID: graphID(kind), rawValue: uuid(salt)) }
    private func record(_ kind: Int, value: Int64) throws -> GraphRecord {
        try GraphRecord(id: nodeID(kind), type: "Sharing.Item", properties: ["value": .integer(value)])
    }
    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              (replica == "owner" && ["seed", "owner-edit", "observe-owner"].contains(stage)) ||
              (replica == "peer" && ["identity", "accept", "peer-edit", "observe-peer"].contains(stage)) ||
              (replica == "fresh" && stage == "recover") else { throw Failure.request }
        self.run = run; root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        manager = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        config = .init(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config)
        if stage == "identity" {
            let identity = try await manager.cloudSharingIdentity(config)
            try JSONEncoder().encode(identity).write(to: root.appendingPathComponent("identity.json"), options: .withoutOverwriting)
            return ["Recipient identity prepared for protected external transport; no graph/store created."]
        }
        let owner = replica == "owner", create = ["seed", "accept", "recover"].contains(stage)
        let kinds = owner ? [0, 1, 2] : [0, 2]
        for kind in kinds {
            let path = root.appendingPathComponent("G\(kind).sqlite")
            if create {
                guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure.fixture }
                graphs[kind] = try await manager.createGraph(id: graphID(kind), at: path)
            } else { graphs[kind] = try await manager.openGraph(id: graphID(kind), at: path) }
        }
        if owner {
            for kind in kinds {
                let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T07-" + run.uuidString + "-\(kind)")
                try await manager.bindCloudZone(zone, to: graphID(kind), configuration: config)
                routes[kind] = .init(zone: zone, graphID: graphID(kind))
            }
        } else {
            let invitations = try JSONDecoder().decode([GraphCloudInvitation].self, from: Data(contentsOf: root.appendingPathComponent("invitations.json")))
            guard Set(invitations.map(\.graphID)) == Set(kinds.map(graphID)), invitations.count == 2 else { throw Failure.fixture }
            for invitation in invitations {
                let kind = invitation.graphID == graphID(0) ? 0 : 2
                try await manager.acceptCloudInvitation(invitation, configuration: config)
                routes[kind] = .init(zone: invitation.zone, graphID: invitation.graphID)
            }
        }
        if stage == "seed" {
            for kind in kinds { let value = try record(kind, value: 1); _ = try await graphs[kind]!.transaction { try $0.insert(value) } }
            let file = try GraphAttachmentPayload(id: nodeID(0, 65), ownerID: nodeID(0), fileName: "sharing.txt", contentType: "public.plain-text", data: Data("T07 attachment".utf8))
            _ = try await graphs[0]!.transaction { try $0.insert(file) }
            for kind in kinds { try await send(kind) }
            let recipient = try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appendingPathComponent("identity.json")))
            var invitations: [GraphCloudInvitation] = []
            invitations.append(try await manager.inviteCloudParticipant(recipient, to: graphID(0), configuration: config))
            invitations.append(try await manager.inviteCloudParticipant(recipient, to: graphID(2), permission: .readOnly, configuration: config))
            try JSONEncoder().encode(invitations).write(to: root.appendingPathComponent("invitations.json"), options: .withoutOverwriting)
        }
        if stage == "peer-edit" || stage == "owner-edit" {
            let value: Int64 = stage == "peer-edit" ? 2 : 3
            let patch = try GraphRecordPatch(id: nodeID(0), properties: ["value": .set(.integer(value))])
            _ = try await graphs[0]!.transaction { try $0.patch(patch) }
            try await send(0)
        }
        let expected: Int64 = ["peer-edit", "observe-owner"].contains(stage) ? 2 : ["owner-edit", "observe-peer", "recover"].contains(stage) ? 3 : 1
        try await recover(kinds, expected: expected, scope: owner ? .private : .shared)
        if !owner {
            var denied = false
            do { try await graphs[2]!.transaction { _ in () } } catch { denied = true }
            guard denied else { throw Failure.verification }
        }
        let database = owner ? CKContainer(identifier: container).privateCloudDatabase : CKContainer(identifier: container).sharedCloudDatabase
        for kind in kinds { try await verify(kind, expected: kind == 0 ? expected : 1, database: database) }
        if !owner {
            // A private control zone is not discoverable through the participant's shared database.
            let all = try await database.allRecordZones()
            guard !all.contains(where: { $0.zoneID.zoneName == "GE2-T07-" + run.uuidString + "-1" }) else { throw Failure.verification }
        }
        let status = try await manager.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.verification }
        return ["Exact local and independent cloud inventories; attachment content/digest and empty PH queues.",
                "Owner uses private zones; participant uses shared zones with read-write A and read-only C; private B remains isolated.",
                "New fixtures, no container reset or copied stores; owners retained for independent peer observation."]
    }
    private func send(_ kind: Int) async throws {
        let report = try await manager.sendCloudChanges(for: graphID(kind), configuration: config)
        guard report.transportError == nil, report.failures.isEmpty, !report.pendingRetry,
              try await graphs[kind]!.collectSyncChanges() == 0 else { throw Failure.verification }
    }
    private func recover(_ kinds: [Int], expected: Int64, scope: GraphCloudScope) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            try await manager.fetchCloudChanges(scope, configuration: config)
            for kind in kinds { _ = try await manager.applyCloudInbox(for: graphID(kind), configuration: config) }
            var complete = true
            for kind in kinds {
                let id = nodeID(kind)
                if try await graphs[kind]!.read({ try $0.record(for: id)?.properties["value"] }) != .integer(kind == 0 ? expected : 1) { complete = false }
                if kind == 0, try await graphs[kind]!.attachment(nodeID(0, 65)) == nil { complete = false }
            }
            if complete { return }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func verify(_ kind: Int, expected: Int64, database: CKDatabase) async throws {
        let node = nodeID(kind), attachment = nodeID(0, 65)
        let expectedIDs: Set<GraphNodeID> = kind == 0 ? [node, attachment] : [node]
        let graphID = graphID(kind)
        let value = try await graphs[kind]!.read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                guard Set(session.nodes.keys) == expectedIDs else { throw Failure.verification }
                return try session.record(node)
            }
        }
        guard value?.id == node, value?.properties["value"] == .integer(expected),
              try await graphs[kind]!.collectSyncChanges() == 0 else { throw Failure.verification }
        if kind == 0 {
            guard let content = try await graphs[kind]!.attachment(attachment), content.data == Data("T07 attachment".utf8) else { throw Failure.verification }
        }
        let route = routes[kind]!, zone = CKRecordZone.ID(zoneName: route.zone.name, ownerName: route.zone.owner)
        let inventory = try await database.recordZoneChanges(inZoneWith: zone, since: nil, resultsLimit: 100)
        guard !inventory.moreComing else { throw Failure.verification }
        var nodes: [GraphRecord] = [], shareCount = 0
        for result in inventory.modificationResultsByID.values {
            let native = try result.get().record
            if native is CKShare { shareCount += 1; continue }
            nodes.append(try GraphCloudNodeCodec.decode(native, binding: route).record)
        }
        guard Set(nodes.map(\.id)) == expectedIDs, nodes.count == expectedIDs.count,
              shareCount == (kind == 1 ? 0 : 1), nodes.first(where: { $0.id == node })?.properties["value"] == .integer(expected) else { throw Failure.verification }
    }
}
