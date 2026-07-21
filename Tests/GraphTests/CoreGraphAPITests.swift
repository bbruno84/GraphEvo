import XCTest
@testable import Graph

final class CoreGraphAPITests: XCTestCase {
    func testEntityRelationshipAndActionRoundTrip() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "CoreAPI-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let subject = Entity("Person", graph: graph)
        subject[dynamicMember: "uuid"] = "subject-1"
        let object = Entity("Person", graph: graph)
        object[dynamicMember: "uuid"] = "object-1"

        let relationship = subject.is(relationship: "knows")
        relationship.object = object

        let action = subject.will(action: "message")
        action.add(objects: object)
        graph.sync()

        let relationships = Search<Relationship>(graph: graph).where(.type("knows")).sync()
        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships.first?.subject?.id, subject.id)
        XCTAssertEqual(relationships.first?.object?.id, object.id)

        let actions = Search<Action>(graph: graph).where(.type("message")).sync()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.subjects.map(\.id), [subject.id])
        XCTAssertEqual(actions.first?.objects.map(\.id), [object.id])
    }
}
