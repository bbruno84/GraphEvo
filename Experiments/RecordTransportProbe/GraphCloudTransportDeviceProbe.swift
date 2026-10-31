import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Compiled only into a disposable library copy, never the distributed product.
@available(iOS 17, macOS 14, *)
public actor GraphCloudTransportDeviceProbe {
    private enum Failure: Error { case request, fixture, pending, send, serverTag, metadata }
    private var manager: GraphContextManager?
    private var stores: [GraphStore] = []
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL,
                        container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              ["owner", "peer", "fresh"].contains(replica),
              ["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"].contains(stage),
              (replica == "owner") == !stage.hasPrefix("read-") else { throw Failure.request }
        let root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let started = root.appendingPathComponent(stage + ".started")
        try Data().write(to: started, options: .withoutOverwriting)
        let aID = GraphID(rawValue: run), bID = GraphID(rawValue: uuid(run, 1))
        let aURL = root.appendingPathComponent("A.sqlite"), bURL = root.appendingPathComponent("B.sqlite")
        let create = stage == "seed" || (stage.hasPrefix("read-") && !FileManager.default.fileExists(atPath: aURL.path))
        if create {
            guard !FileManager.default.fileExists(atPath: aURL.path), !FileManager.default.fileExists(atPath: bURL.path) else { throw Failure.fixture }
        }
        let owner = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        manager = owner
        let a: GraphStore, b: GraphStore
        if create { a = try await owner.createGraph(id: aID, at: aURL) }
        else { a = try await owner.openGraph(id: aID, at: aURL) }
        stores.append(a)
        if create { b = try await owner.createGraph(id: bID, at: bURL) }
        else { b = try await owner.openGraph(id: bID, at: bURL) }
        stores.append(b)
        let config = GraphCloudConfiguration(containerIdentifier: container, environment: .development,
                                              directory: root.appendingPathComponent("Engine"))
        _ = try await owner.startCloudSession(config)
        let zoneA = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T01-" + run.uuidString + "-A")
        let zoneB = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-T01-" + run.uuidString + "-B")
        try await owner.bindCloudZone(zoneA, to: aID, configuration: config)
        try await owner.bindCloudZone(zoneB, to: bID, configuration: config)
        guard let routeA = try await owner.cloudBinding(for: zoneA, configuration: config),
              let routeB = try await owner.cloudBinding(for: zoneB, configuration: config) else { throw Failure.fixture }
        let base = try records(run, phase: 0), phase: Int
        if stage.hasPrefix("read-") {
            phase = stage == "read-baseline" ? 0 : (stage == "read-update" ? 1 : 2)
            if create {
                guard try await a.collectSyncChanges() == 0, try await b.collectSyncChanges() == 0 else { throw Failure.pending }
            }
            try await owner.fetchCloudChanges(.private, configuration: config)
            _ = try await owner.applyCloudInbox(for: aID, configuration: config)
            _ = try await owner.applyCloudInbox(for: bID, configuration: config)
        } else if stage == "seed" {
            phase = 0
            try await a.transaction { scope in for record in base.a { try scope.insert(record) } }
            try await b.transaction { scope in for record in base.b { try scope.insert(record) } }
            try await send(owner, aID, config); try await send(owner, bID, config)
        } else {
            try await owner.fetchCloudChanges(.private, configuration: config)
            _ = try await owner.applyCloudInbox(for: aID, configuration: config)
            _ = try await owner.applyCloudInbox(for: bID, configuration: config)
            if stage == "update" {
                phase = 1
                let desired = try records(run, phase: 1)
                try await a.transaction { scope in
                    _ = try scope.patch(GraphRecordPatch(id: base.a[0].id, properties: ["value": .set(.integer(2)), "remove": .remove], addingTags: ["updated"]))
                    try scope.insert(desired.a[4]); try scope.insert(desired.a[5])
                    _ = try scope.patch(GraphRecordPatch(id: base.a[3].id, endpoints: desired.a[3].endpoints))
                }
                // Inspect the actual frozen provider archive against a fresh server base.
                let binding = GraphCloudTransportBinding(identity: .init(container: container, environment: .development,
                    account: try await CKContainer(identifier: container).userRecordID().recordName), route: routeA)
                let batch = try await a.prepareTransport(binding)
                let item = batch.items.first { $0.change.id == base.a[0].id }
                guard let bytes = item?.recordArchive, let native = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes) else { throw Failure.metadata }
                let server = try await CKContainer(identifier: container).privateCloudDatabase.record(for: native.recordID)
                guard let tag = server.recordChangeTag, native.recordChangeTag == tag else { throw Failure.metadata }
                try await send(owner, aID, config)
            } else if stage == "delete" {
                phase = 2
                try await a.transaction { try $0.delete(base.a[1].id) }
                try await send(owner, aID, config)
            } else { phase = 2 }
        }
        let desired = try records(run, phase: phase)
        try await verifyLocal(a, expected: desired.a, all: records(run, phase: 1).a.map(\.id))
        try await verifyLocal(b, expected: desired.b, all: base.b.map(\.id))
        guard try await a.collectSyncChanges() == 0, try await b.collectSyncChanges() == 0 else { throw Failure.pending }
        let database = CKContainer(identifier: container).privateCloudDatabase
        try await verifyServer(database, route: routeA, expected: desired.a, all: records(run, phase: 1).a.map(\.id))
        try await verifyServer(database, route: routeB, expected: desired.b, all: base.b.map(\.id))
        if stage == "audit" || stage == "read-audit" {
            try await auditInventory(a, route: routeA, expected: desired.a, database: database)
            try await auditInventory(b, route: routeB, expected: desired.b, database: database)
        }
        let status = try await owner.cloudStatus(config)
        guard status.failure == nil, status.outgoingReceiptCount == 0 else { throw Failure.send }
        return ["Native engine session active; no prototype engine used.", "Exact local and independently fetched server values/topology match.",
                "Private graph zones remain separate; B is unchanged.", "Real server change tags present; no pending upload feedback.",
                "Stage passed; owners retained until host termination."]
    }

    private func send(_ manager: GraphContextManager, _ id: GraphID, _ config: GraphCloudConfiguration) async throws {
        let result = try await manager.sendCloudChanges(for: id, configuration: config)
        if let error = result.transportError { throw error }
        guard result.failures.isEmpty, !result.cleanupPending, result.succeeded > 0 else { throw Failure.send }
    }
    private func uuid(_ run: UUID, _ salt: UInt8) -> UUID {
        var value = run.uuid
        withUnsafeMutableBytes(of: &value) { $0[15] ^= salt }
        return UUID(uuid: value)
    }
    private func records(_ run: UUID, phase: Int) throws -> (a: [GraphRecord], b: [GraphRecord]) {
        let a = GraphID(rawValue: run), b = GraphID(rawValue: uuid(run, 1))
        let ids = (16...21).map { GraphNodeID(graphID: a, rawValue: uuid(run, UInt8($0))) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var properties: [String: GraphValue] = ["value": .integer(phase == 0 ? 1 : 2), "binary": .data(Data([0, 1, 255])), "null": .null, "uuid": .uuid(run)]
        if phase == 0 { properties["remove"] = .string("before") }
        var records = [
            try GraphRecord(id: ids[0], type: "Item", properties: properties, tags: phase == 0 ? ["initial"] : ["initial", "updated"], groups: ["fixture"], createdDate: date),
            try GraphRecord(id: ids[1], type: "Item", properties: ["value": .integer(10)], createdDate: date),
            try GraphRecord(id: ids[2], type: "links", endpoints: .relationship(subject: ids[0], object: ids[1]), properties: ["label": .string("edge")], createdDate: date),
            try GraphRecord(id: ids[3], type: "Action", endpoints: .action(subjects: phase == 0 ? [ids[0]] : [ids[0], ids[4]], objects: phase == 2 ? [] : [ids[1]]), createdDate: date)]
        if phase > 0 {
            records.append(try GraphRecord(id: ids[4], type: "Item", properties: ["value": .integer(30)], createdDate: date))
            records.append(try GraphRecord(id: ids[5], type: "links", endpoints: .relationship(subject: ids[0], object: ids[4]), createdDate: date))
        }
        if phase == 2 { records.removeAll { $0.id == ids[1] || $0.id == ids[2] } }
        return (records, [try GraphRecord(id: GraphNodeID(graphID: b, rawValue: uuid(run, 32)), type: "Control", properties: ["value": .integer(99)], createdDate: date)])
    }
    private func verifyLocal(_ graph: GraphStore, expected: [GraphRecord], all: [GraphNodeID]) async throws {
        let desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        try await graph.read { scope in
            for id in all { guard try scope.record(for: id) == desired[id] else { throw Failure.fixture } }
        }
    }
    private func auditInventory(_ graph: GraphStore, route: GraphCloudBinding, expected: [GraphRecord], database: CKDatabase) async throws {
        let desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        try await graph.read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                guard Set(session.nodes.keys) == Set(desired.keys) else { throw Failure.fixture }
            }
        }
        let zone = CKRecordZone.ID(zoneName: route.zone.name, ownerName: route.zone.owner)
        let inventory = try await database.recordZoneChanges(inZoneWith: zone, since: nil, resultsLimit: 100)
        guard !inventory.moreComing, inventory.modificationResultsByID.count == desired.count else { throw Failure.fixture }
        for result in inventory.modificationResultsByID.values {
            let record = try GraphCloudNodeCodec.decode(result.get().record, binding: route).record
            guard desired[record.id] == record else { throw Failure.fixture }
        }
    }
    private func verifyServer(_ database: CKDatabase, route: GraphCloudBinding, expected: [GraphRecord], all: [GraphNodeID]) async throws {
        let desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        for id in all {
            let nativeID = try GraphCloudNodeCodec.recordID(for: id, binding: route)
            do {
                let native = try await database.record(for: nativeID)
                guard desired[id] != nil, try GraphCloudNodeCodec.decode(native, binding: route).record == desired[id] else { throw Failure.fixture }
                guard let tag = native.recordChangeTag, !tag.isEmpty else { throw Failure.serverTag }
            } catch let error as CKError where error.code == .unknownItem {
                guard desired[id] == nil else { throw Failure.fixture }
            }
        }
    }
}
