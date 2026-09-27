import CoreData
import XCTest
@testable import GraphEvo

final class GraphWatchRemoteDeletionTests: XCTestCase {
    private final class Warnings: GraphEventDelegate {
        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            if case .warning(.watchReportMaterializationFailed) = event {
                XCTFail("Confirmed deletions must not block delivery: \(event)")
            }
        }
    }

    private func graph() -> Graph {
        Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteDeletion-\(UUID()).sqlite"), migrationEnabled: false)
    }

    func testRemoteInsertThenDeleteKeepsDeletionEvidenceAndAdvancesToken() throws {
        let graph = graph()
        let background = try XCTUnwrap(graph.newBackgroundContext())
        var nodeID: NSManagedObjectID!
        var detailIDs = Set<NSManagedObjectID>()
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-TRANSIENT"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            let entity = Entity("Transient", graph: facade)
            entity[dynamicMember: "value"] = "payload"
            entity.add(tags: "tag").add(to: "group")
            try background.save()
            nodeID = entity.node.objectID
            for key in ["propertySet", "tagSet", "groupSet"] {
                detailIDs.formUnion(entity.node.objectIDs(forRelationshipNamed: key))
            }
            entity.delete()
            try background.save()
            _ = Entity("Survivor", graph: facade)
            try background.save()
        }
        let warnings = Warnings()
        graph.eventDelegate = warnings
        graph.watchReportSources = [.cloud]
        let received = expectation(description: "deletion evidence delivered")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.events.contains { if case .deletedEntity(let entity) = $0 { return entity.node.objectID == nodeID }; return false })
            XCTAssertFalse(report.events.contains { if case .insertedEntity(let entity) = $0 { return entity.node.objectID == nodeID }; return false })
            XCTAssertTrue(report.events.contains { if case .insertedEntity(let entity) = $0 { return entity.type == "Survivor" }; return false })
            XCTAssertEqual(Set(report.unmaterializedDeletions.map(\.objectID)), detailIDs)
            XCTAssertFalse(report.structuralValidationResults.contains { $0.objectID == nodeID })
            received.fulfill()
        }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        delivery.request()
        wait(for: [received], timeout: 3)
        let store = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        XCTAssertNotNil(try store.load())
        let duplicate = expectation(description: "no repeated deletions")
        duplicate.isInverted = true
        graph.watchReportCompletion = { _, _ in duplicate.fulfill() }
        delivery.request()
        wait(for: [duplicate], timeout: 0.3)
    }

    func testRemoteRemovalOfDetailsFromSurvivingOwnerProducesReferenceOnlyReport() throws {
        let graph = graph()
        let entity = Entity("SurvivingOwner", graph: graph)
        entity[dynamicMember: "value"] = "payload"
        entity.add(tags: "tag").add(to: "group")
        graph.sync()
        let details = Set(["propertySet", "tagSet", "groupSet"].flatMap { entity.node.objectIDs(forRelationshipNamed: $0) })
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-REMOVE-DETAILS"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            let owner = try XCTUnwrap(Search<Entity>(graph: facade).where(.type("SurvivingOwner")).sync().first)
            owner[dynamicMember: "value"] = nil
            owner.remove(tags: "tag").remove(from: "group")
            try background.save()
        }
        let warnings = Warnings()
        graph.eventDelegate = warnings
        graph.watchReportSources = [.cloud]
        let received = expectation(description: "unmaterialized deletions are report payload")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertEqual(Set(report.unmaterializedDeletions.map(\.objectID)), details)
            XCTAssertTrue(report.events.isEmpty)
            received.fulfill()
        }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        delivery.request()
        wait(for: [received], timeout: 3)
        XCTAssertTrue(entity.validateStructure().isValid)
    }

    func testRemoteDeletionOfPreviouslySavedNodeFamiliesPreservesEvidence() throws {
        let graph = graph()
        let nodes: [Node] = [Entity("Known", graph: graph), Relationship("Known", graph: graph), Action("Known", graph: graph)]
        for node in nodes {
            node[dynamicMember: "value"] = "payload"
            node.add(tags: "tag").add(to: "group")
        }
        graph.sync()
        let nodeIDs = Set(nodes.map { $0.node.objectID })
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-DELETE-KNOWN"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            Search<Entity>(graph: facade).where(.type("Known")).sync().forEach { $0.delete() }
            Search<Relationship>(graph: facade).where(.type("Known")).sync().forEach { $0.delete() }
            Search<Action>(graph: facade).where(.type("Known")).sync().forEach { $0.delete() }
            try background.save()
        }
        graph.watchReportSources = [.cloud]
        let warnings = Warnings()
        graph.eventDelegate = warnings
        let received = expectation(description: "known node deletion evidence")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            let deleted = report.events.compactMap { event -> NSManagedObjectID? in
                switch event {
                case .deletedEntity(let node): return node.node.objectID
                case .deletedRelationship(let node): return node.node.objectID
                case .deletedAction(let node): return node.node.objectID
                default: return nil
                }
            }
            XCTAssertEqual(Set(deleted), nodeIDs)
            XCTAssertEqual(report.unmaterializedDeletions.count, 9)
            XCTAssertTrue(report.structuralValidationResults.isEmpty)
            received.fulfill()
        }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        delivery.request()
        wait(for: [received], timeout: 3)
    }

}
