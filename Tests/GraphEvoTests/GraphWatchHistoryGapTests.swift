import CoreData
import XCTest
@testable import GraphEvo

final class GraphWatchHistoryGapTests: XCTestCase {
    private func fixture() throws -> (Graph, NSManagedObjectContext, NSPersistentHistoryToken, GraphWatchDeliveryTokenStore) {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchHistoryGap-\(UUID()).sqlite"), migrationEnabled: false)
        let context = try XCTUnwrap(graph.newBackgroundContext())
        let old = try context.performAndWait { () -> NSPersistentHistoryToken in
            context.transactionAuthor = "REMOTE-PRUNED"
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            _ = Entity("Pruned", graph: facade)
            try context.save()
            let result = try context.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)) as! NSPersistentHistoryResult
            return try XCTUnwrap((result.result as? [NSPersistentHistoryTransaction])?.last?.token)
        }
        // Advance past the saved cursor, then remove its interval through Core Data.
        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            _ = Entity("AlsoPruned", graph: facade)
            try context.save()
            _ = try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
        }
        let tokens = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        try tokens.save(old)
        // Prove the fixture triggers a real expired-token error, not merely an empty fetch.
        try context.performAndWait {
            XCTAssertThrowsError(try context.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: old))) { error in
                XCTAssertTrue([134301, 134501].contains((error as NSError).code))
            }
        }
        return (graph, context, old, tokens)
    }

    func testExpiredCursorWithNoRetainedHistoryReportsGapWithoutInventingEvents() throws {
        let (graph, _, _, _) = try fixture()
        graph.watchReportSources = [.cloud]
        let received = expectation(description: "empty recovery reports history gap")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(report)
            guard case .historyGap = error as? GraphWatchDeliveryError else { return XCTFail("Expected history-gap diagnostic") }
            received.fulfill()
        }
        let coordinator = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        coordinator.request()
        wait(for: [received], timeout: 3)
    }

    func testRecoveryRetainsExpiredCursorAndDeletionsUntilInvalidSurvivorIsRepaired() throws {
        final class Warnings: GraphEventDelegate {
            var onFailure: (() -> Void)?
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                if case .warning(.watchReportMaterializationFailed(_, _, let details)) = event,
                   details.contains(where: { $0.error is GraphStructuralValidationFailure }) { onFailure?() }
            }
        }
        let (graph, context, old, tokens) = try fixture()
        var deletedDetails = Set<NSManagedObjectID>()
        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            let root = Entity("Root", graph: facade)
            let endpoint = Entity("Missing", graph: facade)
            _ = root.is(relationship: "Broken").of(endpoint)
            let transient = Entity("Transient", graph: facade)
            transient.add(tags: "removed")
            try context.save()
            deletedDetails = Set(transient.node.objectIDs(forRelationshipNamed: "tagSet"))
            transient.delete()
            try context.save()
            // Preserve the relationship's to-one ID while removing its destination.
            context.transactionAuthor = GraphDeviceAuthor.current()
            _ = try context.execute(NSBatchDeleteRequest(objectIDs: [endpoint.node.objectID]))
        }
        XCTAssertEqual(deletedDetails.count, 1)
        graph.watchReportSources = [.cloud]
        let warnings = Warnings()
        graph.eventDelegate = warnings
        let failed = expectation(description: "recovered survivor fails validation")
        warnings.onFailure = { failed.fulfill() }
        let premature = expectation(description: "no partial recovery report")
        premature.isInverted = true
        graph.watchReportCompletion = { _, _ in premature.fulfill() }
        let coordinator = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        coordinator.request()
        wait(for: [failed, premature], timeout: 0.5)
        XCTAssertEqual(try tokens.load(), old)

        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            let edge = try XCTUnwrap(Search<Relationship>(graph: facade).where(.type("Broken")).sync().first)
            edge.object = Entity("Replacement", graph: facade)
            try context.save()
        }
        let received = expectation(description: "repaired recovery delivers with gap diagnostic")
        graph.watchReportCompletion = { report, error in
            guard case .historyGap = error as? GraphWatchDeliveryError else { return XCTFail("Expected history-gap diagnostic") }
            guard let report else { return XCTFail("Expected recovered report") }
            XCTAssertEqual(Set(report.unmaterializedDeletions.map(\.objectID)), deletedDetails)
            XCTAssertTrue(report.events.contains { if case .deletedEntity = $0 { return true }; return false })
            XCTAssertTrue(report.structuralValidationResults.allSatisfy(\.isValid))
            XCTAssertFalse(report.structuralValidationResults.isEmpty)
            received.fulfill()
        }
        coordinator.request()
        wait(for: [received], timeout: 3)
        XCTAssertNotEqual(try tokens.load(), old)
    }

    func testExpiredCursorRecoversRetainedHistoryAndPersistsNewCursor() throws {
        let (graph, context, _, tokens) = try fixture()
        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            _ = Entity("Retained", graph: facade)
            try context.save()
        }
        graph.watchReportSources = [.cloud]
        let received = expectation(description: "retained history with gap diagnostic")
        graph.watchReportCompletion = { report, error in
            guard case .historyGap = error as? GraphWatchDeliveryError else { return XCTFail("Expected history-gap diagnostic") }
            guard let report else { return XCTFail("Expected recovered report") }
            let types = report.events.compactMap { event -> String? in
                if case .insertedEntity(let entity) = event { return entity.type }
                return nil
            }
            XCTAssertEqual(types, ["Retained"])
            XCTAssertTrue(report.structuralValidationResults.allSatisfy(\.isValid))
            received.fulfill()
        }
        let coordinator = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        coordinator.request()
        wait(for: [received], timeout: 3)
        let cursor = try XCTUnwrap(tokens.load())
        try context.performAndWait {
            let result = try context.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: cursor)) as! NSPersistentHistoryResult
            XCTAssertTrue((result.result as? [NSPersistentHistoryTransaction] ?? []).isEmpty)
        }
        let duplicate = expectation(description: "recreated coordinator does not replay recovered history")
        duplicate.isInverted = true
        graph.watchReportCompletion = { _, _ in duplicate.fulfill() }
        let recreated = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        recreated.request()
        wait(for: [duplicate], timeout: 0.3)
    }
}
