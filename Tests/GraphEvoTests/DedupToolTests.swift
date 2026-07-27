import XCTest
@testable import GraphEvo

final class DedupToolTests: XCTestCase {
    private struct PreferCanonical: DedupDiscriminator {
        func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
            if (lhs[dynamicMember: "source"] as? String) == "canonical" {
                return lhs
            }
            return rhs
        }
    }

    func testDeduplicateAllMergesMetadataRelationshipsAndDeletesDuplicate() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "DedupToolAll-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let canonical = Entity("Person", graph: graph)
        canonical[dynamicMember: "uuid"] = "person-1"
        canonical[dynamicMember: "source"] = "canonical"
        canonical[dynamicMember: "name"] = "canonical-name"

        let duplicate = Entity("Person", graph: graph)
        duplicate[dynamicMember: "uuid"] = "person-1"
        duplicate[dynamicMember: "source"] = "duplicate"
        duplicate[dynamicMember: "extra"] = "kept-from-duplicate"
        duplicate.add(tags: "imported")
        duplicate.add(to: "review")

        let related = Entity("Person", graph: graph)
        related[dynamicMember: "uuid"] = "person-2"
        duplicate.is(relationship: "knows").object = related
        graph.sync()

        try DedupTool(graph: graph, discriminator: PreferCanonical())
            .deduplicateAll(uuidFieldMap: ["Person": "uuid"])

        let people = Search<Entity>(graph: graph).where(.type("Person")).sync()
        XCTAssertEqual(people.count, 2)
        let survivor = try XCTUnwrap(people.first { ($0[dynamicMember: "uuid"] as? String) == "person-1" })
        XCTAssertEqual(survivor[dynamicMember: "source"] as? String, "canonical")
        XCTAssertEqual(survivor[dynamicMember: "name"] as? String, "canonical-name")
        XCTAssertEqual(survivor[dynamicMember: "extra"] as? String, "kept-from-duplicate")
        XCTAssertTrue(survivor.has(tags: "imported"))
        XCTAssertTrue(survivor.member(of: "review"))

        let relationship = try XCTUnwrap(
            Search<Relationship>(graph: graph).where(.type("knows")).sync().first
        )
        XCTAssertEqual(relationship.subject?.id, survivor.id)
        XCTAssertEqual(relationship.object?[dynamicMember: "uuid"] as? String, "person-2")
    }

    func testDeduplicateSingleOnlyTouchesMatchingLogicalUUID() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "DedupToolSingle-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration, migrationEnabled: false)

        let first = Entity("Person", graph: graph)
        first[dynamicMember: "uuid"] = "person-1"
        first[dynamicMember: "source"] = "canonical"
        let second = Entity("Person", graph: graph)
        second[dynamicMember: "uuid"] = "person-1"
        second[dynamicMember: "source"] = "duplicate"
        let unrelated = Entity("Person", graph: graph)
        unrelated[dynamicMember: "uuid"] = "person-2"
        graph.sync()

        try DedupTool(graph: graph, discriminator: PreferCanonical())
            .deduplicateSingle(second, uuidFieldMap: ["Person": "uuid"])

        let people = Search<Entity>(graph: graph).where(.type("Person")).sync()
        XCTAssertEqual(people.count, 2)
        XCTAssertNotNil(people.first { ($0[dynamicMember: "uuid"] as? String) == "person-2" })
        XCTAssertEqual(
            people.first { ($0[dynamicMember: "uuid"] as? String) == "person-1" }?[dynamicMember: "source"] as? String,
            "canonical"
        )
    }

    func testDeduplicateBetweenCreatesSecondaryOnlyEntitiesAndRelationships() throws {
        var primaryConfiguration = GraphStoreConfiguration()
        primaryConfiguration.name = "DedupToolPrimary-\(UUID().uuidString)"
        primaryConfiguration.backend = .inMemory
        var secondaryConfiguration = GraphStoreConfiguration()
        secondaryConfiguration.name = "DedupToolSecondary-\(UUID().uuidString)"
        secondaryConfiguration.backend = .inMemory

        let primary = Graph(configuration: primaryConfiguration, migrationEnabled: false)
        let secondary = Graph(configuration: secondaryConfiguration, migrationEnabled: false)

        let existing = Entity("Person", graph: primary)
        existing[dynamicMember: "uuid"] = "existing"
        existing[dynamicMember: "source"] = "canonical"

        let imported = Entity("Person", graph: secondary)
        imported[dynamicMember: "uuid"] = "imported"
        imported[dynamicMember: "source"] = "secondary"
        let importedTarget = Entity("Person", graph: secondary)
        importedTarget[dynamicMember: "uuid"] = "target"
        imported.is(relationship: "knows").object = importedTarget
        primary.sync()
        secondary.sync()

        try DedupTool.deduplicateBetween(
            primaryGraph: primary,
            secondaryGraph: secondary,
            discriminator: PreferCanonical(),
            uuidFieldMap: ["Person": "uuid"]
        )

        let people = Search<Entity>(graph: primary).where(.type("Person")).sync()
        XCTAssertEqual(people.count, 3)
        XCTAssertNotNil(people.first { ($0[dynamicMember: "uuid"] as? String) == "imported" })
        XCTAssertNotNil(people.first { ($0[dynamicMember: "uuid"] as? String) == "target" })
        let relationship = try XCTUnwrap(
            Search<Relationship>(graph: primary).where(.type("knows")).sync().first
        )
        XCTAssertEqual(relationship.subject?[dynamicMember: "uuid"] as? String, "imported")
        XCTAssertEqual(relationship.object?[dynamicMember: "uuid"] as? String, "target")
    }
}
