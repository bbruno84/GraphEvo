import Foundation
import Testing
import GraphEvoModel
import GraphEvoStore
@testable import GraphEvo

private final class MigrationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private enum MigrationStop: Error { case interrupted, unexpectedCallback }

private actor MigrationReadGate {
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var readers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrived = true
        let waiting = arrivals; arrivals.removeAll(); waiting.forEach { $0.resume() }
        await withCheckedContinuation { readers.append($0) }
    }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { let waiting = readers; readers.removeAll(); waiting.forEach { $0.resume() } }
}

@Suite(.timeLimit(.minutes(2))) struct GraphDataMigrationTests {
    private func fixture(version: Int64? = 1, kind: GraphNodeKind = .entity) async throws -> (URL, GraphDataMigrationLaboratory, [GraphDataMigrationRow]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lab = try await GraphDataMigrationLaboratory.open(at: root.appendingPathComponent("Source/Store.sqlite"))
        let graphID = await lab.graphID
        let endpoints: GraphEndpoints
        switch kind { case .entity: endpoints = .entity; case .relationship: endpoints = .relationship(subject: nil, object: nil); case .action: endpoints = .action(subjects: [], objects: []) }
        let rows = try (0..<2).map { n in
            try GraphDataMigrationRow(record: GraphRecord(id: GraphNodeID(graphID: graphID), type: "migration.item", endpoints: endpoints,
                properties: ["old": .integer(Int64(n)), "unknown": .object(["max": .unsignedInteger(UInt64.max), "null": .null, "bytes": .data(Data([0,255]))])],
                tags: ["keep"], createdDate: n == 0 ? nil : Date(timeIntervalSince1970: 1_700_000_000)), dataVersion: version)
        }
        do { try await lab.seed(rows) }
        catch { try? await lab.close(); throw error }
        return (root, lab, rows)
    }

    private func definition(_ rows: [GraphDataMigrationRow], calls: MigrationCalls, from: Int64? = 1, to: Int64 = 2,
                            budget: Int = 1_048_576) throws -> GraphDataMigrationDefinition {
        try GraphDataMigrationDefinition(id: "example.rename", revision: 1, type: "migration.item", kind: rows[0].record.endpoints.kind,
            sourceVersion: from, targetVersion: to, records: rows.map { $0.record.id }, maximumArtifactBytes: budget) { record in
                _ = calls.increment()
                return try GraphRecordPatch(id: record.id, properties: ["new": .set(record.properties["old"]!), "old": .remove],
                                            addingTags: ["converted"]).applying(to: record)
            }
    }

    private func checkpoint(_ root: URL) throws -> GraphMigrationCheckpoint {
        try JSONDecoder().decode(GraphMigrationCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("Artifacts/journal.json")))
    }

    @Test(arguments: [GraphEvoModel.GraphNodeKind.entity, .relationship, .action])
    func versionValuesAndEffectCommitTogetherForEveryNodeKind(kind: GraphEvoModel.GraphNodeKind) async throws {
        let (root, lab, rows) = try await fixture(kind: kind)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let calls = MigrationCalls(), adapter = try await lab.adapter(), migration = try definition(rows, calls: calls)
            let result = try await GraphDataMigrationManager.shared.run(migration, adapter: adapter, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(result.state == .completed && !result.recovered && result.recordCount == 2)
            let after = try await adapter.snapshot(rows.map { $0.record.id })
            #expect(after.allSatisfy { $0.dataVersion == 2 && $0.record.properties["old"] == nil && $0.record.tags == ["keep", "converted"] })
            #expect(after.map { $0.record.properties["unknown"] } == rows.map { $0.record.properties["unknown"] })
            #expect(calls.value == 2)
            let cp = try checkpoint(root)
            #expect(cp.state == .completed && cp.pending == nil && cp.completed.count == 1)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func commitBeforeCheckpointRecoversAfterNativeReopenWithoutCallingConsumerAgain() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = MigrationCalls(), base = try await lab.adapter(), migration = try definition(rows, calls: calls)
        let ambiguous = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity, snapshot: base.snapshot,
            publish: { publication, intent in _ = try await base.publish(publication, intent); throw MigrationStop.interrupted }, reconcile: base.reconcile)
        do {
            await #expect(throws: MigrationStop.self) {
                try await GraphDataMigrationManager.shared.run(migration, adapter: ambiguous, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            #expect(try checkpoint(root).pending != nil)
            #expect(try await base.snapshot(rows.map { $0.record.id }).allSatisfy { $0.dataVersion == 2 && $0.record.properties["new"] != nil })
            try await lab.close()
        } catch { try? await lab.close(); throw error }
        // An unaware public facade must refuse this laboratory's versioned data.
        do {
            let unaware = try await GraphDatabase.open(at: root.appendingPathComponent("Source/Store.sqlite"), schema: .nativeIdentity)
            try await unaware.close(); Issue.record("Unaware public native opener admitted laboratory data.")
        } catch GraphStoreError.persistence { }
        let reopened = try await GraphDataMigrationLaboratory.open(at: root.appendingPathComponent("Source/Store.sqlite"), graphID: rows[0].record.id.graphID)
        do {
            let adapter = try await reopened.adapter()
            let forbidden = GraphDataMigrationAdapter(destinationIdentity: adapter.destinationIdentity, snapshot: adapter.snapshot,
                publish: { _, _ in throw MigrationStop.unexpectedCallback }, reconcile: adapter.reconcile)
            let recovered = try await GraphDataMigrationManager.shared.run(migration, adapter: forbidden, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(recovered.state == .completed && recovered.recovered && calls.value == 2)
            let completedAgain = try await GraphDataMigrationManager.shared.run(migration, adapter: forbidden, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(completedAgain.operationID == recovered.operationID && calls.value == 2)
            #expect(try checkpoint(root).completed.count == 1)
            try await reopened.close()
        } catch { try? await reopened.close(); throw error }
    }

    @Test func unchangedPreimageRequiresExplicitRetryAndPublishesPreparedDataWithoutReplayingTransform() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let calls = MigrationCalls(), base = try await lab.adapter(), migration = try definition(rows, calls: calls)
            let stopped = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity, snapshot: base.snapshot,
                publish: { _, _ in throw MigrationStop.interrupted }, reconcile: base.reconcile)
            await #expect(throws: MigrationStop.self) { try await GraphDataMigrationManager.shared.run(migration, adapter: stopped, artifactsAt: root.appendingPathComponent("Artifacts")) }
            let retry = try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(retry.state == .retryRequired && calls.value == 2)
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            let completed = try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(completed.state == .completed && calls.value == 2 && completed.operationID == retry.operationID)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func staleSourceAndExistingMarkerWithChangedPostimageAreNotMisclassified() async throws {
        for afterCommit in [false, true] {
            let (root, lab, rows) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let calls = MigrationCalls(), base = try await lab.adapter(), migration = try definition(rows, calls: calls)
                let racing = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity, snapshot: base.snapshot, publish: { publication, intent in
                    if afterCommit { _ = try await base.publish(publication, intent) }
                    try await lab.edit(GraphRecordPatch(id: rows[0].record.id, properties: ["changed": .set(.boolean(true))]))
                    if afterCommit { throw MigrationStop.interrupted }
                    return try await base.publish(publication, intent)
                }, reconcile: base.reconcile)
                await #expect(throws: (any Error).self) { try await GraphDataMigrationManager.shared.run(migration, adapter: racing, artifactsAt: root.appendingPathComponent("Artifacts")) }
                await #expect(throws: GraphDataMigrationError.reconciliationRequired) {
                    try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
                }
                let cp = try checkpoint(root)
                #expect(cp.pending != nil && cp.completed.isEmpty && calls.value == 2)
                #expect(try await base.snapshot([rows[0].record.id]).first?.record.properties["changed"] == .boolean(true))
                try await lab.close()
            } catch { try? await lab.close(); throw error }
        }
    }

    @Test(arguments: [Optional<Int64>.none, 0, 9])
    func undeclaredOldAndFutureFormatsAreNotGuessed(actual: Int64?) async throws {
        let (root, lab, rows) = try await fixture(version: actual)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let calls = MigrationCalls(), base = try await lab.adapter()
            await #expect(throws: GraphDataMigrationError.sourceFormatMismatch) {
                try await GraphDataMigrationManager.shared.run(definition(rows, calls: calls), adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            #expect(calls.value == 0 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts").path))
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func undeclaredToExplicitZeroIsADeclaredConversion() async throws {
        let (root, lab, rows) = try await fixture(version: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter()
            _ = try await GraphDataMigrationManager.shared.run(definition(rows, calls: MigrationCalls(), from: nil, to: 0), adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(try await base.snapshot(rows.map { $0.record.id }).allSatisfy { $0.dataVersion == 0 })
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func throwingConsumerAndBudgetRefusalDoNotPublishPartialRecords() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter(), calls = MigrationCalls()
            let throwing = try GraphDataMigrationDefinition(id: "throwing", revision: 1, type: "migration.item", kind: .entity,
                sourceVersion: 1, targetVersion: 2, records: rows.map { $0.record.id }) { record in
                    if calls.increment() == 2 { throw MigrationStop.interrupted }
                    return try GraphRecordPatch(id: record.id, properties: ["partial": .set(.boolean(true))]).applying(to: record)
                }
            await #expect(throws: MigrationStop.self) { try await GraphDataMigrationManager.shared.run(throwing, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts")) }
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts").path))
            await #expect(throws: GraphDataMigrationError.budgetExceeded) {
                try await GraphDataMigrationManager.shared.run(definition(rows, calls: calls, budget: 32), adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            #expect(calls.value == 2)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func cancellationAfterSaveFinishesDurableCompletion() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter(), migration = try definition(rows, calls: MigrationCalls())
            let cancelAfter = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity, snapshot: base.snapshot,
                publish: { publication, intent in
                    let marker = try await base.publish(publication, intent)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return marker
                }, reconcile: base.reconcile)
            let result = try await Task {
                try await GraphDataMigrationManager.shared.run(migration, adapter: cancelAfter, artifactsAt: root.appendingPathComponent("Artifacts"))
            }.value
            #expect(result.state == .completed)
            #expect(try checkpoint(root).state == .completed)
            #expect(try await base.snapshot(rows.map { $0.record.id }).allSatisfy { $0.dataVersion == 2 })
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func corruptOrWrongDestinationArtifactsArePreservedAndRefused() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter(), calls = MigrationCalls(), migration = try definition(rows, calls: calls)
            _ = try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            let foreign = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity + ":other", snapshot: base.snapshot, publish: base.publish, reconcile: base.reconcile)
            await #expect(throws: GraphDataMigrationError.destinationMismatch) {
                try await GraphDataMigrationManager.shared.run(migration, adapter: foreign, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            let path = root.appendingPathComponent("Artifacts/prepared-data.json"), corrupt = Data("not-json".utf8)
            try corrupt.write(to: path)
            await #expect(throws: (any Error).self) { try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts")) }
            #expect(try Data(contentsOf: path) == corrupt)
            let cp = try checkpoint(root)
            #expect(calls.value == 2 && cp.state == .completed)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test(arguments: [false, true]) func structuralTransformationIsRejectedBeforeAnyEffect(changesVersion: Bool) async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter()
            let invalid = try GraphDataMigrationDefinition(id: "invalid", revision: 1, type: "migration.item", kind: .entity,
                sourceVersion: 1, targetVersion: 2, records: rows.map { $0.record.id }) { record in
                    try GraphRecord(id: record.id, type: changesVersion ? record.type : "another.type",
                        endpoints: record.endpoints, properties: record.properties, tags: record.tags,
                        groups: record.groups, createdDate: record.createdDate,
                        dataVersion: changesVersion ? 9 : record.dataVersion)
                }
            await #expect(throws: GraphDataMigrationError.invalidTransformation) {
                try await GraphDataMigrationManager.shared.run(invalid, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts").path))
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func cancellationBeforePublicationLeavesAReconciledExplicitRetry() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter(), migration = try definition(rows, calls: MigrationCalls())
            let cancelled = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity, snapshot: base.snapshot,
                publish: { publication, intent in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await base.publish(publication, intent)
                }, reconcile: base.reconcile)
            await #expect(throws: CancellationError.self) {
                try await Task { try await GraphDataMigrationManager.shared.run(migration, adapter: cancelled, artifactsAt: root.appendingPathComponent("Artifacts")) }.value
            }
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            #expect(try checkpoint(root).pending != nil)
            let retry = try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(retry.state == .retryRequired)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func nativeRejectionOfALaterRecordRollsBackEarlierValuesAndVersion() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let base = try await lab.adapter(), calls = MigrationCalls()
            let invalid = try GraphDataMigrationDefinition(id: "native-rejection", revision: 1, type: "migration.item", kind: .entity,
                sourceVersion: 1, targetVersion: 2, records: rows.map { $0.record.id }) { record in
                    let key = calls.increment() == 2 ? "__graphevo_v2.forbidden" : "changed"
                    return try GraphRecordPatch(id: record.id, properties: [key: .set(.boolean(true))]).applying(to: record)
                }
            await #expect(throws: GraphStoreError.self) {
                try await GraphDataMigrationManager.shared.run(invalid, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            #expect(try await base.snapshot(rows.map { $0.record.id }) == rows)
            #expect(try checkpoint(root).pending != nil)
            let retry = try await GraphDataMigrationManager.shared.run(invalid, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            #expect(retry.state == .retryRequired && calls.value == 2)
            try await lab.close()
        } catch { try? await lab.close(); throw error }
    }

    @Test func sameArtifactConcurrentRunIsRejectedWithoutTimingAssumptions() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await lab.adapter(), gate = MigrationReadGate(), migration = try definition(rows, calls: MigrationCalls())
        let held = GraphDataMigrationAdapter(destinationIdentity: base.destinationIdentity,
            snapshot: { ids in await gate.hold(); return try await base.snapshot(ids) }, publish: base.publish, reconcile: base.reconcile)
        let first = Task { try await GraphDataMigrationManager.shared.run(migration, adapter: held, artifactsAt: root.appendingPathComponent("Artifacts")) }
        await gate.waitForArrival()
        do {
            await #expect(throws: GraphDataMigrationError.busy) {
                try await GraphDataMigrationManager.shared.run(migration, adapter: base, artifactsAt: root.appendingPathComponent("Artifacts"))
            }
            await gate.release()
            #expect(try await first.value.state == .completed)
            try await lab.close()
        } catch { await gate.release(); _ = try? await first.value; try? await lab.close(); throw error }
    }

    @Test func completeClosedSourceDirectoryRemainsRecoverableAfterConversion() async throws {
        let (root, lab, rows) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await lab.close()
        let backup = root.appendingPathComponent("ProtectedSource")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Source"), to: backup)
        let destination = try await GraphDataMigrationLaboratory.open(at: root.appendingPathComponent("Source/Store.sqlite"), graphID: rows[0].record.id.graphID)
        do {
            _ = try await GraphDataMigrationManager.shared.run(definition(rows, calls: MigrationCalls()), adapter: destination.adapter(), artifactsAt: root.appendingPathComponent("Artifacts"))
            try await destination.close()
        } catch { try? await destination.close(); throw error }
        let protected = try await GraphDataMigrationLaboratory.open(at: backup.appendingPathComponent("Store.sqlite"), graphID: rows[0].record.id.graphID)
        do {
            let adapter = try await protected.adapter()
            #expect(try await adapter.snapshot(rows.map { $0.record.id }) == rows)
            try await protected.close()
        } catch { try? await protected.close(); throw error }
    }
}
