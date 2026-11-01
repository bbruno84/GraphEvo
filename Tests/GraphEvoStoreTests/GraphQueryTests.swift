import Foundation
import Testing
import GraphEvo

private struct QueryPerson: GraphModel {
    static let graphType = "Q.person"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { let _: String = try graphRecord.value(for: "name"); record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}
private struct QueryEdge: GraphModel {
    static let graphType = "Q.edge"
    static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}
private struct QueryAction: GraphModel {
    static let graphType = "Q.action"
    static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(1))) struct GraphQueryTests {
    private struct Fixture {
        let db: GraphDatabase; let graph: GraphStore; let other: GraphStore
        let ids: [GraphNodeID]
        func close() async throws { try await graph.close(); try await other.close(); try await db.close() }
    }
    @Test func finiteIdentityQueriesKeepRelationshipAndActionEndpointsComplete() async throws {
        let fixture = try await fixture(), graph = fixture.graph, ids = fixture.ids
        let secondAction = graph.makeNodeID()
        try await graph.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: ids[4], properties: ["unused": .set(.data(Data(repeating: 1, count: 1024 * 1024)))]))
            try scope.insert(GraphRecord(id: secondAction, type: QueryAction.graphType, endpoints: .action(subjects: [ids[0]], objects: [ids[2]]), properties: ["unused": .data(Data(repeating: 1, count: 1024 * 1024))]))
        }
        let allowance = try budget(bytes: 16 * 1024)
        let edge = try await graph.query(GraphQuery<QueryEdge>(budget: allowance).where(.id(ids[3])))
        #expect(edge.items.first?.record.endpoints == .relationship(subject: ids[0], object: ids[1]))
        let action = try await graph.query(GraphQuery<QueryAction>(budget: allowance).where(.id(ids[5])))
        #expect(action.items.first?.record.endpoints == .action(subjects: [ids[0], ids[1]], objects: [ids[2]]))
        try await fixture.close()
    }

    private func budget(_ candidates: Int = 128, bytes: Int = 1024 * 1024, steps: Int = 100_000) throws -> GraphQueryBudget {
        try GraphQueryBudget(maximumCandidates: candidates, maximumPropertyBytes: bytes, maximumSteps: steps)
    }
    private func fixture() async throws -> Fixture {
        let db = try await GraphDatabase.inMemory(), graph = try await db.createGraph(), other = try await db.createGraph()
        let ids = (1...6).map { GraphNodeID(graphID: graph.id, rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!) }
        try await graph.transaction { scope in
            for index in 0..<3 {
                var properties: [String: GraphValue] = ["name": .string(["Alice", "Bob", "Cara"][index]), "rank": .integer(index == 2 ? 2 : 1), "blob": .data(Data([0, 255]))]
                if index != 1 { properties["nick"] = index == 0 ? .null : .string("C") }
                try scope.insert(GraphRecord(id: ids[index], type: QueryPerson.graphType, properties: properties,
                    tags: index == 1 ? [] : ["active"], groups: index == 2 ? [] : ["team"]))
            }
            try scope.insert(GraphRecord(id: ids[3], type: QueryEdge.graphType, endpoints: .relationship(subject: ids[0], object: ids[1])))
            try scope.insert(GraphRecord(id: ids[4], type: QueryEdge.graphType, endpoints: .relationship(subject: ids[1], object: ids[0])))
            try scope.insert(GraphRecord(id: ids[5], type: QueryAction.graphType, endpoints: .action(subjects: [ids[0],ids[1]], objects: [ids[2]])))
        }
        let foreign = GraphNodeID(graphID: other.id, rawValue: ids[0].rawValue)
        try await other.transaction { try $0.insert(GraphRecord(id: foreign, type: QueryPerson.graphType, properties: ["name": .string("Leak"), "rank": .integer(0)])) }
        return Fixture(db: db, graph: graph, other: other, ids: ids)
    }

    @Test func booleanCompositionMissingNullAndLiteralStringsHaveExplicitSemantics() async throws {
        let f = try await fixture(), base = GraphQuery<QueryPerson>(budget: try budget())
        #expect(try await f.graph.query(base.where(.tag("active")).where(.property("rank", .greaterThan, .integer(1)))).items.map(\.id) == [f.ids[2]])
        #expect(try await f.graph.count(base.where(.tag("active") || .property("name", .equal, .string("Bob")))) .value == 3)
        #expect(try await f.graph.count(base.where(.exists("nick"))).value == 2)
        #expect(try await f.graph.count(base.where(.property("nick", .beginsWith, .string("C")))).value == 1)
        #expect(try await f.graph.count(base.where(.property("nick", .equal, .null))).value == 1)
        #expect(try await f.graph.count(base.where(.property("nick", .notEqual, .null))).value == 1)
        #expect(try await f.graph.query(base.where(!.exists("nick"))).items.map(\.id) == [f.ids[1]])
        #expect(try await f.graph.count(base.where(.property("name", .equal, .string("alice")))).value == 0)
        #expect(try await f.graph.count(base.where(.property("name", .contains, .string("*")))).value == 0)
        #expect(try await f.graph.count(base).value == 3)
        try await f.close()
    }

    @Test func relatedEntitiesActionsAndCyclesRemainGraphScopedAndBounded() async throws {
        let f = try await fixture(), base = GraphQuery<QueryPerson>(budget: try budget())
        let incoming = base.where(.related(.incoming(QueryEdge.graphType), matching: .id(f.ids[0])))
        #expect(try await f.graph.query(incoming).items.map(\.id) == [f.ids[1]])
        let twoHops = base.where(.related(.outgoing(QueryEdge.graphType), matching: .related(.outgoing(QueryEdge.graphType), matching: .id(f.ids[0]))))
        #expect(try await f.graph.query(twoHops).items.map(\.id) == [f.ids[0]])
        #expect(try await f.graph.count(base.where(.related(.actionObjects(QueryAction.graphType), matching: .id(f.ids[2])))).value == 2)
        #expect(try await f.graph.query(base.where(.related(.actionSubjects(nil), matching: .tag("active")))).items.map(\.id) == [f.ids[2]])
        let edges = GraphQuery<QueryEdge>(budget: try budget()).where(.subject(f.ids[0]))
        #expect(try await f.graph.count(edges).value == 1)
        await #expect(throws: GraphQueryError.self) { try await f.graph.query(GraphQuery<QueryEdge>(budget: self.budget()).where(.related(.outgoing(nil), matching: .all))) }
        let foreign = GraphNodeID(graphID: f.other.id, rawValue: f.ids[0].rawValue)
        await #expect(throws: GraphQueryError.self) { try await f.graph.count(base.where(.related(.outgoing(nil), matching: .id(foreign)))) }
        try await f.close()
    }

    @Test func breadthFirstTraversalDeduplicatesCyclesAndExcludesOrigins() async throws {
        let f = try await fixture()
        let traversal = try GraphTraversal(from: [f.ids[0]], via: .outgoing(QueryEdge.graphType), maximumDepth: 10, budget: budget())
        let result = try await f.graph.traverse(traversal)
        #expect(result.visits.map(\.id) == [f.ids[1]])
        #expect(result.visits.map(\.depth) == [1])
        let reverse = try GraphTraversal(from: [f.ids[2]], via: .actionSubjects(QueryAction.graphType), maximumDepth: 2, budget: budget())
        #expect(try await f.graph.traverse(reverse).visits.map(\.id) == [f.ids[0],f.ids[1]])
        let empty = try GraphTraversal(from: [f.ids[0]], via: .outgoing(nil), maximumDepth: 0, budget: budget())
        #expect(try await f.graph.traverse(empty).visits.isEmpty)
        let bad = try GraphTraversal(from: [f.ids[3]], via: .outgoing(nil), maximumDepth: 1, budget: budget())
        await #expect(throws: GraphQueryError.self) { try await f.graph.traverse(bad) }
        try await f.close()
    }

    @Test func keysetPagesHandleTiesDeletedAnchorAndMovingCurrentStateWithoutOffsetFallback() async throws {
        let f = try await fixture()
        let base = GraphQuery<QueryPerson>(budget: try budget()).sorted(by: [GraphQuerySort(.property("rank"))]).limit(1)
        let first = try await f.graph.query(base)
        #expect(first.items.map(\.id) == [f.ids[0]])
        let cursor = try #require(first.nextCursor)
        try await f.graph.delete(f.ids[0])
        let before = f.graph.makeNodeID()
        try await f.graph.transaction { try $0.insert(GraphRecord(id: before, type: QueryPerson.graphType, properties: ["name": .string("Before"), "rank": .integer(0)])) }
        let next = try await f.graph.query(base.after(cursor))
        #expect(next.items.map(\.id) == [f.ids[1]])
        #expect(first.view.scopeID != next.view.scopeID)
        #expect(try await f.graph.query(base.limit(10)).items.map(\.id) == [before,f.ids[1],f.ids[2]])
        await #expect(throws: GraphQueryError.self) { try await f.other.query(base.after(cursor)) }
        await #expect(throws: GraphQueryError.self) { try await f.graph.query(base.where(.tag("active")).after(cursor)) }
        await #expect(throws: GraphQueryError.self) { try await f.graph.count(base.after(cursor)) }
        try await f.close()
    }

    @Test func projectionCountAggregationAndTransactionViewsDoNotRequireApplicationDecoding() async throws {
        let f = try await fixture(), base = GraphQuery<QueryPerson>(budget: try budget())
        let missingName = f.graph.makeNodeID()
        try await f.graph.transaction { try $0.insert(GraphRecord(id: missingName, type: QueryPerson.graphType, properties: ["rank": .integer(5)])) }
        #expect(try await f.graph.count(base.limit(1)).value == 4)
        #expect(try await f.graph.aggregate(base, .sum("rank")).value == .integer(9))
        #expect(try await f.graph.aggregate(base, .minimum("name")).value == .string("Alice"))
        let projection = try await f.graph.project(base.limit(10), properties: ["rank", "absent"])
        #expect(projection.rows.count == 4)
        #expect(projection.rows.allSatisfy { $0.values.keys.allSatisfy { $0 == "rank" } })
        await #expect(throws: GraphModelError.self) { try await f.graph.query(base) }
        #expect(try await f.graph.query(base.where(.exists("name"))).items.count == 3)
        try await f.graph.transaction { scope in
            let id = f.graph.makeNodeID()
            try scope.insert(GraphRecord(id: id, type: QueryPerson.graphType, properties: ["name": .string("Pending")]))
            let count = try scope.count(base), result = try scope.project(base, properties: [])
            #expect(count.value == 5 && count.view.includesPendingChanges)
            #expect(count.view == result.view)
        }
        try await f.close()
    }

    @Test func budgetsRejectBeforePartialResultsAndUnsupportedOperandsNeverStartTheInventory() async throws {
        let f = try await fixture()
        for budget in [try budget(1), try budget(bytes: 0), try budget(steps: 1)] {
            await #expect(throws: GraphQueryError.self) { try await f.graph.query(GraphQuery<QueryPerson>(budget: budget)) }
        }
        let unsupported = GraphQuery<QueryPerson>(budget: try budget(1)).where(.property("blob", .equal, .data(Data())))
        await #expect { try await f.graph.query(unsupported) } throws: { error in
            if case GraphQueryError.unsupportedValue = error { return true }; return false
        }
        let foreign = GraphNodeID(graphID: f.other.id)
        await #expect { try await f.graph.query(GraphQuery<QueryPerson>(budget: self.budget(1)).where(.id(foreign))) } throws: { error in
            if case GraphQueryError.foreignGraph = error { return true }; return false
        }
        try await f.graph.close()
        await #expect { try await f.graph.query(GraphQuery<QueryPerson>(budget: self.budget())) } throws: { error in
            if case GraphStoreError.closed = error { return true }; return false
        }
        try await f.other.close(); try await f.db.close()
    }

    @Test func sqliteReopenAndExactCandidateBoundaryPreserveOrderingAndMissingPlacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GraphQuery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Graph.sqlite")
        let graph = try await GraphStore.open(at: url)
        let ids = (1...3).map { GraphNodeID(graphID: graph.id, rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!) }
        try await graph.transaction { scope in
            for index in 0..<3 {
                var values: [String: GraphValue] = ["name": .string("P\(index)")]
                if index == 0 { values["rank"] = .integer(1) }
                if index == 1 { values["rank"] = .null }
                try scope.insert(GraphRecord(id: ids[index], type: QueryPerson.graphType, properties: values))
            }
        }
        try await graph.close()
        let reopened = try await GraphStore.open(at: url)
        let base = GraphQuery<QueryPerson>(budget: try budget()).sorted(by: [GraphQuerySort(.property("rank"), direction: .descending, missing: .first)])
        let result = try await reopened.query(base)
        #expect(result.items.map(\.id) == [ids[1],ids[2],ids[0]])
        let exact = GraphQuery<QueryPerson>(budget: try budget(result.diagnostics.nativeCandidates))
        #expect(try await reopened.count(exact).value == 3)
        await #expect(throws: GraphQueryError.self) {
            try await reopened.count(GraphQuery<QueryPerson>(budget: self.budget(result.diagnostics.nativeCandidates - 1)))
        }
        try await reopened.close()
    }

    @Test func numericOverflowAndHeterogeneousOrderingFailWithoutLossyConversions() async throws {
        let graph = try await GraphStore.inMemory(), base = GraphQuery<QueryPerson>(budget: try budget())
        let a = graph.makeNodeID(), b = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: QueryPerson.graphType, properties: ["name": .string("A"), "rank": .integer(Int64.max)]))
            try scope.insert(GraphRecord(id: b, type: QueryPerson.graphType, properties: ["name": .string("B"), "rank": .integer(1)]))
        }
        #expect(try await graph.query(base.where(.property("rank", .greaterThan, .integer(Int64.max - 1)))).items.map(\.id) == [a])
        await #expect { try await graph.aggregate(base, .sum("rank")) } throws: { error in
            if case GraphQueryError.arithmeticOverflow = error { return true }; return false
        }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: b, properties: ["rank": .set(.unsignedInteger(1))])) }
        await #expect(throws: GraphQueryError.self) { try await graph.query(base.sorted(by: [GraphQuerySort(.property("rank"))])) }
        await #expect(throws: GraphQueryError.self) { try await graph.query(base.where(.property("rank", .equal, .floatingPoint(.nan)))) }
        try await graph.close()
    }
}
