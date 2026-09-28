import CoreData
import XCTest
@testable import GraphEvo

/// Characterizes the existing global generation guard without weakening it.
final class GraphTransactionGenerationTests: XCTestCase {
    private func fixture() throws -> Graph {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("Generation-\(UUID()).sqlite"), migrationEnabled: false)
        let target = Entity("Target", graph: graph)
        target[dynamicMember: "value"] = "original"
        let unrelated = Entity("Counts", graph: graph)
        unrelated[dynamicMember: "value"] = "original"
        graph.sync()
        return graph
    }

    private func currentToken(_ coordinator: NSPersistentStoreCoordinator) throws -> NSQueryGenerationToken {
        let probe = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        probe.persistentStoreCoordinator = coordinator
        return try probe.performAndWait {
            try probe.setQueryGenerationFrom(.current)
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "ManagedEntity")
            request.resultType = .managedObjectIDResultType
            request.fetchLimit = 1
            _ = try probe.fetch(request)
            return try XCTUnwrap(probe.queryGenerationToken)
        }
    }

    private func run(_ label: String, rejects: Bool, mutation: (Graph) throws -> Void) throws {
        let graph = try fixture()
        let writer = try XCTUnwrap(graph.newBackgroundContext())
        let coordinator = try XCTUnwrap(writer.persistentStoreCoordinator)
        var generationChanged = false
        var refused = false
        do {
            try graph.transaction { scoped in
                let target = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Target")).sync().first)
                target[dynamicMember: "value"] = "staged"
                let pinned = try XCTUnwrap(scoped.managedObjectContext.queryGenerationToken)
                XCTAssertEqual(pinned, try currentToken(coordinator), "Independent contexts must compare equal before any writer")
                try writer.performAndWait {
                    writer.transactionAuthor = "CONCURRENT-CHARACTERIZATION"
                    let facade = Graph(transactionContext: writer, configuration: graph.configuration)
                    try mutation(facade)
                    if writer.hasChanges { try writer.save() }
                }
                generationChanged = pinned != (try currentToken(coordinator))
            }
        } catch GraphTransactionError.storeChanged { refused = true }
        XCTAssertEqual(refused, rejects, label)
        XCTAssertEqual(refused, generationChanged, label)
        let value = try graph.readSnapshot { scoped in
            Search<Entity>(graph: scoped).where(.type("Target")).sync().first?[dynamicMember: "value"] as? String
        }
        if refused { XCTAssertNotEqual(value, "staged", "Rejected staged changes must not leak") }
        else { XCTAssertEqual(value, "staged") }
        print("GENERATION_CASE \(label) changed=\(generationChanged) refused=\(refused)")
    }

    func testNoConcurrentWriteCommits() throws {
        try run("no-write", rejects: false) { _ in }
    }

    func testNoOpSaveCommits() throws {
        try run("no-op-save", rejects: false) { try $0.managedObjectContext.save() }
    }

    func testUnrelatedCountsPropertyWriteRejectsWholeTransaction() throws {
        try run("unrelated-counts-property", rejects: true) { writer in
            let node = try XCTUnwrap(Search<Entity>(graph: writer).where(.type("Counts")).sync().first)
            node[dynamicMember: "value"] = "concurrent"
        }
    }

    func testSamePropertyWriteRejectsWholeTransaction() throws {
        try run("same-property", rejects: true) { writer in
            let node = try XCTUnwrap(Search<Entity>(graph: writer).where(.type("Target")).sync().first)
            node[dynamicMember: "value"] = "concurrent"
        }
    }

    func testConcurrentTopologyChangeRejectsWholeTransaction() throws {
        try run("topology", rejects: true) { writer in
            let root = try XCTUnwrap(Search<Entity>(graph: writer).where(.type("Target")).sync().first)
            let other = try XCTUnwrap(Search<Entity>(graph: writer).where(.type("Counts")).sync().first)
            _ = root.is(relationship: "new-link").of(other)
        }
    }

    func testConcurrentDuplicateInsertionRejectsWholeTransaction() throws {
        try run("duplicate-insertion", rejects: true) { _ = Entity("Target", graph: $0) }
    }

    func testPublicStoreMetadataAssignmentDoesNotReject() throws {
        try run("public-store-metadata", rejects: false) { writer in
            let coordinator = try XCTUnwrap(writer.managedObjectContext.persistentStoreCoordinator)
            let store = try XCTUnwrap(coordinator.persistentStores.first)
            var metadata = coordinator.metadata(for: store)
            metadata["GraphEvoTests.Bookkeeping"] = UUID().uuidString
            coordinator.setMetadata(metadata, for: store)
        }
    }

    func testReadOnlyTransactionKeepsSnapshotAcrossUnrelatedWrite() throws {
        let graph = try fixture()
        let writer = try XCTUnwrap(graph.newBackgroundContext())
        try graph.transaction { scoped in
            let counts = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Counts")).sync().first)
            XCTAssertEqual(counts[dynamicMember: "value"] as? String, "original")
            try writer.performAndWait {
                let facade = Graph(transactionContext: writer, configuration: graph.configuration)
                let concurrent = try XCTUnwrap(Search<Entity>(graph: facade).where(.type("Counts")).sync().first)
                concurrent[dynamicMember: "value"] = "concurrent"
                try writer.save()
            }
            XCTAssertEqual(counts[dynamicMember: "value"] as? String, "original")
        }
        XCTAssertEqual(try graph.readSnapshot {
            Search<Entity>(graph: $0).where(.type("Counts")).sync().first?[dynamicMember: "value"] as? String
        }, "concurrent")
    }

    func testHistoryPruningRejectsWithoutDomainChanges() throws {
        try run("history-pruning", rejects: true) { writer in
            _ = try writer.managedObjectContext.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
        }
    }
}
