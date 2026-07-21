import XCTest
import CoreData
@testable import Graph

final class CoreGraphAPITests: XCTestCase {
    func testInMemoryBackendAndBackgroundContext() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "InMemory-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let graph = Graph(configuration: configuration, migrationEnabled: false)
        XCTAssertEqual(graph.type, NSInMemoryStoreType)
        XCTAssertNotNil(graph.managedObjectContext)

        let background = graph.newBackgroundContext()
        XCTAssertNotNil(background)
        XCTAssertEqual(background?.transactionAuthor, GraphDeviceAuthor.current())

        let entity = Entity("Ephemeral", graph: graph)
        entity[dynamicMember: "value"] = "memory"
        var saveSuccess = false
        graph.sync { success, _ in saveSuccess = success }
        XCTAssertTrue(saveSuccess)
        XCTAssertEqual(
            Search<Entity>(graph: graph).where(.type("Ephemeral")).sync().first?[dynamicMember: "value"] as? String,
            "memory"
        )
    }

    func testEntityRelationshipAndActionRoundTrip() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "CoreAPI-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let subject = Entity("Person", graph: graph)
        subject[dynamicMember: "uuid"] = "subject-1"
        let object = Entity("Person", graph: graph)
        object[dynamicMember: "uuid"] = "object-1"

        let relationship = subject.is(relationship: "knows")
        XCTAssertTrue(relationship.of(object) === relationship)
        XCTAssertEqual([relationship].subject(types: "Person").map(\.id), [subject.id])
        XCTAssertEqual([relationship].object(types: "Person").map(\.id), [object.id])

        let action = subject.will(action: "message")
        XCTAssertTrue(action.what(objects: object) === action)
        XCTAssertEqual(action.subject(types: "Person").map(\.id), [subject.id])
        XCTAssertEqual(action.object(types: "Person").map(\.id), [object.id])
        action.remove(objects: object).add(objects: object)
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

    func testTagsGroupsAndCompoundSearchPredicates() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Predicates-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let tagged = Entity("Tagged", graph: graph)
        tagged[dynamicMember: "name"] = "target"
        tagged.add(tags: ["red", "important"])
        tagged.add(to: "inbox")

        let other = Entity("Other", graph: graph)
        other[dynamicMember: "name"] = "other"
        other.add(tags: ["blue"])
        graph.sync()

        XCTAssertTrue(tagged.has(tags: "red", "important"))
        XCTAssertTrue(tagged.member(of: "inbox"))
        XCTAssertFalse(other.has(tags: "red"))

        let taggedResults = Search<Entity>(graph: graph)
            .where(.type("Tagged") && .has(tags: "red"))
            .sync()
        XCTAssertEqual(taggedResults.map(\.id), [tagged.id])

        let nonMatchingResults = Search<Entity>(graph: graph)
            .where(.type("Tagged") && !.exists("missing-property"))
            .sync()
        XCTAssertEqual(nonMatchingResults.count, 1)
    }
}
