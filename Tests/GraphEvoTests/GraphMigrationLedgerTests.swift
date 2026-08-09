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
        configuration.name = "MigrationLedgerTests"
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

    func testResetRemovesLocalRecord() throws {
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

        XCTAssertNil(
            GraphMigrationLedger.localRecord(
                migrationID: "test-migration",
                version: 1,
                configuration: configuration
            )
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
}
