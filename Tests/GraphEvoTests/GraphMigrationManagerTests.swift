import XCTest
import CoreData
@testable import GraphEvo

final class GraphMigrationManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GraphMigrationManager.resetForTesting()
    }

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

    private struct ResultMigration: GraphMigration {
        let id: String
        let result: GraphMigrationResult

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            phase == .postInit
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(result)
        }
    }

    private final class RemoteTrackingMigration: GraphMigration {
        let id: String
        private(set) var insertedIDs: [NSManagedObjectID] = []
        private(set) var updatedIDs: [NSManagedObjectID] = []

        init(id: String) {
            self.id = id
        }

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            false
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.skipped)
        }

        func handleRemoteChanges(
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            inserted: [NSManagedObjectID],
            updated: [NSManagedObjectID]
        ) {
            insertedIDs = inserted
            updatedIDs = updated
        }
    }

    private final class LifecycleMigration: GraphMigration {
        let id: String
        let result: GraphMigrationResult
        let adoptsLegacyCompletion: Bool
        private(set) var handleCount = 0

        init(id: String, result: GraphMigrationResult = .done, adoptsLegacyCompletion: Bool = false) {
            self.id = id
            self.result = result
            self.adoptsLegacyCompletion = adoptsLegacyCompletion
        }

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            true
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            handleCount += 1
            completion(result)
        }

        func recognizesLegacyCompletion(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?
        ) -> Bool {
            adoptsLegacyCompletion
        }
    }

    private final class DelayedMigration: GraphMigration {
        let id: String
        private let lock = NSLock()
        private(set) var handledPhases: [GraphMigrationManager.GraphLifecyclePhase] = []
        let preInitDelay: TimeInterval
        let onCompleted: ((GraphMigrationManager.GraphLifecyclePhase) -> Void)?

        init(
            id: String,
            preInitDelay: TimeInterval = 0.05,
            onCompleted: ((GraphMigrationManager.GraphLifecyclePhase) -> Void)? = nil
        ) {
            self.id = id
            self.preInitDelay = preInitDelay
            self.onCompleted = onCompleted
        }

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            true
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            lock.lock()
            handledPhases.append(phase)
            lock.unlock()

            let delay = phase == .preInit ? preInitDelay : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                completion(.done)
                self.onCompleted?(phase)
            }
        }

        var phases: [GraphMigrationManager.GraphLifecyclePhase] {
            lock.lock()
            defer { lock.unlock() }
            return handledPhases
        }
    }

    func testAsyncPhaseQueuesLaterLifecyclePhaseWithoutOverwritingState() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerAsync-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let readyExpectation = expectation(description: "ready migration completes")
        let migration = DelayedMigration(
            id: "ManagerAsync-\(UUID().uuidString)",
            onCompleted: { phase in
                if case .ready = phase {
                    readyExpectation.fulfill()
                }
            }
        )
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)

        wait(for: [readyExpectation], timeout: 2)
        let phases = migration.phases
        XCTAssertEqual(phases.count, 2)
        if phases.count == 2 {
            if case .preInit = phases[0] {
                // Expected first phase.
            } else {
                XCTFail("The asynchronous preInit phase was not completed first")
            }
            if case .ready = phases[1] {
                // Expected queued phase.
            } else {
                XCTFail("The queued ready phase was not started after preInit")
            }
        }
        XCTAssertEqual(
            GraphMigrationManager.record(for: migration, configuration: configuration)?.state,
            .done
        )
    }

    func testRegisteredMigrationRunsOnceAndPersistsCompletion() throws {
        let migrationID = "ManagerTest-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Manager-\(UUID().uuidString)", isDirectory: true)
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

    func testFailedMigrationPersistsErrorAndPostsFailureNotification() throws {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Manager test failed" }
        }

        let migrationID = "ManagerFailure-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerFailure"
        configuration.location = directory

        let migration = ResultMigration(id: migrationID, result: .error(ExpectedError()))
        GraphMigrationManager.registerMigration(migration)
        let notificationExpectation = expectation(description: "failure notification")
        var failureInfo: GraphMigrationManager.FailureInfo?
        let observer = GraphMigrationManager.observeMigrationFailure { info in
            guard info.migrationID == migrationID else { return }
            failureInfo = info
            notificationExpectation.fulfill()
        }
        defer { GraphMigrationManager.removeProgressObserver(observer) }

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)
        wait(for: [notificationExpectation], timeout: 1)

        let record = try XCTUnwrap(GraphMigrationManager.record(for: migration, configuration: configuration))
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.errorDescription, "Manager test failed")
        XCTAssertEqual(failureInfo?.migrationID, migrationID)
        XCTAssertEqual(failureInfo?.errorDescription, "Manager test failed")
        if case .postInit? = failureInfo?.phase {
            // Expected lifecycle phase.
        } else {
            XCTFail("Failure notification reported the wrong phase")
        }
    }

    func testSkippedMigrationClearsStartedRecord() throws {
        let migrationID = "ManagerSkipped-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerSkipped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerSkipped"
        configuration.location = directory

        let migration = ResultMigration(id: migrationID, result: .skipped)
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertNil(GraphMigrationManager.record(for: migration, configuration: configuration))
    }

    func testRemoteEntityChangesAreForwardedToRegisteredMigrations() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerRemote-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let entity = Entity("RemoteEntity", graph: graph)
        let objectID = entity.managedNode.objectID
        let migration = RemoteTrackingMigration(id: "ManagerRemote-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handleRemoteEntityChanges(
            configuration: configuration,
            graph: graph,
            inserted: [objectID],
            updated: []
        )

        XCTAssertEqual(migration.insertedIDs, [objectID])
        XCTAssertTrue(migration.updatedIDs.isEmpty)
    }

    func testDefaultMigrationHelpersAndLedgerReconciliation() throws {
        let migrationID = "ManagerDefaults-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerDefaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerDefaults"
        configuration.location = directory
        let migration = CompletingMigration(id: migrationID) { _ in false }
        let record = try GraphMigrationLedger.markDone(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .local,
            configuration: configuration
        )

        var context = GraphMigrationContext()
        context.set("GraphMigration.previousRecord", value: record)
        XCTAssertEqual(context.previousMigrationRecord, record)
        XCTAssertEqual(
            migration.backupRoot(for: configuration),
            GraphMigrationManager.defaultBackupRoot(for: configuration)
        )

        let reconciled = GraphMigrationLedger.reconciledRecord(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .localAndICloudKeyValueStore,
            configuration: configuration
        )
        XCTAssertEqual(reconciled?.migrationID, record.migrationID)
        XCTAssertEqual(reconciled?.version, record.version)
        XCTAssertEqual(reconciled?.state, .done)

        migration.resetMigrationState(for: configuration)
        XCTAssertNil(GraphMigrationManager.record(for: migration, configuration: configuration))
    }

    func testAlreadyCompletedMigrationIsNotExecutedAgain() throws {
        let migrationID = "ManagerAlreadyDone-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerAlreadyDone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerAlreadyDone"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID)
        _ = try GraphMigrationLedger.markDone(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .local,
            configuration: configuration
        )
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 0)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }

    func testLegacyCompletionIsAdoptedWithoutCallingMigrationHandler() throws {
        let migrationID = "ManagerLegacyDone-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerLegacyDone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerLegacyDone"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID, adoptsLegacyCompletion: true)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 0)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }

    func testFallbackResultIsPersistedAsDone() throws {
        let migrationID = "ManagerFallback-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerFallback"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID, result: .fallback)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 1)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }
}
