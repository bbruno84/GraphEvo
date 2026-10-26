import CoreData
import XCTest
@testable import GraphEvo

final class GraphTransactionWatchReportTests: XCTestCase {
    private func makeGraph() -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = UUID().uuidString
        configuration.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        return graph
    }

    private func drain() {
        let done = expectation(description: "deferred merges and reports")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testWorkerCommitReportsPublicEntitiesRelationshipAndBinaryPropertyOnce() throws {
        let graph = makeGraph()
        var reports: [GraphWatchReport] = []
        graph.watchReportCompletion = { report, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            if let report { reports.append(report) }
        }
        let committed = expectation(description: "worker commit")
        DispatchQueue.global().async {
            defer { committed.fulfill() }
            do {
                try graph.transaction { scoped in
                    let bill = Entity("Bill", graph: scoped)
                    bill[dynamicMember: "media"] = Data([1, 2, 3])
                    let category = Entity("Category", graph: scoped)
                    _ = bill.is(relationship: "category").of(category)
                }
            } catch { XCTFail("\(error)") }
        }
        wait(for: [committed], timeout: 10)
        drain()
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.graph === graph)
        XCTAssertEqual(report.source, .local)
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Bill") || .type("Category")).sync().count, 2)
        XCTAssertTrue(report.events.contains {
            if case .insertedRelationship(let link) = $0 {
                XCTAssertTrue(link.managedNode.managedObjectContext === graph.managedObjectContext)
                XCTAssertEqual(link.object?.type, "Category")
                return true
            }
            return false
        })
        XCTAssertTrue(report.events.contains {
            if case .addedEntityProperty(let node, "media", let value) = $0 {
                XCTAssertTrue(node.managedNode.managedObjectContext === graph.managedObjectContext)
                XCTAssertEqual(value as? Data, Data([1, 2, 3]))
                return true
            }
            return false
        })
        graph.sync()
        drain()
        XCTAssertEqual(reports.count, 1)
    }

    func testUpdatesRemovedDetailsAndWholeNodeDeletion() throws {
        let graph = makeGraph()
        let bill = Entity("Bill", graph: graph)
        bill[dynamicMember: "amount"] = 1
        bill[dynamicMember: "media"] = Data([4, 5])
        bill.add(tags: "old")
        let category = Entity("Category", graph: graph)
        let link = bill.is(relationship: "category").of(category)
        graph.sync()
        var reports: [GraphWatchReport] = []
        graph.watchReportCompletion = { report, _ in if let report { reports.append(report) } }
        try graph.transaction { scoped in
            let item = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Bill")).sync().first)
            item[dynamicMember: "amount"] = 2
            item[dynamicMember: "media"] = nil
            item.remove(tags: "old")
            let relation = try XCTUnwrap(Search<Relationship>(graph: scoped).where(.type("category")).sync().first)
            relation.object = item
        }
        XCTAssertTrue(reports.isEmpty, "Main-thread transaction callback must be deferred")
        drain()
        XCTAssertEqual(reports.count, 1)
        let events = try XCTUnwrap(reports.first).events
        XCTAssertTrue(events.contains { if case .updatedEntityProperty(_, "amount", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .removedEntityProperty(_, "media", let value) = $0 { return value as? Data == Data([4, 5]) }; return false })
        XCTAssertTrue(events.contains { if case .removedEntityTag(_, "old") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .updatedRelationship = $0 { return true }; return false })
        try graph.transaction { scoped in
            try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Category")).sync().first).delete()
        }
        drain()
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.last!.events.contains { if case .deletedEntity(let node) = $0 {
            XCTAssertTrue(node.managedNode.managedObjectContext === graph.managedObjectContext || node.managedNode.managedObjectContext == nil)
            return true
        }; return false })
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        _ = Entity("NextSave", graph: graph)
        graph.sync()
        drain()
        XCTAssertEqual(reports.count, 3)
        XCTAssertFalse(reports.last!.events.contains { if case .deletedEntity = $0 { return true }; return false },
                       "A later ordinary save must not repeat transaction deletions")
        withExtendedLifetime((bill, category, link)) {}
    }

    func testNoReportsForNoOpRollbackSourceFilterOrPendingEdits() throws {
        enum Failure: Error { case rollback }
        let graph = makeGraph()
        var count = 0
        graph.watchReportCompletion = { _, _ in count += 1 }
        try graph.transaction { _ in }
        XCTAssertThrowsError(try graph.transaction { scoped in
            _ = Entity("RolledBack", graph: scoped)
            throw Failure.rollback
        })
        graph.watchReportSources = [.cloud]
        try graph.transaction { _ = Entity("Filtered", graph: $0) }
        drain()
        XCTAssertEqual(count, 0)
        graph.watchReportSources = [.local]
        let pending = Entity("Pending", graph: graph)
        XCTAssertThrowsError(try graph.transaction { _ in XCTFail("Body must not run") })
        drain()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(graph.managedObjectContext.hasChanges)
        XCTAssertTrue(pending.managedNode.isInserted)
        graph.managedObjectContext.rollback()
        _ = Entity("Ordinary", graph: graph)
        graph.sync()
        drain()
        XCTAssertEqual(count, 1)
    }

    func testCascadeDeletionAndHistoryDoNotDuplicateLocalReports() throws {
        let graph = makeGraph()
        let bill = Entity("Bill", graph: graph)
        let category = Entity("Category", graph: graph)
        let link = bill.is(relationship: "category").of(category)
        link[dynamicMember: "media"] = Data([9])
        let action = bill.will(action: "pay").add(objects: category)
        action[dynamicMember: "amount"] = 12
        graph.sync()
        graph.ph_debug_clearToken()
        var reports: [GraphWatchReport] = []
        graph.watchReportCompletion = { report, _ in if let report { reports.append(report) } }
        try graph.transaction(diagnosticID: UUID()) { scoped in
            try XCTUnwrap(Search<Action>(graph: scoped).where(.type("pay")).sync().first).delete()
            try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Category")).sync().first).delete()
        }
        drain()
        XCTAssertEqual(reports.count, 1)
        let events = try XCTUnwrap(reports.first).events
        XCTAssertTrue(events.contains { if case .deletedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .deletedRelationship = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .removedRelationshipProperty(_, "media", let value) = $0 { return value as? Data == Data([9]) }; return false })
        XCTAssertTrue(events.contains { if case .deletedAction = $0 { return true }; return false })
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        drain()
        XCTAssertEqual(reports.count, 1, "Local-authored history must not repeat the transaction as cloud")
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        withExtendedLifetime((bill, category, link, action)) {}
    }
}
