import CoreData
import XCTest
@testable import GraphEvo

final class GraphTransactionTraceTests: XCTestCase {
    private final class Events: GraphEventDelegate {
        var traces: [GraphTransactionTrace] = []
        var received: ((GraphTransactionTrace) -> Void)?
        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            guard case .transactionDiagnostic(let trace) = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            traces.append(trace)
            received?(trace)
        }
    }

    private func fixture(memory: Bool = false) -> Graph {
        Graph(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("Trace-\(UUID()).sqlite"),
              backend: memory ? .inMemory : .sqlite, migrationEnabled: false)
    }

    private func observe(_ graph: Graph) -> (Events, XCTestExpectation) {
        let events = Events()
        let complete = expectation(description: "outcome followed by history")
        complete.expectedFulfillmentCount = 2
        events.received = { _ in complete.fulfill() }
        graph.eventDelegate = events
        return (events, complete)
    }

    func testSuccessfulOutcomeIsQueuedAfterSaveAndCodableWithoutPayloads() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        let id = UUID()
        let value = try graph.transaction(diagnosticID: id) { scoped -> Int in
            let node = Entity("PRIVATE_DOMAIN_TYPE", graph: scoped)
            node[dynamicMember: "PRIVATE_PROPERTY"] = "PRIVATE_PAYLOAD"
            XCTAssertTrue(events.traces.isEmpty)
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertTrue(events.traces.isEmpty, "Delivery must be queued even for a main-thread caller")
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(events.traces.map(\.phase), [.outcome, .history])
        XCTAssertTrue(events.traces.allSatisfy { $0.diagnosticID == id })
        let trace = events.traces[0]
        XCTAssertEqual(trace.outcome, .succeeded)
        XCTAssertTrue(trace.didSave)
        XCTAssertNil(trace.errorCode)
        XCTAssertEqual(trace.checkpoints.map(\.stage), [.begin, .pinned, .bodyEnd, .precommitCompare, .saveResult, .finished])
        XCTAssertEqual(trace.checkpoints.first { $0.stage == .bodyEnd }?.inserted, 2)
        XCTAssertEqual(trace.checkpoints.first { $0.stage == .precommitCompare }?.generationsEqual, true)
        XCTAssertEqual(trace.checkpoints.map(\.elapsed), trace.checkpoints.map(\.elapsed).sorted())
        let history = try XCTUnwrap(events.traces[1].history)
        XCTAssertEqual(history.status, .available)
        XCTAssertFalse(history.isExhaustive)
        XCTAssertFalse(history.truncated)
        XCTAssertEqual(history.observedChanges, 2)
        XCTAssertEqual(history.groups.reduce(0) { $0 + $1.count }, 2)
        let data = try JSONEncoder().encode(events.traces)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for privateValue in ["PRIVATE_DOMAIN_TYPE", "PRIVATE_PROPERTY", "PRIVATE_PAYLOAD"] {
            XCTAssertFalse(json.contains(privateValue))
        }
        XCTAssertEqual(try JSONDecoder().decode([GraphTransactionTrace].self, from: data).first?.diagnosticID, id)
    }

    func testStoreChangedPreservesRollbackAndReportsUnequalGenerations() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        let writer = try XCTUnwrap(graph.newBackgroundContext())
        XCTAssertThrowsError(try graph.transaction(diagnosticID: UUID()) { scoped in
            _ = Entity("MustRollback", graph: scoped)
            try writer.performAndWait {
                writer.transactionAuthor = "CONCURRENT-WRITER"
                let other = Graph(transactionContext: writer, configuration: graph.configuration)
                _ = Entity("Concurrent", graph: other)
                try writer.save()
            }
        }) { error in
            guard case GraphTransactionError.storeChanged = error else { return XCTFail("Unexpected \(error)") }
        }
        wait(for: [complete], timeout: 3)
        let trace = events.traces[0]
        XCTAssertEqual(trace.outcome, .failed)
        XCTAssertFalse(trace.didSave)
        XCTAssertEqual(trace.errorCode, 2)
        XCTAssertEqual(trace.checkpoints.first { $0.stage == .precommitCompare }?.generationsEqual, false)
        XCTAssertEqual(trace.checkpoints.first { $0.stage == .rollbackResult }?.inserted, 0)
        XCTAssertTrue(Search<Entity>(graph: graph).where(.type("MustRollback")).sync().isEmpty)
        let history = try XCTUnwrap(events.traces[1].history)
        XCTAssertEqual(history.status, .available)
        XCTAssertTrue(history.groups.contains { $0.author == "CONCURRENT-WRITER" && $0.operation == "insert" })
    }

    func testBodyFailureIsRethrownWithoutSerializingErrorPayload() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        let failure = NSError(domain: "TestFailure", code: 701,
                              userInfo: [NSLocalizedDescriptionKey: "SECRET_ERROR_PAYLOAD"])
        XCTAssertThrowsError(try graph.transaction(diagnosticID: UUID()) { scoped in
            _ = Entity("MustRollback", graph: scoped)
            throw failure
        }) { XCTAssertTrue(($0 as NSError) === failure) }
        wait(for: [complete], timeout: 3)
        let trace = events.traces[0]
        XCTAssertEqual(trace.errorDomain, "TestFailure")
        XCTAssertEqual(trace.errorCode, 701)
        XCTAssertEqual(trace.checkpoints.map(\.stage), [.begin, .pinned, .bodyEnd, .rollbackResult, .finished])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(trace), as: UTF8.self).contains("SECRET_ERROR_PAYLOAD"))
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
    }

    func testEarlyPendingChangesFailureIsCorrelatedWithoutRunningBody() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        let node = Entity("Pending", graph: graph)
        let id = UUID()
        XCTAssertThrowsError(try graph.transaction(diagnosticID: id) { _ in XCTFail("Body must not run") })
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(events.traces[0].diagnosticID, id)
        XCTAssertEqual(events.traces[0].checkpoints.map(\.stage), [.begin, .finished])
        XCTAssertEqual(events.traces[0].errorCode, 1)
        XCTAssertTrue(node.node.isInserted)
        XCTAssertTrue(graph.managedObjectContext.hasChanges)
        graph.managedObjectContext.rollback()
    }

    func testUnavailableContextStillProducesOutcomeAndUnavailableHistory() throws {
        let graph = Graph(transactionContext: NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType),
                          configuration: GraphStoreConfiguration())
        graph.isTransactionFacade = false
        let (events, complete) = observe(graph)
        XCTAssertThrowsError(try graph.transaction(diagnosticID: UUID()) { _ in XCTFail("Body must not run") })
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(events.traces[0].outcome, .failed)
        XCTAssertEqual(events.traces[0].errorCode, 0)
        XCTAssertEqual(events.traces[1].history?.status, .unavailable)
    }

    func testDelegateCanReadAfterOutcomeWithoutTransactionQueueDeadlock() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        events.received = { trace in
            if trace.phase == .outcome {
                XCTAssertEqual(try? graph.readSnapshot { Search<Entity>(graph: $0).where(.type("Committed")).sync().count }, 1)
            }
            complete.fulfill()
        }
        let finished = expectation(description: "worker returned")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try graph.transaction(diagnosticID: UUID()) { _ = Entity("Committed", graph: $0) } }
            catch { XCTFail("\(error)") }
        }
        wait(for: [complete, finished], timeout: 5)
    }

    func testLegacyTransactionEmitsNoTrace() throws {
        let graph = fixture()
        let events = Events()
        graph.eventDelegate = events
        let none = expectation(description: "legacy path does not emit diagnostics")
        none.isInverted = true
        events.received = { _ in none.fulfill() }
        try graph.transaction { _ = Entity("Ordinary", graph: $0) }
        wait(for: [none], timeout: 0.1)
    }

    func testHistoryReadIsBoundedAndDoesNotFetchDomainValues() throws {
        let graph = fixture()
        let start = Date()
        for _ in 0..<600 { _ = Entity("PRIVATE_TYPE", graph: graph) }
        graph.sync()
        let history = GraphTransactionTraceRecorder.readHistory(
            coordinator: graph.managedObjectContext.persistentStoreCoordinator, from: start, through: Date())
        XCTAssertEqual(history.status, .available)
        XCTAssertEqual(history.observedChanges, 0)
        XCTAssertTrue(history.truncated)
        XCTAssertLessThanOrEqual(history.groups.count, 64)
        XCTAssertTrue(history.groups.allSatisfy { $0.entityName == "ManagedEntity" })
    }

    func testHistoryExcludesOlderAndLaterTransactions() throws {
        let graph = fixture()
        _ = Entity("Older", graph: graph)
        graph.sync()
        let start = Date()
        _ = Entity("Inside", graph: graph)
        graph.sync()
        let end = Date()
        _ = Entity("Later", graph: graph)
        graph.sync()
        let history = GraphTransactionTraceRecorder.readHistory(
            coordinator: graph.managedObjectContext.persistentStoreCoordinator, from: start, through: end)
        XCTAssertEqual(history.status, .available)
        XCTAssertEqual(history.observedChanges, 1)
        XCTAssertEqual(history.groups.reduce(0) { $0 + $1.count }, 1)
        XCTAssertFalse(history.truncated)
    }

    func testNoOpSucceedsWithoutClaimingASaveOrGenerationComparison() throws {
        let graph = fixture()
        let (events, complete) = observe(graph)
        XCTAssertEqual(try graph.transaction(diagnosticID: UUID()) { _ in 7 }, 7)
        wait(for: [complete], timeout: 3)
        let trace = events.traces[0]
        XCTAssertEqual(trace.outcome, .succeeded)
        XCTAssertFalse(trace.didSave)
        XCTAssertEqual(trace.checkpoints.map(\.stage), [.begin, .pinned, .bodyEnd, .finished])
        XCTAssertEqual(events.traces[1].history?.status, .available)
        XCTAssertEqual(events.traces[1].history?.observedChanges, 0)
    }

    func testNestedRejectionStillEmitsBothCorrelatedPhases() throws {
        let graph = fixture()
        let id = UUID()
        let events = Events()
        let complete = expectation(description: "nested rejection evidence")
        complete.expectedFulfillmentCount = 2
        events.received = { trace in
            XCTAssertEqual(trace.diagnosticID, id)
            XCTAssertEqual(trace.outcome, .failed)
            XCTAssertEqual(trace.errorCode, 3)
            complete.fulfill()
        }
        // Keep the facade alive for queued delivery; ordinary callers must not let
        // transaction facades escape. This test controls lifetime solely to observe rejection.
        let scoped = Graph(transactionContext: graph.managedObjectContext, configuration: graph.configuration)
        scoped.eventDelegate = events
        XCTAssertThrowsError(try scoped.transaction(diagnosticID: id) { _ in XCTFail("Nested body must not execute") })
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(events.traces.last?.history?.status, .unavailable)
        withExtendedLifetime(scoped) {}
    }

    func testHistoryFailureIsAnUnavailableSupplement() throws {
        final class BrokenCoordinator: NSPersistentStoreCoordinator, @unchecked Sendable {
            override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext) throws -> Any {
                if request is NSPersistentHistoryChangeRequest { throw NSError(domain: "HistoryUnavailable", code: 23) }
                return try super.execute(request, with: context)
            }
        }
        let coordinator = BrokenCoordinator(managedObjectModel: Model.create())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BrokenHistory-\(UUID()).sqlite")
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSPersistentHistoryTrackingKey: true])
        let history = GraphTransactionTraceRecorder.readHistory(coordinator: coordinator, from: Date(), through: Date())
        XCTAssertEqual(history.status, .unavailable)
        XCTAssertEqual(history.errorDomain, "HistoryUnavailable")
        XCTAssertEqual(history.errorCode, 23)
        XCTAssertFalse(history.isExhaustive)
    }

    func testHistoryGroupAndStringLimitsAreFlagged() throws {
        let graph = fixture()
        let start = Date()
        for index in 0..<70 {
            graph.managedObjectContext.transactionAuthor = index == 0 ? String(repeating: "a", count: 200) : "writer-\(index)"
            _ = Entity("Node", graph: graph)
            graph.sync()
        }
        let history = GraphTransactionTraceRecorder.readHistory(
            coordinator: graph.managedObjectContext.persistentStoreCoordinator, from: start, through: Date())
        XCTAssertEqual(history.status, .available)
        XCTAssertTrue(history.truncated)
        XCTAssertEqual(history.observedChanges, 70)
        XCTAssertEqual(history.groups.count, 64)
        XCTAssertTrue(history.groups.allSatisfy { ($0.author?.count ?? 0) <= 128 && $0.entityName.count <= 128 })
    }

    func testInMemoryTransactionSucceedsWithUnavailableHistory() throws {
        let graph = fixture(memory: true)
        let (events, complete) = observe(graph)
        try graph.transaction(diagnosticID: UUID()) { _ = Entity("Memory", graph: $0) }
        wait(for: [complete], timeout: 3)
        XCTAssertEqual(events.traces[0].outcome, .succeeded)
        XCTAssertTrue(events.traces[0].didSave)
        XCTAssertFalse(events.traces[0].checkpoints.contains { $0.stage == .precommitCompare })
        XCTAssertEqual(events.traces[1].history?.status, .unavailable)
    }
}
