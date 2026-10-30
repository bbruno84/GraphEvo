import CloudKit
import Foundation
import GraphEvo
@testable import GraphEvo

@available(iOS 17, *)
actor CS01GraphController {
    let id: GraphID
    let url: URL
    private var db: GraphDatabase?
    private var graph: GraphStore?
    init(id: GraphID, url: URL) { self.id = id; self.url = url }
    func open() async throws { let result = try await GraphCustomSyncLaboratory.open(at: url, graphID: id); db = result.0; graph = result.1 }
    func close() async throws { try await graph?.close(); try await db?.close(); graph = nil; db = nil }
    func record(_ id: GraphNodeID) async throws -> GraphRecord? { guard let graph else { throw CS01Failure.closed }; return try await graph.read { try $0.record(for: id) } }
    func apply(_ records: [GraphRecord]) async throws {
        guard let graph else { throw CS01Failure.closed }
        let ordered = records.sorted { ($0.endpoints.kind == .entity ? 0 : 1) < ($1.endpoints.kind == .entity ? 0 : 1) }
        // Keep incomplete native batches in the durable engine inbox until dependencies arrive.
        let available = Set(records.map(\.id))
        for record in records {
            switch record.endpoints {
            case .relationship(let a, let b): guard [a,b].compactMap({ $0 }).allSatisfy(available.contains) else { return }
            case .action(let a, let b): guard a.union(b).isSubset(of: available) else { return }
            case .entity: break
            }
        }
        try await graph.transaction { scope in
            for record in ordered {
                if let old = try scope.record(for: record.id) {
                    var properties = record.properties.mapValues(GraphPropertyChange.set)
                    for key in old.properties.keys where record.properties[key] == nil { properties[key] = .remove }
                    _ = try scope.patch(GraphRecordPatch(id: record.id, properties: properties,
                        addingTags: record.tags.subtracting(old.tags), removingTags: old.tags.subtracting(record.tags),
                        addingGroups: record.groups.subtracting(old.groups), removingGroups: old.groups.subtracting(record.groups), endpoints: record.endpoints))
                } else { try scope.insert(record) }
            }
        }
    }
    func patch(_ id: GraphNodeID, key: String, value: GraphValue) async throws -> GraphRecord {
        guard let graph else { throw CS01Failure.closed }
        return try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, properties: [key: .set(value)])) }
    }
    func migrate() async throws { try await close(); try GraphCustomSyncLaboratory.migrateClosed(at: url); try await open() }
    func catalog() async throws -> [GraphID] { guard let db else { throw CS01Failure.closed }; return try await db.graphIDs() }
    func count() async throws -> Int { guard let db else { throw CS01Failure.closed }; return try await db.validateIntegrity(of: id) }
}

enum CS01Failure: Error { case fixture, paused, busy, closed, sync, replay, deadline }
struct CS01Route: Codable, Sendable {
    let graph: GraphID; let zoneName: String; let ownerName: String
    nonisolated var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
}

/// CS01 is manually scheduled for deterministic experiments, not production sync.
@available(iOS 17, *)
actor CS01Engine: CKSyncEngineDelegate {
    private struct Journal: Codable {
        var state: CKSyncEngine.State.Serialization?
        var paused: Set<GraphID> = []
        var records: [String: Data] = [:]
        var outbox: [String: Data] = [:]
        var inbox: [String: Data] = [:]
        var fields: [String: Data] = [:]
        var failure: String?
        var unexpectedZoneEvents = 0
    }
    private let file: URL
    private let routes: [CS01Route]
    private let controllers: [GraphID: CS01GraphController]
    private let database: CKDatabase
    private var journal: Journal
    private var engine: CKSyncEngine?
    private var busy = false
    private var applying = 0
    private var pausing: Set<GraphID> = []
    private var fetchedRows = 0
    init(file: URL, routes: [CS01Route], controllers: [GraphID: CS01GraphController], database: CKDatabase) throws {
        self.file = file; self.routes = routes; self.controllers = controllers; self.database = database
        if FileManager.default.fileExists(atPath: file.path) { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file)) }
        else { journal = Journal() }
    }
    private func key(_ id: GraphNodeID) -> String { id.graphID.rawValue.uuidString + ":" + id.rawValue.uuidString }
    private func route(_ zone: CKRecordZone.ID) -> CS01Route? { routes.first { $0.zoneID == zone } }
    private func persist() throws { try JSONEncoder().encode(journal).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    func start() async throws {
        guard engine == nil else { throw CS01Failure.busy }
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: journal.state, delegate: self)
        config.automaticallySync = false
        let value = CKSyncEngine(config); engine = value
        for payload in journal.outbox.values {
            let record = try GraphCustomSyncLaboratory.decode(payload)
            guard let route = routes.first(where: { $0.graph == record.id.graphID }) else { throw CS01Failure.fixture }
            value.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: record.id.rawValue.uuidString, zoneID: route.zoneID))])
        }
        try await materialize()
    }
    func createZones() throws { guard let engine else { throw CS01Failure.closed }; engine.state.add(pendingDatabaseChanges: routes.map { .saveZone(CKRecordZone(zoneID: $0.zoneID)) }) }
    func enqueue(_ record: GraphRecord) throws {
        guard let route = routes.first(where: { $0.graph == record.id.graphID }), let engine else { throw CS01Failure.fixture }
        let payload = try GraphCustomSyncLaboratory.encode(record); guard payload.count <= 262_144 else { throw CS01Failure.fixture }
        journal.records[key(record.id)] = payload; journal.outbox[key(record.id)] = payload
        try persist()
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: record.id.rawValue.uuidString, zoneID: route.zoneID))])
    }
    func synchronize(only graph: GraphID? = nil) async throws {
        let selected = routes.filter { (graph == nil || $0.graph == graph) && !journal.paused.contains($0.graph) && !pausing.contains($0.graph) }
        guard !selected.isEmpty else { throw CS01Failure.paused }
        guard !busy, let engine else { throw CS01Failure.busy }
        busy = true; defer { busy = false }
        try await engine.sendChanges(.init(scope: .zoneIDs(selected.map(\.zoneID))))
        try await engine.fetchChanges(.init(scope: .zoneIDs(selected.map(\.zoneID))))
        try await materialize()
        guard journal.failure == nil else { throw CS01Failure.sync }
    }
    func pause(_ graph: GraphID) async throws {
        pausing.insert(graph)
        await engine?.cancelOperations()
        // Cancellation alone is not a barrier. New arrivals are durably queued while paused.
        while busy || applying > 0 { try await Task.sleep(for: .milliseconds(25)) }
        journal.paused.insert(graph); try persist(); pausing.remove(graph)
    }
    func resume(_ graph: GraphID) throws { journal.paused.remove(graph); try persist() }
    func status() -> (paused: Bool, pending: Int, fetched: Int, unexpected: Int, failed: Bool) {
        (!journal.paused.isEmpty, journal.outbox.count, fetchedRows, journal.unexpectedZoneEvents, journal.failure != nil)
    }
    func diagnostic() -> String? { journal.failure }
    private func materialize() async throws {
        applying += 1; defer { applying -= 1 }
        let rows = try journal.records.values.map(GraphCustomSyncLaboratory.decode)
        for route in routes where !journal.paused.contains(route.graph) && !pausing.contains(route.graph) {
            guard let controller = controllers[route.graph] else { throw CS01Failure.fixture }
            try await controller.apply(rows.filter { $0.id.graphID == route.graph })
        }
    }
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var result = context.options
        result.scope = .zoneIDs(routes.filter { !journal.paused.contains($0.graph) && !pausing.contains($0.graph) && context.options.scope.contains($0.zoneID) }.map(\.zoneID))
        return result
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            var records: [CKRecord] = []
            for (key, payload) in journal.outbox {
                let node = try GraphCustomSyncLaboratory.decode(payload)
                guard let route = routes.first(where: { $0.graph == node.id.graphID }) else { throw CS01Failure.fixture }
                if journal.paused.contains(route.graph) || pausing.contains(route.graph) { continue }
                let id = CKRecord.ID(recordName: node.id.rawValue.uuidString, zoneID: route.zoneID)
                guard context.options.scope.contains(id) else { continue }
                let record: CKRecord
                if let data = journal.fields[key] {
                    let coder = try NSKeyedUnarchiver(forReadingFrom: data); coder.requiresSecureCoding = true
                    guard let restored = CKRecord(coder: coder) else { throw CS01Failure.fixture }; coder.finishDecoding(); record = restored
                } else { record = CKRecord(recordType: "GE2CS01Node", recordID: id) }
                guard record.recordID == id else { throw CS01Failure.fixture }
                record["payload"] = payload as CKRecordValue; records.append(record)
            }
            return records.isEmpty ? nil : .init(recordsToSave: records, atomicByZone: true)
        } catch { journal.failure = "outgoing-codec"; try? persist(); return nil }
    }
    private func saveFields(_ record: CKRecord, key: String) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding()
        journal.fields[key] = coder.encodedData
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let value): journal.state = value.stateSerialization; try persist()
            case .fetchedRecordZoneChanges(let value):
                for change in value.modifications {
                    let record = change.record
                    guard let route = route(record.recordID.zoneID) else { journal.unexpectedZoneEvents += 1; journal.failure = "unexpected-zone"; continue }
                    if record is CKShare || record.recordType == CKRecord.SystemType.share { continue }
                    guard record.recordType == "GE2CS01Node", let payload = record["payload"] as? Data else { throw CS01Failure.fixture }
                    let inboxKey = route.graph.rawValue.uuidString + ":" + record.recordID.recordName
                    journal.inbox[inboxKey] = payload; try persist()
                    let node = try GraphCustomSyncLaboratory.decode(payload)
                    guard node.id.graphID == route.graph, node.id.rawValue.uuidString == record.recordID.recordName else { throw CS01Failure.fixture }
                    let key = key(node.id)
                    if let pending = journal.outbox[key], pending != payload { journal.failure = "incoming-pending-conflict"; continue }
                    journal.records[key] = payload; journal.inbox.removeValue(forKey: inboxKey); saveFields(record, key: key); fetchedRows += 1
                }
                if !value.deletions.isEmpty { journal.failure = "deletion-not-in-this-slice" }
                // Persist fetched bodies before any await or state/cursor publication.
                try persist(); try await materialize()
            case .sentRecordZoneChanges(let value):
                for record in value.savedRecords {
                    guard let route = route(record.recordID.zoneID), let id = UUID(uuidString: record.recordID.recordName) else { throw CS01Failure.fixture }
                    let key = key(GraphNodeID(graphID: route.graph, rawValue: id)); saveFields(record, key: key)
                    if let sent = record["payload"] as? Data, journal.outbox[key] == sent { journal.outbox.removeValue(forKey: key) }
                }
                if !value.failedRecordSaves.isEmpty || !value.failedRecordDeletes.isEmpty { journal.failure = "record-send-failure:" + value.failedRecordSaves.map { String($0.error.code.rawValue) }.joined(separator: ",") }
                try persist()
            case .sentDatabaseChanges(let value):
                if !value.failedZoneSaves.isEmpty || !value.failedZoneDeletes.isEmpty { journal.failure = "zone-send-failure:" + value.failedZoneSaves.map { String($0.error.code.rawValue) }.joined(separator: ",") }; try persist()
            case .willFetchRecordZoneChanges(let value):
                if route(value.zoneID) == nil { journal.unexpectedZoneEvents += 1; journal.failure = "unexpected-zone-fetch"; try persist() }
            case .accountChange(let value):
                switch value.changeType { case .signOut, .switchAccounts: journal.paused = Set(routes.map(\.graph)); journal.failure = "account-change"; try persist(); default: break }
            default: break
            }
        } catch { journal.failure = "event-persistence-or-apply"; try? persist() }
    }
}
