import Foundation
import Testing
import GraphEvoStore

@Suite struct GraphMigrationJournalTests {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationJournal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("journal.json")
    }
    private func plan(source: String = "source-v1") -> GraphMigrationPlan {
        GraphMigrationPlan(scope: "test-store", migrationID: "v1-to-v2", version: 1,
                           sourceFingerprint: source, destinationIdentity: "destination-v2", steps: ["objects", "links"])
    }

    @Test func committedBeforeCheckpointRecoveryDoesNotRepeatEffect() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        let first = try await journal.prepare(at: url, plan: plan)
        let marker = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "objects-hash")
        // Simulate a crash after the destination committed this marker but before journal confirmation.
        let reopened = try await journal.prepare(at: url, plan: plan)
        #expect(reopened.operationID == first.operationID && reopened.pending == marker)
        await #expect(throws: GraphMigrationJournalError.reconciliationRequired) {
            try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "objects-hash")
        }
        let recovered = try await journal.confirmCommitted(at: url, plan: plan, marker: marker)
        #expect(recovered.completed == [marker])
        #expect(try await journal.confirmCommitted(at: url, plan: plan, marker: marker) == recovered)
        let links = try await journal.begin(at: url, plan: plan, step: "links", resultFingerprint: "links-hash")
        _ = try await journal.confirmCommitted(at: url, plan: plan, marker: links)
        #expect(try await journal.markValidated(at: url, plan: plan).state == .validated)
        #expect(try await journal.markActivated(at: url, plan: plan).state == .completed)
        #expect(try await journal.prepare(at: url, plan: plan).state == .completed)
    }

    @Test func sourceMismatchAndOutOfOrderActivationPreserveOriginalBytes() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        let original = try Data(contentsOf: url)
        await #expect(throws: GraphMigrationJournalError.planMismatch) {
            try await journal.prepare(at: url, plan: self.plan(source: "different-source"))
        }
        await #expect(throws: GraphMigrationJournalError.invalidTransition) {
            try await journal.markActivated(at: url, plan: plan)
        }
        await #expect(throws: GraphMigrationJournalError.invalidTransition) {
            try await journal.markValidated(at: url, plan: plan)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func staleMarkerCannotConfirmAnotherAttempt() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        let old = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "hash")
        _ = try await journal.confirmNotApplied(at: url, plan: plan, intent: old)
        let next = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "hash")
        #expect(next.token != old.token)
        await #expect(throws: GraphMigrationJournalError.staleIntent) {
            try await journal.confirmCommitted(at: url, plan: plan, marker: old)
        }
        #expect(try await journal.read(at: url, plan: plan).pending == next)
    }

    @Test func concurrentBeginAdmitsOnlyOneIntent() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "hash"); return true }
                    catch GraphMigrationJournalError.reconciliationRequired { return false }
                    catch { Issue.record(error); return false }
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        #expect(admitted == 1)
    }

    @Test func malformedAndFutureJournalsAreNeverReplaced() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["formatVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: url)
        await #expect(throws: GraphMigrationJournalError.invalidCheckpoint) { try await journal.prepare(at: url, plan: plan) }
        #expect(try Data(contentsOf: url) == future)
        try Data("corrupt".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await journal.prepare(at: url, plan: plan) }
        #expect(try Data(contentsOf: url) == Data("corrupt".utf8))
    }

    @Test func unreadableCheckpointCannotBeConfirmedOrSilentlyRecreated() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        let marker = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "hash")
        let pending = try Data(contentsOf: url)
        try Data("unreadable".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await journal.confirmCommitted(at: url, plan: plan, marker: marker) }
        #expect(try Data(contentsOf: url) == Data("unreadable".utf8))
        // Restoring the protected checkpoint recovers the exact outstanding intent.
        try pending.write(to: url)
        #expect(try await journal.read(at: url, plan: plan).pending == marker)
    }

    @Test func cancellationRefusesNewEffectsButCanRecordAnExistingCommit() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        let marker = try await journal.begin(at: url, plan: plan, step: "objects", resultFingerprint: "hash")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await journal.confirmCommitted(at: url, plan: plan, marker: marker)
            await #expect(throws: CancellationError.self) {
                try await journal.begin(at: url, plan: plan, step: "links", resultFingerprint: "links-hash")
            }
        }
        try await task.value
        let state = try await journal.read(at: url, plan: plan)
        #expect(state.completed == [marker] && state.pending == nil)
    }


    @Test func inconsistentStateCannotMasqueradeAsCompletedMigration() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        _ = try await journal.prepare(at: url, plan: plan)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for state in ["running", "validated", "completed"] {
            json["state"] = state
            let invalid = try JSONSerialization.data(withJSONObject: json)
            try invalid.write(to: url)
            await #expect(throws: GraphMigrationJournalError.invalidCheckpoint) {
                try await journal.read(at: url, plan: plan)
            }
            #expect(try Data(contentsOf: url) == invalid)
        }
    }

    @Test func invalidPlanAndSkippedStepCannotStartAnEffect() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GraphMigrationJournal.shared, plan = plan()
        let invalid = GraphMigrationPlan(scope: "test", migrationID: "m", version: 1,
            sourceFingerprint: "s", destinationIdentity: "d", steps: ["duplicate", "duplicate"])
        await #expect(throws: GraphMigrationJournalError.invalidPlan) { try await journal.prepare(at: url, plan: invalid) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try await journal.prepare(at: url, plan: plan)
        await #expect(throws: GraphMigrationJournalError.invalidTransition) {
            try await journal.begin(at: url, plan: plan, step: "links", resultFingerprint: "hash")
        }
        #expect(try await journal.read(at: url, plan: plan).pending == nil)
    }

}
