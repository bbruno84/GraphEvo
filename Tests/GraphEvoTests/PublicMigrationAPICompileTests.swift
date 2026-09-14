import XCTest
import GraphEvo

final class PublicMigrationAPICompileTests: XCTestCase {
    func testDiagnosticTypesAndAPIsArePubliclyConsumable() throws {
        let entry = GraphMigrationLedgerEntry(
            schemaVersion: 1,
            operationID: "operation",
            generation: 1,
            migrationID: "migration",
            version: 1,
            state: .started,
            phase: "postMigration",
            requestedBy: .user,
            deviceID: "redacted-device",
            appVersion: "1.0",
            graphModelVersion: nil,
            backupReference: nil,
            previousOperationID: nil,
            decisionReason: .noCandidate,
            decisionSource: .localEvaluation,
            source: "localLedger",
            date: Date(),
            errorDescription: nil,
            storeScope: "scope",
            observedAt: nil,
            publishedAt: nil
        )
        XCTAssertEqual(entry.state, .started)
        _ = GraphMigrationManager.history
        _ = GraphMigrationManager.stateSnapshot
        _ = Notification.Name.graphMigrationMetadataDidChange
    }

    private struct Migration: GraphMigration {
        let id = "public-metadata"
        func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { false }
        func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) { completion(.done) }
    }

    func testArbitraryCodableMetadataThroughPublicAPI() throws {
        struct Payload: Codable, Equatable { let format: Int; let names: [String]; let date: Date }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = GraphStoreConfiguration()
        config.name = "PublicMetadata"
        config.location = root
        let value = Payload(format: 7, names: ["a", "b"], date: Date(timeIntervalSince1970: 1234))
        XCTAssertNil(try GraphMigrationManager.metadata(Payload.self, forKey: "payload", for: Migration(), configuration: config))
        try GraphMigrationManager.setMetadata(value, forKey: "payload", for: Migration(), configuration: config)
        try GraphMigrationManager.setMetadata(true, forKey: "flag", for: Migration(), configuration: config)
        XCTAssertEqual(try GraphMigrationManager.metadata(Payload.self, forKey: "payload", for: Migration(), configuration: config), value)
        XCTAssertThrowsError(try GraphMigrationManager.metadata(Int.self, forKey: "payload", for: Migration(), configuration: config))
        try GraphMigrationManager.removeMetadata(forKey: "payload", for: Migration(), configuration: config)
        XCTAssertNil(try GraphMigrationManager.metadata(Payload.self, forKey: "payload", for: Migration(), configuration: config))
        XCTAssertEqual(try GraphMigrationManager.metadata(Bool.self, forKey: "flag", for: Migration(), configuration: config), true)
    }
}
