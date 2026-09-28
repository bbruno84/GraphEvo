import CoreData
import XCTest
@testable import GraphEvo

final class GraphStructuralValidationTests: XCTestCase {
    private func makeGraph() -> Graph {
        Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuralValidation-\(UUID().uuidString).sqlite"), migrationEnabled: false)
    }

    func testUnsavedRootFailsAndSavedEmptyRootSucceeds() {
        let graph = makeGraph()
        let entity = Entity("Empty", graph: graph)
        let unsaved = entity.validateStructure()
        XCTAssertFalse(unsaved.isValid)
        XCTAssertEqual(unsaved.issues.count, 1)
        XCTAssertNotNil(unsaved.issues.first?.error)
        graph.sync()
        let saved = entity.validateStructure()
        XCTAssertTrue(saved.isValid)
        XCTAssertEqual(saved.references.filter { $0.state == .absent }.count, 7)
    }

    func testOptionalEndpointsAreAbsentWithoutFailure() {
        let graph = makeGraph()
        let relationship = Relationship("Optional", graph: graph)
        let action = Action("Optional", graph: graph)
        graph.sync()
        for (node, keys) in [(relationship as Node, ["subject", "object"]), (action as Node, ["subjectSet", "objectSet"])] {
            let result = node.validateStructure()
            XCTAssertTrue(result.isValid)
            for key in keys {
                let reference = result.references.first { $0.relationshipName == key }
                XCTAssertEqual(reference?.state, .absent)
                XCTAssertNil(reference?.destinationObjectID)
                XCTAssertNil(reference?.error)
            }
        }
    }

    func testEntityIncludesEdgeDetailsAndEndpointsButStopsAtEndpointEntities() {
        let graph = makeGraph()
        let root = Entity("Root", graph: graph)
        root[dynamicMember: "name"] = "Root"
        root.add(tags: "tag").add(to: "group")
        let endpoint = Entity("Endpoint", graph: graph)
        let distant = Entity("Distant", graph: graph)
        endpoint[dynamicMember: "outsideScope"] = "value"
        let outsideEdge = endpoint.is(relationship: "outside").of(distant)
        let edge = root.is(relationship: "inside").of(endpoint)
        edge[dynamicMember: "weight"] = 1
        edge.add(tags: "edgeTag").add(to: "edgeGroup")
        let action = root.will(action: "Act").add(objects: endpoint, distant)
        action[dynamicMember: "payload"] = ["value": "stored"]
        action.add(tags: "actionTag").add(to: "actionGroup")
        graph.sync()

        let result = root.validateStructure()
        XCTAssertTrue(result.isValid)
        for owner in [root as Node, edge, action] {
            for key in ["propertySet", "tagSet", "groupSet"] {
                XCTAssertTrue(result.references.contains {
                    $0.sourceObjectID == owner.node.objectID && $0.relationshipName == key && $0.state == .materialized
                })
            }
        }
        XCTAssertTrue(result.references.contains { $0.destinationObjectID == endpoint.node.objectID })
        XCTAssertTrue(result.references.contains { $0.destinationObjectID == distant.node.objectID })
        XCTAssertFalse(result.references.contains { $0.sourceObjectID == endpoint.node.objectID })
        XCTAssertFalse(result.references.contains { $0.destinationObjectID == outsideEdge.node.objectID })
        for node in [edge as Node, action] {
            let direct = node.validateStructure()
            XCTAssertTrue(direct.isValid)
            XCTAssertFalse(direct.references.contains { $0.sourceObjectID == root.node.objectID })
        }
    }

    func testUnsavedLinksAndRemovalsDoNotChangePersistedValidation() {
        let graph = makeGraph()
        let root = Entity("Root", graph: graph)
        root.add(tags: "saved")
        graph.sync()
        root.remove(tags: "saved")
        _ = root.is(relationship: "unsaved").of(Entity("Unsaved", graph: graph))
        let result = root.validateStructure()
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.references.first { $0.relationshipName == "tagSet" }?.state, .materialized)
        XCTAssertEqual(result.references.first { $0.relationshipName == "relationshipSubjectSet" }?.state, .absent)
        graph.managedObjectContext.rollback()
    }

    func testPermanentIDWithoutSavedRowStillFails() throws {
        let graph = makeGraph()
        let root = Entity("NeverSaved", graph: graph)
        try graph.managedObjectContext.obtainPermanentIDs(for: [root.node])
        XCTAssertFalse(root.node.objectID.isTemporaryID)
        XCTAssertFalse(root.validateStructure().isValid)
    }

    func testMeshAndSelfLoopsRemainBounded() {
        let graph = makeGraph()
        let a = Entity("A", graph: graph)
        let b = Entity("B", graph: graph)
        let c = Entity("C", graph: graph)
        _ = a.is(relationship: "self").of(a)
        _ = a.is(relationship: "ab").of(b)
        let bc = b.is(relationship: "bc").of(c)
        _ = c.is(relationship: "ca").of(a)
        graph.sync()
        let result = a.validateStructure()
        XCTAssertTrue(result.isValid)
        XCTAssertFalse(result.references.contains { $0.destinationObjectID == bc.node.objectID })
        XCTAssertLessThan(result.references.count, 60)
    }

    func testDeletedRootFailsDirectValidationButDoesNotBlockDeletionReport() {
        let graph = makeGraph()
        let entity = Entity("Deleted", graph: graph)
        graph.sync()
        let id = entity.node.objectID
        let delivered = expectation(description: "deletion remains deliverable")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.events.contains { if case .deletedEntity = $0 { return true }; return false })
            XCTAssertFalse(report.structuralValidationResults.contains { $0.objectID == id })
            delivered.fulfill()
        }
        entity.delete()
        graph.sync()
        wait(for: [delivered], timeout: 2)
        XCTAssertFalse(entity.validateStructure().isValid)
    }

    func testLocalReportExposesSameScopeAsDirectAPI() {
        let graph = makeGraph()
        let entity = Entity("Root", graph: graph)
        let delivered = expectation(description: "validated local report")
        graph.watchReportCompletion = { report, _ in
            guard let report else { return }
            let result = report.structuralValidationResults.first { $0.objectID == entity.node.objectID }
            XCTAssertEqual(result?.isValid, true)
            XCTAssertEqual(result?.references.count, entity.validateStructure().references.count)
            delivered.fulfill()
        }
        graph.sync()
        wait(for: [delivered], timeout: 2)
    }

    func testDanglingEndpointIsReportedAndDoesNotTraverseItsEntity() throws {
        let graph = makeGraph()
        let root = Entity("Root", graph: graph)
        let target = Entity("Target", graph: graph)
        let edge = root.is(relationship: "link").of(target)
        graph.sync()
        let targetID = target.node.objectID
        // A store-level deletion deliberately bypasses facade cleanup to model an unresolved reference.
        let context = try XCTUnwrap(graph.newBackgroundContext())
        try context.performAndWait {
            _ = try context.execute(NSBatchDeleteRequest(objectIDs: [targetID]))
        }
        let result = edge.validateStructure()
        let endpoint = try XCTUnwrap(result.references.first { $0.relationshipName == "object" })
        XCTAssertEqual(endpoint.state, .unresolved)
        XCTAssertEqual(endpoint.destinationObjectID, targetID)
        XCTAssertNotNil(endpoint.error)
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(root.validateStructure().isValid)
    }

    func testCloudValidationFailureRetainsDeliveryTokenAndRetriesAfterRepair() throws {
        final class Warnings: GraphEventDelegate {
            var onFailure: ((GraphStructuralValidationFailure) -> Void)?
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                guard case .warning(.watchReportMaterializationFailed(_, _, let details)) = event else { return }
                for detail in details {
                    if let failure = detail.error as? GraphStructuralValidationFailure { onFailure?(failure) }
                }
            }
        }
        let graph = makeGraph()
        let root = Entity("Root", graph: graph)
        let target = Entity("Target", graph: graph)
        _ = root.is(relationship: "link").of(target)
        graph.sync()
        let targetID = target.node.objectID
        let context = try XCTUnwrap(graph.newBackgroundContext())
        try context.performAndWait {
            context.transactionAuthor = GraphDeviceAuthor.current()
            _ = try context.execute(NSBatchDeleteRequest(objectIDs: [targetID]))
            context.transactionAuthor = "REMOTE-STRUCTURAL-VALIDATION"
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            let relationship = try XCTUnwrap(Search<Relationship>(graph: facade).where(.type("link")).sync().first)
            relationship[dynamicMember: "remote"] = "update"
            try context.save()
        }
        let warnings = Warnings()
        graph.eventDelegate = warnings
        graph.watchReportSources = [.cloud]
        let failureReceived = expectation(description: "structural failure")
        failureReceived.assertForOverFulfill = false
        warnings.onFailure = { failure in
            XCTAssertFalse(failure.result.isValid)
            XCTAssertTrue(failure.result.issues.contains { $0.destinationObjectID == targetID })
            failureReceived.fulfill()
        }
        let premature = expectation(description: "no partial report")
        premature.isInverted = true
        graph.watchReportCompletion = { report, _ in if report != nil { premature.fulfill() } }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        let tokenStore = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        XCTAssertNil(try tokenStore.load())
        delivery.request()
        wait(for: [failureReceived, premature], timeout: 0.5)
        XCTAssertNil(try tokenStore.load())

        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            let relationship = try XCTUnwrap(Search<Relationship>(graph: facade).where(.type("link")).sync().first)
            relationship.object = Entity("Replacement", graph: facade)
            try context.save()
        }
        let received = expectation(description: "retry succeeds")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertFalse(report.structuralValidationResults.isEmpty)
            XCTAssertTrue(report.structuralValidationResults.allSatisfy(\.isValid))
            received.fulfill()
        }
        delivery.request()
        wait(for: [received], timeout: 3)
        XCTAssertNotNil(try tokenStore.load())
    }


    func testInMemoryBackendUsesSavedState() {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidationMemory-\(UUID().uuidString)"), backend: .inMemory, migrationEnabled: false)
        let entity = Entity("Root", graph: graph)
        XCTAssertFalse(entity.validateStructure().isValid)
        graph.sync()
        XCTAssertTrue(entity.validateStructure().isValid)
    }

    func testValidationDoesNotCrossStoresWithMatchingTypes() {
        let first = makeGraph()
        let second = makeGraph()
        let persisted = Entity("Same", graph: first)
        first.sync()
        let unsaved = Entity("Same", graph: second)
        XCTAssertTrue(persisted.validateStructure().isValid)
        XCTAssertFalse(unsaved.validateStructure().isValid)
        second.sync()
        XCTAssertNotEqual(persisted.validateStructure().objectID, unsaved.validateStructure().objectID)
    }

}
