//
//  GraphMigrationLedgerTests.swift
//  GraphTests
//

import XCTest
@testable import GraphEvo

final class GraphMigrationLedgerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configuration: GraphStoreConfiguration!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        var configuration = GraphStoreConfiguration()
        configuration.name = "MigrationLedgerTests-\(UUID().uuidString)"
        configuration.location = temporaryDirectory
        self.configuration = configuration
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        configuration = nil
    }

    func testStartedThenDonePersistsTerminalState() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(30)

        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration,
            now: startedAt
        )
        let started = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(started?.state, .started)
        XCTAssertEqual(started?.startedAt, startedAt)

        _ = try GraphMigrationLedger.markDone(
            migrationID: "test-migration",
            version: 1,
            synchronization: .local,
            configuration: configuration,
            now: completedAt
        )
        let done = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.startedAt, startedAt)
        XCTAssertEqual(done?.updatedAt, completedAt)
    }

    func testStartedThenFailedStoresHandledError() throws {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Expected migration failure" }
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let failedAt = startedAt.addingTimeInterval(10)
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration,
            now: startedAt
        )
        _ = try GraphMigrationLedger.markFailed(
            migrationID: "test-migration",
            version: 1,
            error: ExpectedError(),
            configuration: configuration,
            now: failedAt
        )

        let failed = GraphMigrationLedger.localRecord(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.startedAt, startedAt)
        XCTAssertEqual(failed?.updatedAt, failedAt)
        XCTAssertEqual(failed?.errorDescription, "Expected migration failure")
    }

    func testResetRecordsNotExecutedWithoutRemovingHistory() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        try GraphMigrationLedger.reset(
            migrationID: "test-migration",
            version: 1,
            synchronization: .local,
            configuration: configuration
        )

        XCTAssertEqual(
            GraphMigrationLedger.localRecord(migrationID: "test-migration", version: 1, configuration: configuration)?.state,
            .notExecuted
        )
    }

    func testSkippedAttemptCanClearStartedWithoutTouchingCloudState() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        try GraphMigrationLedger.clearLocal(
            migrationID: "test-migration",
            version: 1,
            configuration: configuration
        )

        XCTAssertNil(
            GraphMigrationLedger.localRecord(
                migrationID: "test-migration",
                version: 1,
                configuration: configuration
            )
        )
    }

    func testForceIsConsumedOnceAndRetainedInProjection() throws {
        try GraphMigrationLedger.requestForce(migrationID: "forced", version: 1, configuration: configuration, reason: "test")
        let first = try GraphMigrationLedger.consumeForce(migrationID: "forced", version: 1, configuration: configuration)
        XCTAssertNotNil(first)
        XCTAssertNil(try GraphMigrationLedger.consumeForce(migrationID: "forced", version: 1, configuration: configuration))
        XCTAssertEqual(GraphMigrationLedger.snapshot(migrationID: "forced", version: 1, configuration: configuration)?.pendingForceCount, 0)
    }

    func testStoresWithSameMigrationIDHaveIndependentLedgers() throws {
        var other = configuration!
        other.location = temporaryDirectory.appendingPathComponent("other", isDirectory: true)
        _ = try GraphMigrationLedger.markDone(migrationID: "same", version: 1, synchronization: .local, configuration: configuration)
        _ = try GraphMigrationLedger.markStarted(migrationID: "same", version: 1, configuration: other)
        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "same", version: 1, configuration: configuration)?.state, .done)
        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "same", version: 1, configuration: other)?.state, .started)
    }

    func testDevelopmentAndProductionLedgersRemainSeparate() throws {
        var production = configuration!
        production.location = temporaryDirectory.appendingPathComponent("EnvironmentStore", isDirectory: true)
        production.cloudKitContainerIdentifier = "iCloud.example.GraphEvo"
        production.setResolvedEnvironment(.production)
        var development = production
        development.setResolvedEnvironment(.development)

        _ = try GraphMigrationLedger.markDone(migrationID: "environment", version: 1, synchronization: .local, configuration: production)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "environment", version: 1, configuration: production)?.state, .done)
        XCTAssertNil(GraphMigrationLedger.localRecord(migrationID: "environment", version: 1, configuration: development))
        XCTAssertNotEqual(
            GraphMigrationLedger.fileURLForTesting(migrationID: "environment", version: 1, configuration: production),
            GraphMigrationLedger.fileURLForTesting(migrationID: "environment", version: 1, configuration: development)
        )
    }

    func testCorruptedLedgerIsNotReplaced() throws {
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: "corrupt", version: 1, configuration: configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: url)
        XCTAssertThrowsError(try GraphMigrationLedger.markStarted(migrationID: "corrupt", version: 1, configuration: configuration))
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3]))
    }

    func testHistoryRetentionCompactsOlderEvents() throws {
        for index in 0..<500 {
            _ = try GraphMigrationLedger.markFailed(migrationID: "retention", version: 1, error: NSError(domain: "test", code: index, userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 8_000)]), configuration: configuration)
        }
        let snapshot = GraphMigrationLedger.snapshot(migrationID: "retention", version: 1, configuration: configuration)
        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.compactedEventCount ?? 0, 0)
        XCTAssertGreaterThanOrEqual(snapshot?.historyCount ?? 0, 2)

        let data = try Data(contentsOf: GraphMigrationLedger.fileURLForTesting(migrationID: "retention", version: 1, configuration: configuration))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try XCTUnwrap(json["compactionSummary"] as? [String: Any])
        XCTAssertGreaterThan(summary["removedEventCount"] as? Int ?? 0, 0)
        XCTAssertFalse((summary["removedByState"] as? [String: Int] ?? [:]).isEmpty)
    }

    func testRetentionLimitAppliesToTheWholeStoreScope() throws {
        for index in 0..<90 {
            for migrationID in ["aggregate-a", "aggregate-b"] {
                _ = try GraphMigrationLedger.markFailed(
                    migrationID: migrationID,
                    version: 1,
                    error: NSError(
                        domain: "aggregate-retention",
                        code: index,
                        userInfo: [NSLocalizedDescriptionKey: String(repeating: migrationID, count: 1_500)]
                    ),
                    configuration: configuration
                )
            }
        }

        let ledgerDirectory = GraphMigrationLedger.fileURLForTesting(migrationID: "aggregate-a", version: 1, configuration: configuration).deletingLastPathComponent()
        let ledgerFiles = try FileManager.default.contentsOfDirectory(at: ledgerDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let totalBytes = try ledgerFiles.reduce(into: 0) { total, url in
            total += try Data(contentsOf: url).count
        }
        XCTAssertLessThanOrEqual(totalBytes, 2 * 1024 * 1024)
        let compacted = ["aggregate-a", "aggregate-b"].compactMap {
            GraphMigrationLedger.snapshot(migrationID: $0, version: 1, configuration: configuration)?.compactedEventCount
        }.reduce(0, +)
        XCTAssertGreaterThan(compacted, 0)
    }

    func testLegacyRecordIsConvertedToCurrentSchemaAtomically() throws {
        let migrationID = "legacy"
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = GraphMigrationRecord(
            migrationID: migrationID,
            version: 1,
            state: .done,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(legacy).write(to: url)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .done)
        let converted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(converted["schemaVersion"] as? Int, 3)
        XCTAssertEqual((converted["history"] as? [[String: Any]])?.first?["source"] as? String, "legacyLedger")
    }

    func testIntermediateSchemaTwoIsUpgradedWithoutLosingHistory() throws {
        let migrationID = "schema-two"
        _ = try GraphMigrationLedger.markStarted(migrationID: migrationID, version: 1, configuration: configuration)
        let url = GraphMigrationLedger.fileURLForTesting(migrationID: migrationID, version: 1, configuration: configuration)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 2
        json.removeValue(forKey: "compactionSummary")
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migrationID, version: 1, configuration: configuration)?.state, .started)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(upgraded["schemaVersion"] as? Int, 3)
        XCTAssertEqual((upgraded["history"] as? [[String: Any]])?.count, 1)
    }

    func testResetAndForceKeepStructuredRequestMetadata() throws {
        try GraphMigrationLedger.requestForce(
            migrationID: "requests",
            version: 1,
            configuration: configuration,
            requestedBy: .supportCenter,
            reason: "support retry"
        )
        let forceEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "requests", version: 1, configuration: configuration).last)
        XCTAssertEqual(forceEntry.requestedBy, .supportCenter)
        XCTAssertEqual(forceEntry.requestReason, "support retry")

        try GraphMigrationLedger.reset(
            migrationID: "requests",
            version: 1,
            configuration: configuration,
            targets: [.local],
            requestedBy: .user,
            reason: "manual recovery"
        )
        let resetEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "requests", version: 1, configuration: configuration).last)
        XCTAssertEqual(resetEntry.state, .notExecuted)
        XCTAssertEqual(resetEntry.resetTargets, [.local])
        XCTAssertEqual(resetEntry.requestReason, "manual recovery")
    }

    func testRemoteOnlyResetPreservesLocalProjection() throws {
        _ = try GraphMigrationLedger.markDone(migrationID: "remote-reset", version: 1, synchronization: .local, configuration: configuration)

        try GraphMigrationLedger.reset(
            migrationID: "remote-reset",
            version: 1,
            configuration: configuration,
            targets: [.remote],
            requestedBy: .supportCenter,
            reason: "invalidate remote projection"
        )

        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: "remote-reset", version: 1, configuration: configuration)?.state, .done)
        let resetEntry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "remote-reset", version: 1, configuration: configuration).last)
        XCTAssertEqual(resetEntry.state, .notExecuted)
        XCTAssertEqual(resetEntry.resetTargets, [.remote])
    }

    func testSnapshotExposesRecoveryAndPseudonymousScopeMetadata() throws {
        _ = try GraphMigrationLedger.markStarted(
            migrationID: "snapshot",
            version: 1,
            configuration: configuration,
            phase: "postMigration",
            operationID: "operation",
            generation: 7,
            backupReference: "/backup/reference"
        )

        let snapshot = try GraphMigrationLedger.stateSnapshot(migrationID: "snapshot", version: 1, configuration: configuration)
        XCTAssertTrue(snapshot.interrupted)
        XCTAssertEqual(snapshot.storeScope, GraphStoreScope(configuration: configuration).logicalKey)
        XCTAssertEqual(snapshot.generation, 7)
        XCTAssertEqual(snapshot.operationID, "operation")
        XCTAssertEqual(snapshot.phase, "postMigration")
        XCTAssertEqual(snapshot.backupReference, "/backup/reference")
        XCTAssertNil(snapshot.errorDescription)

        let entry = try XCTUnwrap(GraphMigrationLedger.history(migrationID: "snapshot", version: 1, configuration: configuration).last)
        XCTAssertEqual(entry.storeScope, GraphStoreScope(configuration: configuration).logicalKey)
        XCTAssertEqual(entry.deviceID, GraphMigrationLedger.installationIdentifier)
        XCTAssertNotEqual(entry.deviceID, ProcessInfo.processInfo.hostName)
        XCTAssertNotNil(entry.publishedAt)
    }

    func testSameGenerationRemoteConflictUsesDeterministicOrdering() throws {
        let migrationID = "remote-conflict"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func remote(deviceID: String, operationID: String) -> GraphMigrationLedgerEntry {
            GraphMigrationLedgerEntry(
                schemaVersion: 3,
                operationID: operationID,
                generation: 12,
                migrationID: migrationID,
                version: 1,
                state: .done,
                phase: "ready",
                requestedBy: .migrationManager,
                deviceID: deviceID,
                appVersion: "1",
                graphModelVersion: nil,
                backupReference: nil,
                previousOperationID: nil,
                decisionReason: nil,
                source: "localLedger",
                date: date,
                errorDescription: nil,
                storeScope: GraphStoreScope(configuration: configuration).logicalKey,
                observedAt: nil,
                publishedAt: date
            )
        }
        let lower = remote(deviceID: "installation-A", operationID: "operation-Z")
        let higher = remote(deviceID: "installation-B", operationID: "operation-A")

        try GraphMigrationLedger.reconcileRemoteEntryForTesting(higher, configuration: configuration)
        try GraphMigrationLedger.reconcileRemoteEntryForTesting(lower, configuration: configuration)
        try GraphMigrationLedger.reconcileRemoteEntryForTesting(lower, configuration: configuration)

        let observations = try GraphMigrationLedger.history(migrationID: migrationID, version: 1, configuration: configuration).filter { $0.source == "remoteKVS" }
        XCTAssertEqual(observations.map(\.deviceID), ["installation-B", "installation-A"])
        XCTAssertTrue(observations.allSatisfy { $0.observedAt != nil && $0.publishedAt == date })
        XCTAssertTrue(GraphMigrationLedger.orderedAfterForTesting(higher, lower))
        XCTAssertFalse(GraphMigrationLedger.orderedAfterForTesting(lower, higher))
        XCTAssertEqual(try GraphMigrationLedger.stateSnapshot(migrationID: migrationID, version: 1, configuration: configuration).operationID, higher.operationID)
    }
}
