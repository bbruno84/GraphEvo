import CloudKit
import Foundation
import GraphEvoModel

struct GraphLedgerRemote: Sendable {
    let value: GraphLedger
    let recordArchive: Data
}
struct GraphLedgerService: Sendable {
    let fetch: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> GraphLedgerRemote?
    let save: @Sendable (GraphCloudConfiguration, GraphCloudBinding, GraphLedger, GraphLedgerRemote?) async throws -> GraphLedgerRemote
}

enum GraphLedgerCodec {
    static let recordType = "GraphEvoControl"
    static let recordName = "graphevo.control"
    private struct Envelope: Codable { let format: Int; let ledger: GraphLedger }

    static func isControl(_ change: GraphCloudIncoming) -> Bool {
        change.recordName == recordName || change.recordType == recordType
    }
    static func recordID(_ binding: GraphCloudBinding) -> CKRecord.ID {
        .init(recordName: recordName, zoneID: .init(zoneName: binding.zone.name, ownerName: binding.zone.owner))
    }
    static func decode(_ record: CKRecord, binding: GraphCloudBinding) throws -> GraphLedgerRemote {
        guard record.recordID == recordID(binding), record.recordType == recordType,
              record["graphID"] as? String == binding.graphID.rawValue.uuidString,
              let data = record["payload"] as? Data, data.count <= GraphLedger.maximumPayloadBytes else { throw GraphLedgerError.invalidData }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == 1, envelope.ledger.graphID == binding.graphID else { throw GraphLedgerError.invalidData }
        try envelope.ledger.validate()
        return .init(value: envelope.ledger, recordArchive: try GraphCloudRecordCodec.archive(record, scope: binding.zone.scope).recordArchive!)
    }
    static func encode(_ value: GraphLedger, binding: GraphCloudBinding, base: GraphLedgerRemote?) throws -> CKRecord {
        guard value.graphID == binding.graphID else { throw GraphLedgerError.invalidData }
        try value.validate()
        let record: CKRecord
        if let base {
            record = try GraphCloudRecordCodec.restore(base.recordArchive)
            guard try decode(record, binding: binding).value == base.value else { throw GraphLedgerError.invalidData }
        } else { record = CKRecord(recordType: recordType, recordID: recordID(binding)) }
        var fields: [String: Any] = [:]
        if let previous = record["payload"] as? Data {
            guard let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any] else { throw GraphLedgerError.invalidData }
            fields = object
        }
        fields["format"] = 1
        fields["ledger"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= GraphLedger.maximumPayloadBytes else { throw GraphLedgerError.limitExceeded }
        record["graphID"] = binding.graphID.rawValue.uuidString as CKRecordValue
        record["payload"] = data as CKRecordValue
        return record
    }
}

extension GraphLedgerService {
    static let live = GraphLedgerService(fetch: { config, binding in
        let container = CKContainer(identifier: config.containerIdentifier)
        let database = binding.zone.scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        do { return try GraphLedgerCodec.decode(await database.record(for: GraphLedgerCodec.recordID(binding)), binding: binding) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }, save: { config, binding, value, base in
        let container = CKContainer(identifier: config.containerIdentifier)
        let database = binding.zone.scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        let record = try GraphLedgerCodec.encode(value, binding: binding, base: base)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw GraphCloudError.invalidState }
        return try GraphLedgerCodec.decode(saved.get(), binding: binding)
    })
}

extension GraphCloudSession {
    func updateLedger(_ id: GraphID, mutation: GraphLedgerMutation, expectedRevision: UUID?, date: Date = Date()) throws -> GraphLedgerStatus {
        var entry = try ensureLedger(id, writing: true)
        guard !entry.conflict else { throw GraphLedgerError.conflict }
        if let expectedRevision { guard expectedRevision == entry.value.revision else { throw GraphLedgerError.staleOperation } }
        if entry.recoveryRequired {
            switch mutation { case .resume, .interrupt, .finish: break; default: throw GraphLedgerError.recoveryRequired }
        }
        let next = try entry.value.applying(mutation, origin: ledgerClientID, date: date)
        if next == entry.value { return entry.status }
        if !entry.pending { entry.pendingBase = entry.serverRevision }
        entry.value = next; entry.pending = true; entry.failure = nil; entry.recoveryRequired = false
        try saveLedger(entry, signal: true)
        return entry.status
    }

    /// Reads exact control records independently of graph-data admission and PH.
    func synchronizeLedger(_ id: GraphID, discardPending: Bool = false) async throws -> GraphLedgerStatus {
        let entry = try ensureLedger(id, writing: false), config = configuration
        let service = try ledgerService()
        do {
            return try await withScopeControl(entry.binding.zone.scope, allowingDataLimit: true) { session in
                try await session.verifyLedgerAccount()
                for attempt in 0..<2 {
                    let remote = try await service.fetch(config, entry.binding)
                    var current = try session.checkedLedger(id, generation: entry.generation)
                    if discardPending {
                        guard let remote else {
                            if current.serverRevision != nil || current.pending { throw GraphLedgerError.unavailable }
                            return current.status
                        }
                        current.value = remote.value; current.serverRevision = remote.value.revision
                        current.pending = false; current.pendingBase = nil; current.inflight = nil; current.conflict = false
                        current.conflicting = nil
                        current.recoveryRequired = current.recoveryRequired && remote.value.current?.origin == session.ledgerClientID && remote.value.current?.state.terminal == false
                        current.failure = nil
                        try session.saveLedger(current, signal: false); return current.status
                    }
                    if !current.pending {
                        if let remote {
                            guard remote.value.revision != current.value.revision || remote.value == current.value else { throw GraphLedgerError.invalidData }
                            current.value = remote.value; current.serverRevision = remote.value.revision
                            current.conflicting = nil; current.conflict = false; current.failure = nil
                            if remote.value.current?.origin != session.ledgerClientID || remote.value.current?.state.terminal != false { current.recoveryRequired = false }
                        } else if current.serverRevision != nil {
                            current.conflict = true; current.failure = "The previously observed control record is unavailable."
                        }
                        try session.saveLedger(current, signal: false); return current.status
                    }
                    if remote?.value.revision == current.value.revision {
                        guard remote?.value == current.value else { throw GraphLedgerError.invalidData }
                        current.pending = false; current.pendingBase = nil; current.inflight = nil; current.serverRevision = remote?.value.revision
                        current.conflict = false; current.conflicting = nil; current.failure = nil
                        try session.saveLedger(current, signal: false); return current.status
                    }
                    if let inflight = current.inflight, remote?.value.revision == inflight.revision {
                        guard remote?.value == inflight else { throw GraphLedgerError.invalidData }
                        current.serverRevision = inflight.revision; current.pendingBase = inflight.revision; current.inflight = nil
                        try session.saveLedger(current, signal: false)
                    }
                    guard !current.conflict, remote?.value.revision == current.pendingBase else {
                        current.conflict = true; current.conflicting = remote?.value; current.failure = "Concurrent graph control changes require explicit resolution."
                        try session.saveLedger(current, signal: false); return current.status
                    }
                    if current.recoveryRequired { return current.status }
                    do { try session.requireLedgerUpload(id) }
                    catch GraphLedgerError.readOnly {
                        current.failure = "The graph permits incoming control updates but is read-only."
                        try session.saveLedger(current, signal: false); return current.status
                    }
                    let sent = current.value
                    current.inflight = sent
                    try session.saveLedger(current, signal: false)
                    do {
                        let saved = try await service.save(config, entry.binding, sent, remote)
                        guard saved.value == sent else { throw GraphLedgerError.invalidData }
                        var latest = try session.checkedLedger(id, generation: entry.generation)
                        latest.serverRevision = sent.revision; latest.failure = nil; latest.inflight = nil
                        if latest.value.revision == sent.revision {
                            latest.pending = false; latest.pendingBase = nil
                        } else { latest.pending = true; latest.pendingBase = sent.revision }
                        try session.saveLedger(latest, signal: false); return latest.status
                    } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 { continue }
                }
                throw GraphLedgerError.conflict
            }
        } catch {
            try? recordLedgerFailure(id, generation: entry.generation, error: error)
            throw error
        }
    }
}

extension GraphContextManager {
    package func graphLedger(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphLedgerStatus {
        try await cloud(configuration).ledgerStatus(id)
    }
    package func observeGraphLedger(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> AsyncStream<GraphLedgerStatus> {
        try await cloud(configuration).observeLedger(id)
    }
    @discardableResult package func updateGraphLedger(for id: GraphID, configuration: GraphCloudConfiguration,
        expectedRevision: UUID? = nil, mutation: GraphLedgerMutation) async throws -> GraphLedgerStatus {
        let result = try await cloud(configuration).updateLedger(id, mutation: mutation, expectedRevision: expectedRevision)
        await requestLedgerControl(configuration, ids: [id], explicit: true)
        return result
    }
    @discardableResult package func reconcileGraphLedger(for id: GraphID, configuration: GraphCloudConfiguration,
        acceptCloud: Bool = false) async throws -> GraphLedgerStatus {
        let session = try await cloud(configuration), generation = ledgerSessionGeneration(configuration)
        let result = try await session.synchronizeLedger(id, discardPending: acceptCloud)
        if ledgerSessionGeneration(configuration) == generation { await ledgerControlSuccess(id, configuration: configuration) }
        return result
    }
}
