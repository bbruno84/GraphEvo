import Foundation

public enum GraphMigrationState: String, Codable, Sendable { case started, done, notRequired, notExecuted, failed }
public enum GraphMigrationCompletionSynchronization: Equatable, Sendable { case local, localAndICloudKeyValueStore }
public struct GraphMigrationRecord: Codable, Equatable, Sendable {
    public let migrationID: String; public let version: Int; public let state: GraphMigrationState
    public let startedAt: Date; public let updatedAt: Date; public let errorDescription: String?
    public init(migrationID: String, version: Int, state: GraphMigrationState, startedAt: Date, updatedAt: Date, errorDescription: String? = nil) {
        self.migrationID = migrationID; self.version = version; self.state = state; self.startedAt = startedAt; self.updatedAt = updatedAt; self.errorDescription = errorDescription
    }
}
public enum GraphMigrationRequestedBy: String, Codable, Sendable { case system, migrationManager, supportCenter, user, recovery }
enum GraphMigrationDecisionReason: String, Codable { case remoteDone, noCandidate, alreadyCompatible, manualSkip }
public enum GraphMigrationResetTarget: String, Codable, Sendable { case local, remote, localAndRemote }
struct GraphMigrationForceRequest: Codable, Equatable { let operationID: String; let generation: UInt64; let migrationID: String; let version: Int; let scope: String; let requestedBy: GraphMigrationRequestedBy; let reason: String; let date: Date }
struct GraphMigrationLedgerEntry: Codable, Equatable {
    let schemaVersion: Int; let operationID: String; let generation: UInt64; let migrationID: String; let version: Int; let state: GraphMigrationState; let phase: String
    let requestedBy: GraphMigrationRequestedBy; let deviceID: String; let appVersion: String; let graphModelVersion: Int?; let backupReference: String?; let previousOperationID: String?
    let decisionReason: GraphMigrationDecisionReason?; let source: String; let date: Date; let errorDescription: String?
    let storeScope: String; let observedAt: Date?; let publishedAt: Date?
    let resetTargets: [GraphMigrationResetTarget]?; let requestReason: String?

    init(schemaVersion: Int, operationID: String, generation: UInt64, migrationID: String, version: Int, state: GraphMigrationState, phase: String, requestedBy: GraphMigrationRequestedBy, deviceID: String, appVersion: String, graphModelVersion: Int?, backupReference: String?, previousOperationID: String?, decisionReason: GraphMigrationDecisionReason?, source: String, date: Date, errorDescription: String?, storeScope: String, observedAt: Date?, publishedAt: Date?, resetTargets: [GraphMigrationResetTarget]? = nil, requestReason: String? = nil) {
        self.schemaVersion = schemaVersion; self.operationID = operationID; self.generation = generation; self.migrationID = migrationID; self.version = version; self.state = state; self.phase = phase; self.requestedBy = requestedBy; self.deviceID = deviceID; self.appVersion = appVersion; self.graphModelVersion = graphModelVersion; self.backupReference = backupReference; self.previousOperationID = previousOperationID; self.decisionReason = decisionReason; self.source = source; self.date = date; self.errorDescription = errorDescription; self.storeScope = storeScope; self.observedAt = observedAt; self.publishedAt = publishedAt; self.resetTargets = resetTargets; self.requestReason = requestReason
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, operationID, generation, migrationID, version, state, phase, requestedBy, deviceID, appVersion, graphModelVersion, backupReference, previousOperationID, decisionReason, source, date, errorDescription, storeScope, observedAt, publishedAt, resetTargets, requestReason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); operationID = try c.decode(String.self, forKey: .operationID); generation = try c.decode(UInt64.self, forKey: .generation)
        migrationID = try c.decode(String.self, forKey: .migrationID); version = try c.decode(Int.self, forKey: .version); state = try c.decode(GraphMigrationState.self, forKey: .state); phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "unknown"
        requestedBy = try c.decodeIfPresent(GraphMigrationRequestedBy.self, forKey: .requestedBy) ?? .migrationManager; deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? "unknown"; appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        graphModelVersion = try c.decodeIfPresent(Int.self, forKey: .graphModelVersion); backupReference = try c.decodeIfPresent(String.self, forKey: .backupReference); previousOperationID = try c.decodeIfPresent(String.self, forKey: .previousOperationID)
        decisionReason = try c.decodeIfPresent(GraphMigrationDecisionReason.self, forKey: .decisionReason); source = try c.decodeIfPresent(String.self, forKey: .source) ?? "localLedger"; date = try c.decode(Date.self, forKey: .date); errorDescription = try c.decodeIfPresent(String.self, forKey: .errorDescription); storeScope = try c.decodeIfPresent(String.self, forKey: .storeScope) ?? "legacy"; observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt); publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt); resetTargets = try c.decodeIfPresent([GraphMigrationResetTarget].self, forKey: .resetTargets); requestReason = try c.decodeIfPresent(String.self, forKey: .requestReason)
    }
}
private struct GraphMigrationCompactionSummary: Codable {
    var removedEventCount: Int = 0
    var removedByState: [String: Int] = [:]
    var firstRemovedGeneration: UInt64?
    var lastRemovedGeneration: UInt64?

    mutating func include(_ entry: GraphMigrationLedgerEntry) {
        removedEventCount += 1
        removedByState[entry.state.rawValue, default: 0] += 1
        firstRemovedGeneration = firstRemovedGeneration ?? entry.generation
        lastRemovedGeneration = entry.generation
    }
}
struct GraphMigrationLedgerSnapshot {
    let current: GraphMigrationRecord
    let historyCount: Int
    let compactedEventCount: Int
    let pendingForceCount: Int
    let latestEntry: GraphMigrationLedgerEntry?
}
private struct LedgerEnvelope: Codable {
    var schemaVersion: Int; var current: GraphMigrationRecord; var history: [GraphMigrationLedgerEntry]; var remoteObserved: GraphMigrationLedgerEntry?; var forcePending: [GraphMigrationForceRequest]; var compactedEventCount: Int; var compactionSummary: GraphMigrationCompactionSummary
    private enum CodingKeys: String, CodingKey { case schemaVersion, current, history, remoteObserved, forcePending, compactedEventCount, compactionSummary }
    init(schemaVersion: Int, current: GraphMigrationRecord, history: [GraphMigrationLedgerEntry], remoteObserved: GraphMigrationLedgerEntry?, forcePending: [GraphMigrationForceRequest], compactedEventCount: Int, compactionSummary: GraphMigrationCompactionSummary = .init()) { self.schemaVersion = schemaVersion; self.current = current; self.history = history; self.remoteObserved = remoteObserved; self.forcePending = forcePending; self.compactedEventCount = compactedEventCount; self.compactionSummary = compactionSummary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); current = try c.decode(GraphMigrationRecord.self, forKey: .current); history = try c.decodeIfPresent([GraphMigrationLedgerEntry].self, forKey: .history) ?? []; remoteObserved = try c.decodeIfPresent(GraphMigrationLedgerEntry.self, forKey: .remoteObserved); forcePending = try c.decodeIfPresent([GraphMigrationForceRequest].self, forKey: .forcePending) ?? []; compactedEventCount = try c.decodeIfPresent(Int.self, forKey: .compactedEventCount) ?? 0; compactionSummary = try c.decodeIfPresent(GraphMigrationCompactionSummary.self, forKey: .compactionSummary) ?? .init(removedEventCount: compactedEventCount)
    }
}
private final class LedgerRetentionResult: @unchecked Sendable {
    var error: Error?
}
enum GraphMigrationLedgerError: LocalizedError, Equatable {
    case corrupted(URL); case unsupportedSchema(Int); case invalidRemoteProjection
    var errorDescription: String? { switch self { case .corrupted(let url): return "The migration ledger at \(url.path) is corrupted or truncated."; case .unsupportedSchema(let version): return "The migration ledger schema version \(version) is not supported."; case .invalidRemoteProjection: return "The remote migration projection does not match the requested store scope or migration." } }
}

enum GraphMigrationLedger {
    private static let queue = DispatchQueue(label: "GraphEvo.migration-ledger")
    private static let retentionQueue = DispatchQueue(label: "GraphEvo.migration-ledger.retention", qos: .utility)
    private static let fm = FileManager.default; private static let schemaVersion = 3; private static let maxBytes = 2 * 1024 * 1024
    private static let kvsKey = "GraphEvo.migration.ledger.v2"
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()
    static var installationIdentifier: String {
        let key = "GraphEvo.migration.installationIdentifier"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static func validate(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws { try queue.sync { _ = try read(migrationID: migrationID, version: version, configuration: configuration) } }
    static func reconcileRemoteObservation(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration) throws {
        guard synchronization == .localAndICloudKeyValueStore else { return }
        try queue.sync {
            guard let remote = try remoteEntry(migrationID: migrationID, version: version, configuration: configuration) else { return }
            var envelope = try read(migrationID: migrationID, version: version, configuration: configuration) ?? emptyEnvelope(migrationID: migrationID, version: version)
            if envelope.history.contains(where: { isRemoteObservation($0) && $0.operationID == remote.operationID }) { return }
            if let observed = envelope.remoteObserved {
                if remote.generation < observed.generation { return }
                if isOrderedAfter(remote, observed) { envelope.remoteObserved = remote }
            } else {
                envelope.remoteObserved = remote
            }
            envelope.history.append(remote)
            retain(&envelope)
            try save(envelope, migrationID: migrationID, version: version, configuration: configuration)
        }
    }
    static func localRecord(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> GraphMigrationRecord? {
        queue.sync {
            do {
                guard var envelope = try read(migrationID: migrationID, version: version, configuration: configuration) else { return nil }
                if envelope.schemaVersion < schemaVersion {
                    envelope.schemaVersion = schemaVersion
                    try save(envelope, migrationID: migrationID, version: version, configuration: configuration)
                }
                return envelope.current
            } catch {
                GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_read_failed", message: error.localizedDescription, configuration: configuration)
                return nil
            }
        }
    }
    static func reconciledRecord(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration) -> GraphMigrationRecord? {
        queue.sync {
            do {
                guard var envelope = try read(migrationID: migrationID, version: version, configuration: configuration) else { return nil }
                if envelope.schemaVersion < schemaVersion { envelope.schemaVersion = schemaVersion }
                guard synchronization == .localAndICloudKeyValueStore else {
                    try save(envelope, migrationID: migrationID, version: version, configuration: configuration)
                    return envelope.current
                }
                if envelope.current.state == .done { publish(envelope.history.last, configuration: configuration) }
                if let remote = try remoteEntry(migrationID: migrationID, version: version, configuration: configuration), !envelope.history.contains(where: { isRemoteObservation($0) && $0.operationID == remote.operationID }), envelope.remoteObserved.map({ remote.generation >= $0.generation }) ?? true {
                    if envelope.remoteObserved.map({ isOrderedAfter(remote, $0) }) ?? true { envelope.remoteObserved = remote }
                    envelope.history.append(remote)
                    retain(&envelope)
                }
                try save(envelope, migrationID: migrationID, version: version, configuration: configuration)
                return envelope.current
            } catch {
                GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_reconciliation_failed", message: error.localizedDescription, configuration: configuration)
                return nil
            }
        }
    }

    static func markStarted(migrationID: String, version: Int, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord { try transition(migrationID: migrationID, version: version, state: .started, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, previousOperationID: previousOperationID, requestedBy: requestedBy, now: now) }
    static func markDone(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord { let r = try transition(migrationID: migrationID, version: version, state: .done, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, previousOperationID: previousOperationID, requestedBy: requestedBy, now: now); if synchronization == .localAndICloudKeyValueStore { queue.async { do { try publishLatestThrowing(migrationID: migrationID, version: version, configuration: configuration) } catch { GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_kvs_publish_failed", message: error.localizedDescription, configuration: configuration) } } }; return r }
    static func markNotRequired(migrationID: String, version: Int, configuration: GraphStoreConfiguration, reason: GraphMigrationDecisionReason = .noCandidate, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord { try transition(migrationID: migrationID, version: version, state: .notRequired, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, reason: reason, requestedBy: requestedBy, now: now) }
    static func markFailed(migrationID: String, version: Int, error: Error, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, requestedBy: GraphMigrationRequestedBy = .migrationManager, now: Date = Date()) throws -> GraphMigrationRecord { try transition(migrationID: migrationID, version: version, state: .failed, configuration: configuration, phase: phase, operationID: operationID, generation: generation, backupReference: backupReference, requestedBy: requestedBy, now: now, errorDescription: error.localizedDescription) }

    static func reset(migrationID: String, version: Int, synchronization: GraphMigrationCompletionSynchronization, configuration: GraphStoreConfiguration, target: GraphMigrationResetTarget = .localAndRemote) throws {
        let targets: Set<GraphMigrationResetTarget> = target == .localAndRemote ? [.local, .remote] : [target]
        try reset(migrationID: migrationID, version: version, configuration: configuration, targets: targets, requestedBy: .user, reason: "manual reset")
    }
    static func reset(migrationID: String, version: Int, configuration: GraphStoreConfiguration, targets: Set<GraphMigrationResetTarget>, requestedBy: GraphMigrationRequestedBy, reason: String) throws {
        let normalized = targets.contains(.localAndRemote) ? Set<GraphMigrationResetTarget>([.local, .remote]) : targets
        try queue.sync {
            let now = Date()
            var envelope = try read(migrationID: migrationID, version: version, configuration: configuration) ?? emptyEnvelope(migrationID: migrationID, version: version)
            let resetRecord = GraphMigrationRecord(migrationID: migrationID, version: version, state: .notExecuted, startedAt: now, updatedAt: now)
            let generation = (envelope.history.map(\.generation).max() ?? 0) + 1
            let operationID = UUID().uuidString
            if normalized.contains(.local) { envelope.current = resetRecord }
            envelope.history.append(entry(for: resetRecord, configuration: configuration, operationID: operationID, generation: generation, previousOperationID: envelope.history.last?.operationID, source: "reset", requestedBy: requestedBy, reason: .manualSkip, resetTargets: normalized.sorted { $0.rawValue < $1.rawValue }, requestReason: reason))
            retain(&envelope)
            try save(envelope, migrationID: migrationID, version: version, configuration: configuration)
        }
        if normalized.contains(.remote) { try queue.sync { try publishLatestThrowing(migrationID: migrationID, version: version, configuration: configuration) } }
    }
    static func requestForce(migrationID: String, version: Int, configuration: GraphStoreConfiguration, requestedBy: GraphMigrationRequestedBy = .user, reason: String) throws {
        try queue.sync { var e = try read(migrationID: migrationID, version: version, configuration: configuration) ?? emptyEnvelope(migrationID: migrationID, version: version); let generation = (e.history.map(\.generation).max() ?? 0) + 1; let operationID = UUID().uuidString; e.forcePending.append(GraphMigrationForceRequest(operationID: operationID, generation: generation, migrationID: migrationID, version: version, scope: GraphStoreScope(configuration: configuration).logicalKey, requestedBy: requestedBy, reason: reason, date: Date())); let current = e.current; e.history.append(entry(for: current, configuration: configuration, operationID: operationID, generation: generation, source: "forceRequest", requestedBy: requestedBy, requestReason: reason)); retain(&e); try save(e, migrationID: migrationID, version: version, configuration: configuration) }
    }
    static func consumeForce(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> GraphMigrationForceRequest? { try queue.sync { guard var e = try read(migrationID: migrationID, version: version, configuration: configuration), !e.forcePending.isEmpty else { return nil }; let r = e.forcePending.removeFirst(); try save(e, migrationID: migrationID, version: version, configuration: configuration); return r } }
    static func clearLocal(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws { try queue.sync { let url = recordURL(migrationID: migrationID, version: version, configuration: configuration); if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) } } }
    static func snapshot(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> GraphMigrationLedgerSnapshot? { queue.sync { do { guard let e = try read(migrationID: migrationID, version: version, configuration: configuration) else { return nil }; return GraphMigrationLedgerSnapshot(current: e.current, historyCount: e.history.count, compactedEventCount: e.compactedEventCount, pendingForceCount: e.forcePending.count, latestEntry: e.history.last) } catch { GraphMigrationLogger.log(migrationID: migrationID, level: .error, event: "migration_ledger_snapshot_failed", message: error.localizedDescription, configuration: configuration); return nil } } }
    static func stateSnapshot(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> GraphMigrationStateSnapshot { try queue.sync { let e = try read(migrationID: migrationID, version: version, configuration: configuration); let latest = e?.history.max(by: { isOrderedAfter($1, $0) }); let remote: GraphMigrationRemoteState; if let observed = e?.remoteObserved { remote = .observed(GraphMigrationRecord(migrationID: observed.migrationID, version: observed.version, state: observed.state, startedAt: observed.date, updatedAt: observed.date, errorDescription: observed.errorDescription)) } else { remote = .unknown }; return GraphMigrationStateSnapshot(storeScope: GraphStoreScope(configuration: configuration).logicalKey, localRecord: e?.current, remoteState: remote, generation: latest?.generation, operationID: latest?.operationID, phase: latest?.phase, backupReference: latest?.backupReference, errorDescription: e?.current.errorDescription, attemptCount: e?.history.count ?? 0, interrupted: e?.current.state == .started) } }
    static func history(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> [GraphMigrationLedgerEntry] { try queue.sync { try read(migrationID: migrationID, version: version, configuration: configuration)?.history ?? [] } }
    static func fileURLForTesting(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> URL { recordURL(migrationID: migrationID, version: version, configuration: configuration) }
#if DEBUG
    static func orderedAfterForTesting(_ candidate: GraphMigrationLedgerEntry, _ reference: GraphMigrationLedgerEntry) -> Bool { isOrderedAfter(candidate, reference) }
    static func reconcileRemoteEntryForTesting(_ entry: GraphMigrationLedgerEntry, configuration: GraphStoreConfiguration) throws {
        try queue.sync {
            let remote = observedRemote(entry)
            var envelope = try read(migrationID: entry.migrationID, version: entry.version, configuration: configuration) ?? emptyEnvelope(migrationID: entry.migrationID, version: entry.version)
            if envelope.history.contains(where: { isRemoteObservation($0) && $0.operationID == remote.operationID }) { return }
            if let observed = envelope.remoteObserved {
                if remote.generation < observed.generation { return }
                if isOrderedAfter(remote, observed) { envelope.remoteObserved = remote }
            } else {
                envelope.remoteObserved = remote
            }
            envelope.history.append(remote)
            retain(&envelope)
            try save(envelope, migrationID: entry.migrationID, version: entry.version, configuration: configuration)
        }
    }
#endif
}

private extension GraphMigrationLedger {
    static func transition(migrationID: String, version: Int, state: GraphMigrationState, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64? = nil, backupReference: String? = nil, previousOperationID: String? = nil, reason: GraphMigrationDecisionReason? = nil, source: String = "localLedger", requestedBy: GraphMigrationRequestedBy = .migrationManager, resetTargets: [GraphMigrationResetTarget]? = nil, requestReason: String? = nil, now: Date = Date(), errorDescription: String? = nil) throws -> GraphMigrationRecord {
        try queue.sync { let old = try read(migrationID: migrationID, version: version, configuration: configuration); let previous = old?.current; let record = GraphMigrationRecord(migrationID: migrationID, version: version, state: state, startedAt: previous?.startedAt ?? now, updatedAt: now, errorDescription: errorDescription); var e = old ?? emptyEnvelope(migrationID: migrationID, version: version, current: record); let next = generation ?? ((e.history.map(\.generation).max() ?? 0) + 1); e.schemaVersion = schemaVersion; e.current = record; e.history.append(entry(for: record, configuration: configuration, phase: phase, operationID: operationID, generation: next, backupReference: backupReference, previousOperationID: previousOperationID ?? e.history.last?.operationID, source: source, requestedBy: requestedBy, reason: reason, resetTargets: resetTargets, requestReason: requestReason)); retain(&e); try save(e, migrationID: migrationID, version: version, configuration: configuration); return record }
    }
    static func read(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> LedgerEnvelope? {
        let url = recordURL(migrationID: migrationID, version: version, configuration: configuration)
        let legacyURL = legacyRecordURL(migrationID: migrationID, version: version, configuration: configuration)
        let candidate = fm.fileExists(atPath: url.path)
            ? url
            : (configuration.environment == .production && fm.fileExists(atPath: legacyURL.path) ? legacyURL : nil)
        guard let candidate else { return nil }
        let data: Data
        do { data = try Data(contentsOf: candidate) } catch { throw GraphMigrationLedgerError.corrupted(candidate) }
        if let e = try? decoder.decode(LedgerEnvelope.self, from: data) { guard e.schemaVersion <= schemaVersion else { throw GraphMigrationLedgerError.unsupportedSchema(e.schemaVersion) }; return e }
        if let legacy = try? decoder.decode(GraphMigrationRecord.self, from: data) { return LedgerEnvelope(schemaVersion: 0, current: legacy, history: [entry(for: legacy, configuration: configuration, source: "legacyLedger")], remoteObserved: nil, forcePending: [], compactedEventCount: 0) }
        throw GraphMigrationLedgerError.corrupted(candidate)
    }
    static func emptyEnvelope(migrationID: String, version: Int, current: GraphMigrationRecord? = nil) -> LedgerEnvelope { let now = Date(); return LedgerEnvelope(schemaVersion: schemaVersion, current: current ?? GraphMigrationRecord(migrationID: migrationID, version: version, state: .notExecuted, startedAt: now, updatedAt: now), history: [], remoteObserved: nil, forcePending: [], compactedEventCount: 0) }
    static func save(_ e: LedgerEnvelope, migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws {
        let url = recordURL(migrationID: migrationID, version: version, configuration: configuration)
        try writeAtomically(e, to: url)
        try performRetention(in: url.deletingLastPathComponent())
    }
    static func writeAtomically(_ envelope: LedgerEnvelope, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard fm.createFile(atPath: temporaryURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: encoder.encode(envelope))
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporaryURL) }
            else { try fm.moveItem(at: temporaryURL, to: url) }
        } catch {
            try? fm.removeItem(at: temporaryURL)
            throw error
        }
    }
    static func enforceStoreRetention(in directory: URL) throws {
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
        var envelopes: [URL: LedgerEnvelope] = [:]
        var total = 0
        for url in urls {
            let data = try Data(contentsOf: url)
            total += data.count
            guard let envelope = try? decoder.decode(LedgerEnvelope.self, from: data) else { throw GraphMigrationLedgerError.corrupted(url) }
            envelopes[url] = envelope
        }
        while total > maxBytes {
            guard let candidate = envelopes
                .filter({ $0.value.history.count > 2 })
                .min(by: { ($0.value.history.first?.date ?? .distantFuture) < ($1.value.history.first?.date ?? .distantFuture) }) else { break }
            var envelope = candidate.value
            let oldSize = (try? Data(contentsOf: candidate.key).count) ?? 0
            let removed = envelope.history.removeFirst()
            envelope.compactionSummary.include(removed)
            envelope.compactedEventCount = envelope.compactionSummary.removedEventCount
            try writeAtomically(envelope, to: candidate.key)
            let newSize = (try? Data(contentsOf: candidate.key).count) ?? oldSize
            total -= max(0, oldSize - newSize)
            envelopes[candidate.key] = envelope
        }
    }
    static func performRetention(in directory: URL) throws {
        guard Thread.isMainThread else {
            try enforceStoreRetention(in: directory)
            return
        }
        let completion = DispatchSemaphore(value: 0)
        let result = LedgerRetentionResult()
        retentionQueue.async {
            do { try enforceStoreRetention(in: directory) }
            catch { result.error = error }
            completion.signal()
        }
        completion.wait()
        if let error = result.error { throw error }
    }
    static func retain(_ e: inout LedgerEnvelope) { while e.history.count > 2, let data = try? encoder.encode(e), data.count > maxBytes { let removed = e.history.removeFirst(); e.compactionSummary.include(removed); e.compactedEventCount = e.compactionSummary.removedEventCount } }
    static func entry(for r: GraphMigrationRecord, configuration: GraphStoreConfiguration, phase: String = "unknown", operationID: String = UUID().uuidString, generation: UInt64 = 0, backupReference: String? = nil, previousOperationID: String? = nil, source: String = "localLedger", requestedBy: GraphMigrationRequestedBy = .migrationManager, reason: GraphMigrationDecisionReason? = nil, resetTargets: [GraphMigrationResetTarget]? = nil, requestReason: String? = nil) -> GraphMigrationLedgerEntry { GraphMigrationLedgerEntry(schemaVersion: schemaVersion, operationID: operationID, generation: generation == 0 ? UInt64(Date().timeIntervalSince1970 * 1000) : generation, migrationID: r.migrationID, version: r.version, state: r.state, phase: phase, requestedBy: requestedBy, deviceID: installationIdentifier, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", graphModelVersion: configuration.requiredGraphModelVersion, backupReference: backupReference, previousOperationID: previousOperationID, decisionReason: reason, source: source, date: r.updatedAt, errorDescription: r.errorDescription, storeScope: GraphStoreScope(configuration: configuration).logicalKey, observedAt: source == "remoteKVS" ? Date() : nil, publishedAt: source == "remoteKVS" ? nil : r.updatedAt, resetTargets: resetTargets, requestReason: requestReason) }
    static func logicalKey(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> String { let s = GraphStoreScope(configuration: configuration); return "\(s.logicalKey)|\(migrationID)|\(version)" }
    static func publish(_ item: GraphMigrationLedgerEntry?, configuration: GraphStoreConfiguration) { guard let item else { return }; do { let data = try encoder.encode(item); var values = (NSUbiquitousKeyValueStore.default.object(forKey: kvsKey) as? [String: Any]) ?? [:]; values[logicalKey(migrationID: item.migrationID, version: item.version, configuration: configuration)] = data; NSUbiquitousKeyValueStore.default.set(values, forKey: kvsKey) } catch { GraphMigrationLogger.log(migrationID: item.migrationID, level: .error, event: "migration_kvs_encode_failed", message: error.localizedDescription, configuration: configuration) } }
    static func publishLatestThrowing(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws { guard let item = try read(migrationID: migrationID, version: version, configuration: configuration)?.history.last else { return }; let data = try encoder.encode(item); var values = (NSUbiquitousKeyValueStore.default.object(forKey: kvsKey) as? [String: Any]) ?? [:]; values[logicalKey(migrationID: migrationID, version: version, configuration: configuration)] = data; NSUbiquitousKeyValueStore.default.set(values, forKey: kvsKey) }
    static func remoteEntry(migrationID: String, version: Int, configuration: GraphStoreConfiguration) throws -> GraphMigrationLedgerEntry? { if let values = NSUbiquitousKeyValueStore.default.object(forKey: kvsKey) as? [String: Any], let data = values[logicalKey(migrationID: migrationID, version: version, configuration: configuration)] as? Data { let item = try decoder.decode(GraphMigrationLedgerEntry.self, from: data); guard item.migrationID == migrationID, item.version == version, item.storeScope == GraphStoreScope(configuration: configuration).logicalKey else { throw GraphMigrationLedgerError.invalidRemoteProjection }; return observedRemote(item) }; guard configuration.environment == .production, let legacy = NSUbiquitousKeyValueStore.default.dictionary(forKey: legacyCloudKey(migrationID: migrationID, version: version, configuration: configuration)), legacy["status"] as? String == GraphMigrationState.done.rawValue else { return nil }; let date = legacy["completedAt"] as? Date ?? Date(); let item = entry(for: GraphMigrationRecord(migrationID: migrationID, version: version, state: .done, startedAt: date, updatedAt: date), configuration: configuration, source: "legacyKVS", reason: .remoteDone); publish(item, configuration: configuration); return observedRemote(item, source: "legacyKVS") }
    static func observedRemote(_ item: GraphMigrationLedgerEntry, source: String = "remoteKVS") -> GraphMigrationLedgerEntry { GraphMigrationLedgerEntry(schemaVersion: item.schemaVersion, operationID: item.operationID, generation: item.generation, migrationID: item.migrationID, version: item.version, state: item.state, phase: item.phase, requestedBy: item.requestedBy, deviceID: item.deviceID, appVersion: item.appVersion, graphModelVersion: item.graphModelVersion, backupReference: item.backupReference, previousOperationID: item.previousOperationID, decisionReason: item.decisionReason, source: source, date: item.date, errorDescription: item.errorDescription, storeScope: item.storeScope, observedAt: Date(), publishedAt: item.publishedAt ?? item.date, resetTargets: item.resetTargets, requestReason: item.requestReason) }
    static func isOrderedAfter(_ candidate: GraphMigrationLedgerEntry, _ reference: GraphMigrationLedgerEntry) -> Bool {
        if candidate.generation != reference.generation { return candidate.generation > reference.generation }
        if candidate.deviceID != reference.deviceID { return candidate.deviceID > reference.deviceID }
        return candidate.operationID > reference.operationID
    }
    static func isRemoteObservation(_ entry: GraphMigrationLedgerEntry) -> Bool { entry.source == "remoteKVS" || entry.source == "legacyKVS" }
    static func legacyCloudKey(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> String { let identity = [configuration.cloudKitContainerIdentifier ?? "local", configuration.name, migrationID, String(version)].joined(separator: "|"); var hash: UInt64 = 14_695_981_039_346_656_037; for byte in identity.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }; return "GraphMigration.done.\(String(format: "%016llx", hash))" }
    static func recordURL(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> URL { GraphMigrationManager.defaultBackupRoot(for: configuration).appendingPathComponent("ledger", isDirectory: true).appendingPathComponent(scopeComponent(configuration), isDirectory: true).appendingPathComponent("\(safeComponent(migrationID))-v\(version).json") }
    static func legacyRecordURL(migrationID: String, version: Int, configuration: GraphStoreConfiguration) -> URL { GraphMigrationManager.defaultBackupRoot(for: configuration).appendingPathComponent("ledger", isDirectory: true).appendingPathComponent("\(safeComponent(migrationID))-v\(version).json") }
    static func scopeComponent(_ configuration: GraphStoreConfiguration) -> String { var hash: UInt64 = 14_695_981_039_346_656_037; for byte in GraphStoreScope(configuration: configuration).logicalKey.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }; return String(format: "%016llx", hash) }
    static func safeComponent(_ value: String) -> String { let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")); return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("_") }).prefix(80).description }
}
