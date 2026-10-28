import XCTest
@testable import GraphEvo

final class GraphExactLookupTests: XCTestCase {
    private func makeGraph() -> Graph {
        Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactLookup-\(UUID()).sqlite"), migrationEnabled: false)
    }

    func testExactStringPreservesDuplicatesAndLiteralCharacters() throws {
        let graph = makeGraph()
        let first = Entity("Bolletta", graph: graph)
        first[dynamicMember: "codice_bolletta"] = "Ä*?_[%]"
        let second = Entity("Bolletta", graph: graph)
        second[dynamicMember: "codice_bolletta"] = "Ä*?_[%]"
        let differentCase = Entity("Bolletta", graph: graph)
        differentCase[dynamicMember: "codice_bolletta"] = "ä*?_[%]"
        let differentType = Entity("Other", graph: graph)
        differentType[dynamicMember: "codice_bolletta"] = "Ä*?_[%]"
        graph.sync()

        let matches = graph.entities(type: "Bolletta", property: "codice_bolletta", exactly: "Ä*?_[%]")
        XCTAssertEqual(Set(matches.map(\.id)), Set([first.id, second.id]))
        graph.batchOffset = 1
        XCTAssertEqual(Set(graph.entities(type: "Bolletta", property: "codice_bolletta", exactly: "Ä*?_[%]").map(\.id)), Set([first.id, second.id]))
        graph.batchOffset = 0
        XCTAssertEqual(graph.entities(type: "Bolletta", property: "codice_bolletta", exactly: "ä*?_[%]").map(\.id), [differentCase.id])
        XCTAssertTrue(graph.entities(type: "Bolletta", property: "codice_bolletta", exactly: "A*?_[%]").isEmpty)

        let snapshotIDs = try graph.readSnapshot { scoped in
            Set(scoped.entities(type: "Bolletta", property: "codice_bolletta", exactly: "Ä*?_[%]").map(\.id))
        }
        XCTAssertEqual(snapshotIDs, Set([first.id, second.id]))
    }

    func testPhysicalIDsAndDirectedRelationshipsInScopes() throws {
        let graph = makeGraph()
        let bill = Entity("Bolletta", graph: graph)
        let category = Entity("Categoria", graph: graph)
        let unrelated = Entity("Bolletta", graph: graph)
        let edge = bill.is(relationship: "classified").of(category)
        let reverse = category.is(relationship: "classified").of(bill)
        let another = unrelated.is(relationship: "classified").of(category)
        graph.sync()

        XCTAssertEqual(Set(graph.entities(type: "Bolletta", matchingIDs: [bill.id, unrelated.id, "bad"]).map(\.id)), Set([bill.id, unrelated.id]))
        XCTAssertTrue(graph.entities(type: "Categoria", matchingIDs: [bill.id]).isEmpty)
        XCTAssertTrue(graph.entities(type: "Bolletta", matchingIDs: []).isEmpty)
        XCTAssertEqual(graph.relationships(type: "classified", subjectIDs: [bill.id]).map(\.id), [edge.id])
        XCTAssertEqual(Set(graph.relationships(type: "classified", objectIDs: [category.id]).map(\.id)), Set([edge.id, another.id]))
        XCTAssertEqual(graph.relationships(type: "classified", subjectIDs: [category.id], objectIDs: [bill.id]).map(\.id), [reverse.id])
        XCTAssertTrue(graph.relationships(type: "classified", subjectIDs: []).isEmpty)
        graph.batchOffset = 1
        XCTAssertEqual(Set(graph.relationships(type: "classified", objectIDs: [category.id]).map(\.id)), Set([edge.id, another.id]))
        graph.batchOffset = 0

        try graph.readSnapshot { scoped in
            XCTAssertEqual(scoped.entities(type: "Bolletta", matchingIDs: [bill.id]).first?.id, bill.id)
            XCTAssertEqual(scoped.relationships(type: "classified", subjectIDs: [bill.id], objectIDs: [category.id]).map(\.id), [edge.id])
        }
        try graph.transaction { scoped in
            XCTAssertEqual(scoped.entities(type: "Bolletta", matchingIDs: [bill.id]).first?.id, bill.id)
            XCTAssertEqual(scoped.relationships(type: "classified", subjectIDs: [category.id], objectIDs: [bill.id]).map(\.id), [reverse.id])
        }
    }

    func testPendingDraftsAreVisibleOnlyInOwningContext() throws {
        let graph = makeGraph()
        let draft = Entity("Bolletta", graph: graph)
        draft[dynamicMember: "codice_bolletta"] = "draft*"
        let draftID = draft.id
        XCTAssertEqual(graph.entities(type: "Bolletta", matchingIDs: [draftID]).map(\.id), [draftID])
        XCTAssertEqual(graph.entities(type: "Bolletta", property: "codice_bolletta", exactly: "draft*").map(\.id), [draftID])
        XCTAssertTrue(try graph.readSnapshot { $0.entities(type: "Bolletta", matchingIDs: [draftID]).isEmpty })
    }

    func testUnknownIDFromAnotherStoreDoesNotResolve() {
        let local = makeGraph()
        let own = Entity("Bolletta", graph: local)
        local.sync()
        let foreign = makeGraph()
        for _ in 0..<12 { _ = Entity("Bolletta", graph: foreign) }
        foreign.sync()
        let foreignID = Search<Entity>(graph: foreign).where(.type("Bolletta"))
            .sync().map(\.id).first { $0 != own.id }
        XCTAssertNotNil(foreignID)
        XCTAssertTrue(local.entities(type: "Bolletta", matchingIDs: [foreignID!]).isEmpty)
    }
}
