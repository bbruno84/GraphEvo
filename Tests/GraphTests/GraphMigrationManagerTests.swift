import XCTest
@testable import Graph

final class GraphMigrationManagerTests: XCTestCase {
    private struct CompletingMigration: GraphMigration {
        let id: String
        let version = 1
        let shouldRun: (GraphMigrationManager.GraphLifecyclePhase) -> Bool

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            shouldRun(phase)
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.done)
        }
    }

    func testRegisteredMigrationRunsOnceAndPersistsCompletion() throws {
        let migrationID = "ManagerTest-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerTest"
        configuration.location = directory

        let migration = CompletingMigration(id: migrationID) { $0 == .preInit }
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .started)

        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)

        let record = GraphMigrationManager.record(for: migration, configuration: configuration)
        XCTAssertEqual(record?.state, .done)
        XCTAssertEqual(record?.migrationID, migrationID)
        XCTAssertEqual(record?.version, 1)

        try GraphMigrationManager.resetRecord(for: migration, configuration: configuration)
        XCTAssertNil(GraphMigrationManager.record(for: migration, configuration: configuration))
    }

    func testMigrationContextStoresTypedValues() {
        var context = GraphMigrationContext()
        context.set("count", value: 3)
        context.set("name", value: "migration")

        XCTAssertEqual(context["count"] as Int?, 3)
        XCTAssertEqual(context["name"] as String?, "migration")
        XCTAssertNil(context["missing"] as String?)
    }
}
