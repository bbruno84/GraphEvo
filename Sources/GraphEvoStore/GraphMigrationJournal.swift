import Foundation

/// Detached migration identity. Fingerprints are supplied by a future validated source adapter.
package struct GraphMigrationPlan: Codable, Equatable, Sendable {
    package let scope: String
    package let migrationID: String
    package let version: Int
    package let sourceFingerprint: String
    package let destinationIdentity: String
    package let steps: [String]

    package init(scope: String, migrationID: String, version: Int, sourceFingerprint: String,
                 destinationIdentity: String, steps: [String]) {
        self.scope = scope; self.migrationID = migrationID; self.version = version
        self.sourceFingerprint = sourceFingerprint; self.destinationIdentity = destinationIdentity
        self.steps = steps
    }

    fileprivate var isValid: Bool {
        version > 0 && [scope, migrationID, sourceFingerprint, destinationIdentity].allSatisfy { !$0.isEmpty }
            && !steps.isEmpty && steps.allSatisfy { !$0.isEmpty } && Set(steps).count == steps.count
    }
}

/// Persist before an effect; a matching destination marker must be committed with that effect.
package struct GraphMigrationIntent: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let token: UUID
    package let step: String
    package let resultFingerprint: String
}

package struct GraphMigrationCheckpoint: Codable, Equatable, Sendable {
    package enum State: String, Codable, Sendable { case prepared, running, validated, completed }
    package let formatVersion: Int
    package let operationID: UUID
    package let plan: GraphMigrationPlan
    package fileprivate(set) var completed: [GraphMigrationIntent]
    package fileprivate(set) var pending: GraphMigrationIntent?
    package fileprivate(set) var state: State

    fileprivate var isValid: Bool {
        guard formatVersion == 1, plan.isValid, completed.count <= plan.steps.count,
              completed.map(\.step) == Array(plan.steps.prefix(completed.count)),
              Set(completed.map(\.token)).count == completed.count,
              completed.allSatisfy({ $0.operationID == operationID && !$0.resultFingerprint.isEmpty }) else { return false }
        if let pending {
            return state == .running && completed.count < plan.steps.count
                && pending.operationID == operationID && pending.step == plan.steps[completed.count]
                && !pending.resultFingerprint.isEmpty && !completed.contains { $0.token == pending.token }
        }
        switch state {
        case .running: return false
        case .prepared: return true
        case .validated, .completed: return completed.count == plan.steps.count
        }
    }
}

package enum GraphMigrationJournalError: Error, Equatable {
    case invalidPlan, invalidCheckpoint, planMismatch, invalidTransition, staleIntent, reconciliationRequired
}

/// Journal-only foundation. Does not execute migration bodies or own any Graph resources.
/// One process-wide actor serializes file operations; it is not an interprocess/cloud fence.
package actor GraphMigrationJournal {
    package static let shared = GraphMigrationJournal()
    private init() {}

    package func prepare(at url: URL, plan: GraphMigrationPlan) throws -> GraphMigrationCheckpoint {
        try Task.checkCancellation()
        guard plan.isValid else { throw GraphMigrationJournalError.invalidPlan }
        if FileManager.default.fileExists(atPath: url.path) { return try read(at: url, plan: plan) }
        let checkpoint = GraphMigrationCheckpoint(formatVersion: 1, operationID: UUID(), plan: plan,
                                                  completed: [], pending: nil, state: .prepared)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never overwrite an existing operation during initial reservation.
        try JSONEncoder().encode(checkpoint).write(to: url, options: .withoutOverwriting)
        return checkpoint
    }

    package func read(at url: URL, plan: GraphMigrationPlan) throws -> GraphMigrationCheckpoint {
        let checkpoint = try JSONDecoder().decode(GraphMigrationCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.isValid else { throw GraphMigrationJournalError.invalidCheckpoint }
        guard checkpoint.plan == plan else { throw GraphMigrationJournalError.planMismatch }
        return checkpoint
    }

    package func begin(at url: URL, plan: GraphMigrationPlan, step: String,
                       resultFingerprint: String) throws -> GraphMigrationIntent {
        try Task.checkCancellation()
        var checkpoint = try read(at: url, plan: plan)
        guard checkpoint.pending == nil else { throw GraphMigrationJournalError.reconciliationRequired }
        guard checkpoint.state == .prepared, checkpoint.completed.count < plan.steps.count,
              step == plan.steps[checkpoint.completed.count], !resultFingerprint.isEmpty else {
            throw GraphMigrationJournalError.invalidTransition
        }
        let intent = GraphMigrationIntent(operationID: checkpoint.operationID, token: UUID(), step: step,
                                          resultFingerprint: resultFingerprint)
        checkpoint.pending = intent; checkpoint.state = .running
        try save(checkpoint, at: url)
        return intent
    }

    /// The trusted adapter supplies the marker read from the committed destination, never a prediction.
    /// This remains callable after cancellation: recording an already committed effect must finish.
    package func confirmCommitted(at url: URL, plan: GraphMigrationPlan,
                                  marker: GraphMigrationIntent) throws -> GraphMigrationCheckpoint {
        var checkpoint = try read(at: url, plan: plan)
        if checkpoint.completed.contains(marker) { return checkpoint }
        guard checkpoint.pending == marker else { throw GraphMigrationJournalError.staleIntent }
        checkpoint.completed.append(marker); checkpoint.pending = nil; checkpoint.state = .prepared
        try save(checkpoint, at: url)
        return checkpoint
    }

    /// Only after independent reconciliation proves no effect; missing marker alone is insufficient.
    package func confirmNotApplied(at url: URL, plan: GraphMigrationPlan,
                                   intent: GraphMigrationIntent) throws -> GraphMigrationCheckpoint {
        var checkpoint = try read(at: url, plan: plan)
        guard checkpoint.pending == intent else { throw GraphMigrationJournalError.staleIntent }
        checkpoint.pending = nil; checkpoint.state = .prepared
        try save(checkpoint, at: url)
        return checkpoint
    }

    /// Semantic validation and activation are separate external operations, not inferred from row counts.
    package func markValidated(at url: URL, plan: GraphMigrationPlan) throws -> GraphMigrationCheckpoint {
        try Task.checkCancellation()
        var checkpoint = try read(at: url, plan: plan)
        guard checkpoint.state == .prepared, checkpoint.pending == nil,
              checkpoint.completed.count == plan.steps.count else { throw GraphMigrationJournalError.invalidTransition }
        checkpoint.state = .validated
        try save(checkpoint, at: url)
        return checkpoint
    }

    package func markActivated(at url: URL, plan: GraphMigrationPlan) throws -> GraphMigrationCheckpoint {
        var checkpoint = try read(at: url, plan: plan)
        guard checkpoint.state == .validated else { throw GraphMigrationJournalError.invalidTransition }
        checkpoint.state = .completed
        try save(checkpoint, at: url)
        return checkpoint
    }

    private func save(_ checkpoint: GraphMigrationCheckpoint, at url: URL) throws {
        guard checkpoint.isValid else { throw GraphMigrationJournalError.invalidCheckpoint }
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}
