import XCTest
@testable import GraphEvo

final class WatcherSpecializedTests: XCTestCase {
    func testRelationshipAndActionInsertionCallbacks() {
        let relationshipExpectation = expectation(description: "relationship callback")
        let actionExpectation = expectation(description: "action callback")

        final class RelationshipDelegate: NSObject, GraphRelationshipDelegate {
            let expectation: XCTestExpectation
            init(_ expectation: XCTestExpectation) { self.expectation = expectation }
            func graph(_ graph: Graph, inserted relationship: Relationship, source: GraphSource) {
                XCTAssertEqual(relationship.type, "knows")
                XCTAssertEqual(source, .local)
                XCTAssertNotNil(relationship.subject)
                XCTAssertNotNil(relationship.object)
                expectation.fulfill()
            }
        }

        final class ActionDelegate: NSObject, GraphActionDelegate {
            let expectation: XCTestExpectation
            init(_ expectation: XCTestExpectation) { self.expectation = expectation }
            func graph(_ graph: Graph, inserted action: Action, source: GraphSource) {
                XCTAssertEqual(action.type, "message")
                XCTAssertEqual(source, .local)
                XCTAssertEqual(action.subjects.count, 1)
                XCTAssertEqual(action.objects.count, 1)
                expectation.fulfill()
            }
        }

        var configuration = GraphStoreConfiguration()
        configuration.name = "SpecializedWatchers-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let relationshipWatcher = Watch<Relationship>(graph: graph).where(.type("knows"))
        let actionWatcher = Watch<Action>(graph: graph).where(.type("message"))
        let relationshipDelegate = RelationshipDelegate(relationshipExpectation)
        let actionDelegate = ActionDelegate(actionExpectation)
        relationshipWatcher.delegate = relationshipDelegate
        actionWatcher.delegate = actionDelegate

        let subject = Entity("Person", graph: graph)
        let object = Entity("Person", graph: graph)
        subject.is(relationship: "knows").object = object
        subject.will(action: "message").add(objects: object)

        graph.async { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
        }

        wait(for: [relationshipExpectation, actionExpectation], timeout: 2.0)
    }
}
