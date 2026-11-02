import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime
@testable import GraphEvoStore

private struct TypedQueryItem: GraphModel {
    static let graphType = "TypedQuery.Item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct GraphTypedQueryTests {
    private struct Fixture {
        let root: URL, graph: GraphStore
        let manager: GraphContextManager
        func close() async throws { try await graph.close(); try FileManager.default.removeItem(at: root) }
    }
    private func fixture(schema: StoreSchema = GraphRuntimeSchema.typedProperties, id: GraphID = GraphID()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypedQuery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: schema, adapter: GraphCoordinatorFactory.adapter)
        return try await Fixture(root: root, graph: manager.createGraph(id: id, at: root.appendingPathComponent("Store.sqlite")), manager: manager)
    }
    private func query(bytes: Int = 1024 * 1024, steps: Int = 100_000) throws -> GraphQuery<TypedQueryItem> {
        GraphQuery(budget: try GraphQueryBudget(maximumCandidates: 1_000, maximumPropertyBytes: bytes, maximumSteps: steps))
    }
    @Test func nativeScalarsAndResidualsMatchTheS03Evaluator() async throws {
        let id = GraphID(), native = try await fixture(id: id), old = try await fixture(schema: GraphRuntimeSchema.nativeIdentity, id: id)
        let ids = (0..<8).map { _ in GraphNodeID(graphID: id) }
        let uuid = UUID(), date = Date(timeIntervalSince1970: 1234.5)
        let records = try ids.enumerated().map { index, id in
            var values: [String: GraphValue] = ["i": .integer(Int64(index)), "u": .unsignedInteger(UInt64.max - UInt64(index)),
                "d": .floatingPoint(Double(index) / 2), "b": .boolean(index % 2 == 0), "s": .string("a*\(index)"),
                "date": .date(date), "uuid": .uuid(uuid), "nul\u{0}key": .boolean(true),
                "decimal": .decimal(Decimal(index)), "negativeZero": .floatingPoint(-0.0),
                "unicode": .string(index == 0 ? "é" : "e\u{301}"), "array": .array([.integer(1)])]
            values[index % 2 == 0 ? "é" : "e\u{301}"] = .integer(9)
            if index % 3 != 0 { values["nullable"] = index % 2 == 0 ? .null : .integer(1) }
            return try GraphRecord(id: id, type: TypedQueryItem.graphType, properties: values, tags: index % 2 == 0 ? ["even"] : [])
        }
        for f in [native, old] { try await f.graph.transaction { scope in for record in records { try scope.insert(record) } } }
        let predicates: [GraphQueryPredicate] = [
            .exists("nullable"), .property("nullable", .equal, .null), .property("nullable", .notEqual, .null),
            .property("i", .greaterThanOrEqual, .integer(4)), .property("u", .greaterThan, .unsignedInteger(.max - 3)),
            .property("d", .lessThan, .floatingPoint(1.5)), .property("b", .equal, .boolean(true)),
            .property("s", .contains, .string("*")), .property("uuid", .equal, .uuid(uuid)),
            .property("date", .equal, .date(date)),
            .property("decimal", .greaterThan, .decimal(3)), .property("negativeZero", .equal, .floatingPoint(0)),
            .property("unicode", .equal, .string("é")), .tag("even") || .property("i", .equal, .integer(1)),
            !.property("b", .equal, .boolean(true)), .property("i", .greaterThan, .integer(2)) && .tag("even")]
        for predicate in predicates {
            let q = try query().where(predicate)
            #expect(try await native.graph.count(q).value == old.graph.count(q).value)
            let a = try await native.graph.project(q, properties: ["i", "nullable"])
            let b = try await old.graph.project(q, properties: ["i", "nullable"])
            #expect(a.rows.map(\.id) == b.rows.map(\.id)); #expect(a.rows.map(\.values) == b.rows.map(\.values))
        }
        for aggregate in [GraphQueryAggregate.sum("i"), .minimum("decimal"), .maximum("date")] {
            let first = try await native.graph.aggregate(query(), aggregate)
            let second = try await old.graph.aggregate(query(), aggregate)
            #expect(first.value == second.value && first.contributingCount == second.contributingCount)
        }
        #expect(try await native.graph.count(query().where(.property("é", .equal, .integer(9)))).value == 8)
        #expect(try await native.graph.count(query().where(.exists("nul\u{0}key"))).value == 8)
        let result = try await native.graph.query(query().where(.property("i", .equal, .integer(4))))
        #expect(result.diagnostics.strategy == .hybrid && result.diagnostics.nativePredicateCount == 1)
        #expect(result.diagnostics.nativeFetchCount > 0 && result.diagnostics.materializedRecords == 1)
        #expect(try query().where(.property("i", .equal, .integer(1))).explain().eligiblePredicatePrefixCount == 1)
        #expect(try await native.graph.count(query().where(.property("unicode", .equal, .string("é")))).diagnostics.fallbackReasons.contains(.nonASCIIString))
        try await native.close(); try await old.close()
    }
    @Test func sourceOrderDoesNotHideErrorsAndTransactionsSeePendingValues() async throws {
        let f = try await fixture(), first = f.graph.makeNodeID(), second = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: TypedQueryItem.graphType, properties: ["bad": .array([.integer(1)]), "i": .integer(1)]))
            try $0.insert(GraphRecord(id: second, type: TypedQueryItem.graphType, properties: ["bad": .integer(2), "i": .integer(2)]))
        }
        let bad = GraphQueryPredicate.property("bad", .greaterThan, .integer(0))
        await #expect(throws: GraphQueryError.unsupportedValue) { try await f.graph.count(self.query().where(bad && .id(second))) }
        #expect(try await f.graph.count(query().where(.id(second) && bad)).value == 1)
        try await f.graph.transaction { scope in
            _ = try scope.patch(.init(id: first, properties: ["i": .set(.integer(9))]))
            let result = try scope.count(self.query().where(.property("i", .equal, .integer(9))))
            #expect(result.value == 1 && result.diagnostics.fallbackReasons.contains(.pendingChanges))
        }
        let q = try query().where(.property("i", .greaterThan, .integer(0)))
        try await f.graph.transaction { _ = try $0.patch(.init(id: first, properties: ["i": .set(.unsignedInteger(1))])) }
        await #expect(throws: GraphQueryError.incomparableValues) { try await f.graph.count(q) }
        try await f.close()
    }
    @Test func nativeSortMergesChunksBeforePagingAndKeepsUUIDTies() async throws {
        let f = try await fixture()
        let records = try (0..<300).map { index in
            try GraphRecord(id: GraphNodeID(graphID: f.graph.id), type: TypedQueryItem.graphType,
                properties: ["rank": .integer(Int64(index % 7)), "payload": .data(Data(repeating: 9, count: 4_096))])
        }
        try await f.graph.transaction { scope in for record in records { try scope.insert(record) } }
        let expected = records.sorted {
            let first = $0.properties["rank"]!, second = $1.properties["rank"]!
            if first == second { return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            if case .integer(let a) = first, case .integer(let b) = second { return a > b }; return false
        }.map(\.id)
        let q = try query(bytes: 100_000).sorted(by: [.init(.property("rank"), direction: .descending)]).limit(13)
        var cursor: GraphQueryCursor?, actual: [GraphNodeID] = []
        repeat {
            let result = try await f.graph.query(cursor.map { q.after($0) } ?? q)
            #expect(result.diagnostics.nativeSortApplied && result.diagnostics.materializedRecords <= 13)
            actual += result.items.map(\.id); cursor = result.nextCursor
        } while cursor != nil
        #expect(actual == expected)
        await #expect(throws: GraphQueryError.self) { try await f.graph.query(self.query(bytes: 1)) }
        await #expect(throws: GraphQueryError.self) { try await f.graph.query(self.query(steps: 5)) }
        try await f.close()
    }
    @Test func discardedBodiesAreNotMaterializedButReturnedCorruptionIsVisible() async throws {
        let f = try await fixture(), first = f.graph.makeNodeID(), second = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: TypedQueryItem.graphType, properties: ["i": .integer(1), "body": .data(Data([1]))]))
            try $0.insert(GraphRecord(id: second, type: TypedQueryItem.graphType, properties: ["i": .integer(2), "body": .array([.integer(1)])]))
        }
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let fetch = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
                fetch.predicate = NSPredicate(format: "name == %@ AND ge2ValueEncoding == 1", "body")
                let row = try #require(context.fetch(fetch).first)
                row.setValue(Data([0, 255]), forKey: "ge2Bytes"); try context.save()
            }
        }
        #expect(try await f.graph.query(query(bytes: 1_024).where(.property("i", .equal, .integer(1)))).items.map(\.id) == [first])
        #expect(try await f.graph.count(query().where(.exists("body"))).value == 2)
        await #expect(throws: (any Error).self) { try await f.graph.query(self.query().where(.id(second))) }
        await #expect(throws: (any Error).self) { try await f.graph.validateIntegrity() }
        try await f.close()
    }
    @Test func inMemoryAndRelatedTraversalUseScopedLazyReaders() async throws {
        let db = try await GraphDatabase.open(configuration: .init(location: .inMemory(UUID())),
            schema: GraphRuntimeSchema.typedProperties, adapter: GraphNativeIdentityDatabaseAdapter.database)
        let graph = try await db.createGraph(), a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID()
        try await graph.transaction {
            try $0.insert(GraphRecord(id: a, type: TypedQueryItem.graphType, properties: ["i": .integer(1)]))
            try $0.insert(GraphRecord(id: b, type: TypedQueryItem.graphType, properties: ["i": .integer(2)]))
            try $0.insert(GraphRecord(id: edge, type: "TypedQuery.Edge", endpoints: .relationship(subject: a, object: b)))
        }
        let q = try query().where(.related(.outgoing(nil), matching: .property("i", .equal, .integer(2))))
        let result = try await graph.query(q)
        #expect(result.items.map(\.id) == [a] && result.diagnostics.fallbackReasons.contains(.inMemory))
        let traversal = try GraphTraversal(from: [a], via: .outgoing(nil), maximumDepth: 5,
            budget: GraphQueryBudget(maximumCandidates: 10))
        #expect(try await graph.traverse(traversal).visits.map(\.id) == [b])
        try await graph.close(); try await db.close()
        let f = try await fixture(), first = f.graph.makeNodeID(), second = f.graph.makeNodeID(), relationship = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: TypedQueryItem.graphType, properties: ["i": .integer(1)]))
            try $0.insert(GraphRecord(id: second, type: TypedQueryItem.graphType, properties: ["i": .integer(2)]))
            try $0.insert(GraphRecord(id: relationship, type: "TypedQuery.Edge", endpoints: .relationship(subject: first, object: second)))
        }
        #expect(try await f.graph.query(q).items.map(\.id) == [first])
        let count = try await f.graph.count(query().where(.property("i", .greaterThan, .integer(0))))
        #expect(count.value == 2 && count.diagnostics.strategy == .native && count.diagnostics.materializedRecords == 0)
        try await f.close()
    }

    @Test func headerOnlySnapshotsDoNotRegisterApplicationPropertyObjects() async throws {
        let f = try await fixture()
        let records = try (0..<3).map { _ in
            try GraphRecord(id: f.graph.makeNodeID(), type: TypedQueryItem.graphType,
                properties: ["i": .integer(1), "body": .data(Data(repeating: 91, count: 1024 * 1024))])
        }
        try await f.graph.transaction { scope in for record in records { try scope.insert(record) } }
        try await f.graph.read { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, f.graph.id, database: true)
                func registeredValues() -> Int {
                    context.registeredObjects.filter {
                        $0.entity.attributesByName[GraphNativePropertyStorage.kindKey] != nil &&
                        $0.value(forKey: GraphNativePropertyStorage.kindKey) != nil
                    }.count
                }
                #expect(registeredValues() == 0)
                for (id, node) in session.nodes { _ = try session.snapshot(node, id: id, propertyKeys: []) }
                #expect(registeredValues() == 0)
            }
        }
        try await f.close()
    }

    @Test func aggregatesResolveLazyValuesAndPreserveOverflowAndCategoryErrors() async throws {
        let f = try await fixture(), a = f.graph.makeNodeID(), b = f.graph.makeNodeID(), c = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: a, type: TypedQueryItem.graphType, properties: ["i": .integer(1), "text": .string("Zulu"), "d": .decimal(3)]))
            try $0.insert(GraphRecord(id: b, type: TypedQueryItem.graphType, properties: ["i": .integer(2), "text": .string("Alpha"), "d": .decimal(2)]))
            try $0.insert(GraphRecord(id: c, type: TypedQueryItem.graphType, properties: ["i": .null]))
        }
        let q = try query()
        let sum = try await f.graph.aggregate(q, .sum("i"))
        #expect(sum.value == .integer(3) && sum.contributingCount == 2 && sum.diagnostics.materializedRecords == 0)
        #expect(try await f.graph.aggregate(q, .minimum("text")).value == .string("Alpha"))
        #expect(try await f.graph.aggregate(q, .maximum("d")).value == .decimal(3))
        #expect(try await f.graph.aggregate(q.where(.property("i", .equal, .integer(2))), .sum("i")).value == .integer(2))
        #expect(try await f.graph.aggregate(q.sorted(by: [.init(.property("text"))]), .sum("i")).value == .integer(3))
        try await f.graph.transaction { _ = try $0.patch(.init(id: a, properties: ["i": .set(.integer(.max))])) }
        await #expect(throws: GraphQueryError.arithmeticOverflow) { try await f.graph.aggregate(q, .sum("i")) }
        try await f.graph.transaction { _ = try $0.patch(.init(id: a, properties: ["i": .set(.unsignedInteger(1))])) }
        await #expect(throws: GraphQueryError.unsupportedComparison) { try await f.graph.aggregate(q, .sum("i")) }
        await #expect(throws: GraphQueryError.incomparableValues) { try await f.graph.aggregate(q, .minimum("i")) }
        try await f.close()
    }

}
