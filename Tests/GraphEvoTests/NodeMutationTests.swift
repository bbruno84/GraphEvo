import XCTest
@testable import GraphEvo

final class NodeMutationTests: XCTestCase {
    private func makeGraph(_ suffix: String) -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "NodeMutation-\(suffix)-\(UUID().uuidString)"
        configuration.backend = .inMemory
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    func testPropertyTagGroupMutationAndConditions() {
        let graph = makeGraph("Metadata")
        let entity = Entity("Mutable", graph: graph)
        entity[dynamicMember: "value"] = "first"
        entity[dynamicMember: "value"] = "second"
        entity[dynamicMember: "temporary"] = 1
        XCTAssertEqual(entity.properties["value"] as? String, "second")
        XCTAssertEqual(entity[dynamicMember: "temporary"] as? Int, 1)

        entity[dynamicMember: "temporary"] = nil
        XCTAssertNil(entity[dynamicMember: "temporary"])

        entity.add(tags: ["red", "important", "red"])
        XCTAssertTrue(entity.has(tags: ["red", "important"], using: .and))
        XCTAssertTrue(entity.has(tags: ["missing", "red"], using: .or))
        XCTAssertFalse(entity.has(tags: ["missing", "red"], using: .and))
        entity.toggle(tags: "red", "new")
        XCTAssertFalse(entity.has(tags: "red"))
        XCTAssertTrue(entity.has(tags: "new"))
        entity.remove(tags: "new")
        XCTAssertFalse(entity.has(tags: "new"))

        entity.add(to: ["inbox", "review"])
        XCTAssertTrue(entity.member(of: ["inbox", "review"], using: .and))
        XCTAssertTrue(entity.member(of: ["missing", "review"], using: .or))
        entity.toggle(groups: "inbox", "done")
        XCTAssertFalse(entity.member(of: "inbox"))
        XCTAssertTrue(entity.member(of: "done"))
        entity.remove(from: "done")
        XCTAssertFalse(entity.member(of: "done"))
    }

    func testRelationshipsActionsFiltersDeletionAndNodeCodableRoundTrip() throws {
        let graph = makeGraph("Relations")
        let subject = Entity("Person", graph: graph)
        subject[dynamicMember: "name"] = "Alice"
        subject.add(tags: "person")
        subject.add(to: "people")
        let object = Entity("Company", graph: graph)
        let relationship = subject.is(relationship: "worksAt").of(object)
        let action = subject.did(action: "send").what(objects: object)
        graph.sync()

        XCTAssertEqual(subject.relationship(types: "worksAt").count, 1)
        XCTAssertEqual(subject.relationship(types: "missing").count, 0)
        XCTAssertEqual(subject.action(types: "send").count, 1)
        XCTAssertEqual(subject.actions.count, 1)
        XCTAssertEqual(action.subject(types: "Person").count, 1)
        XCTAssertEqual(action.object(types: "Company").count, 1)
        XCTAssertEqual(relationship.subject?.id, subject.id)
        XCTAssertEqual(relationship.object?.id, object.id)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(subject)
        let decoder = JSONDecoder()
        decoder.userInfo[.graph] = graph
        let decoded = try decoder.decode(Entity.self, from: encoded)
        XCTAssertEqual(decoded.type, "Person")
        XCTAssertEqual(decoded[dynamicMember: "name"] as? String, "Alice")
        XCTAssertTrue(decoded.has(tags: "person"))
        XCTAssertTrue(decoded.member(of: "people"))

        relationship.delete()
        action.delete()
        graph.sync()
        XCTAssertTrue(Search<Relationship>(graph: graph).where(.type("worksAt")).sync().isEmpty)
        XCTAssertTrue(Search<Action>(graph: graph).where(.type("send")).sync().isEmpty)
    }
}
