import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime
@testable import GraphEvoStore

private struct DescriptorItem: GraphModel {
    static let graphType = "Descriptor.Item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) { record = graphRecord }
    func graphRecord(in graphID: GraphID) -> GraphRecord { record }
}
private struct CanonicalDescriptorItem: GraphModel {
    static let graphType = "Café"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) { record = graphRecord }
    func graphRecord(in graphID: GraphID) -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct GraphDescriptorQueryTests {
    private struct Fixture {
        let root: URL, graph: GraphStore, manager: GraphContextManager
        func close() async throws { try await graph.close(); try FileManager.default.removeItem(at: root) }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DescriptorQuery-" + UUID().uuidString)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        return Fixture(root: root, graph: graph, manager: manager)
    }
    private func query(_ candidates: Int = 1_000, steps: Int = 100_000) throws -> GraphQuery<DescriptorItem> {
        GraphQuery(budget: try GraphQueryBudget(maximumCandidates: candidates, maximumSteps: steps))
    }

    @Test func scalarCountDoesNotBuildApplicationFacadesOrIndexUnrequestedBodies() async throws {
        let f = try await fixture()
        let records = try (0..<100).map { index in
            var values: [String: GraphValue] = ["rank": .integer(Int64(index)), "body": .data(Data(repeating: 9, count: 4_096))]
            for field in 0..<20 { values["extra\(field)"] = .array([.string("serialized")]) }
            return try GraphRecord(id: f.graph.makeNodeID(), type: DescriptorItem.graphType, properties: values)
        }
        try await f.graph.transaction { scope in
            for record in records { try scope.insert(record) }
            try scope.insert(GraphRecord(id: f.graph.makeNodeID(), type: "Unrelated", properties: ["body": .data(Data(repeating: 1, count: 64_000))]))
        }
        let q = try query(103, steps: 1_200).where(.property("rank", .greaterThanOrEqual, .integer(50)))
        try await f.graph.read { scope in
            let result = try scope.count(q)
            #expect(result.value == 50 && result.diagnostics.scopedNodes == 100)
            #expect(result.diagnostics.nativeCandidates == 103 && result.diagnostics.materializedRecords == 0)
            try scope.withContext { context, _ in
                let application = context.registeredObjects.filter {
                    $0.entity.name == ModelIdentifier.entityName && $0.value(forKey: "type") as? String == DescriptorItem.graphType
                }
                #expect(application.isEmpty)
                #expect(!context.registeredObjects.contains {
                    $0.entity.name == ModelIdentifier.entityPropertyName && $0.value(forKey: "name") as? String == "body"
                })
            }
        }
        try await f.graph.read { scope in
            let result = try scope.project(q.limit(1), properties: ["rank"])
            #expect(result.rows.count == 1)
            try scope.withContext { context, _ in
                #expect(!context.registeredObjects.contains {
                    $0.entity.name == ModelIdentifier.entityPropertyName && $0.value(forKey: "name") as? String == "body"
                })
            }
        }
        try await f.close()
    }

    @Test func unrelatedRoutingDamageBelongsToExplicitAuditAndStillCountsAgainstAllowance() async throws {
        let f = try await fixture(), selected = f.graph.makeNodeID(), damaged = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: selected, type: DescriptorItem.graphType))
            try $0.insert(GraphRecord(id: damaged, type: "Unrelated"))
        }
        try await f.graph.nativeOperation { container in
            try container.testNativeContext { context in
                let fetch = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityName)
                fetch.predicate = NSPredicate(format: "type == %@", "Unrelated")
                let row = try #require(context.fetch(fetch).first)
                row.setValue(nil, forKey: GraphNativeIdentityColumns.nodeAttribute); try context.save()
            }
        }
        #expect(try await f.graph.count(query(4)).value == 1)
        #expect(try await f.graph.query(query(4)).items.map(\.id) == [selected])
        await #expect(throws: GraphQueryError.budgetExceeded(.candidates)) { try await f.graph.count(self.query(3)) }
        await #expect(throws: (any Error).self) { try await f.graph.validateIntegrity() }
        try await f.close()
    }

    @Test func losingConsultedScalarCannotHideCorruptionAndEarlierIdentityFilterLimitsConsultation() async throws {
        let f = try await fixture(), first = f.graph.makeNodeID(), second = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: DescriptorItem.graphType, properties: ["rank": .integer(1)]))
            try $0.insert(GraphRecord(id: second, type: DescriptorItem.graphType, properties: ["rank": .integer(2)]))
        }
        try await f.graph.nativeOperation { container in
            try container.testNativeContext { context in
                let fetch = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
                fetch.predicate = NSPredicate(format: "name == %@ AND ge2Int64 == 1", "rank")
                let row = try #require(context.fetch(fetch).first)
                row.setValue(true, forKey: "ge2Bool"); try context.save()
            }
        }
        let rank = GraphQueryPredicate.property("rank", .greaterThanOrEqual, .integer(2))
        await #expect { try await f.graph.count(self.query().where(rank)) } throws: { error in
            if case GraphStoreError.corruptIdentity = error { return true }; return false
        }
        #expect(try await f.graph.count(query().where(.id(second) && rank)).value == 1)
        await #expect { try await f.graph.count(self.query().where(rank && .id(second))) } throws: { error in
            if case GraphStoreError.corruptIdentity = error { return true }; return false
        }
        try await f.close()
    }

    @Test func sparseTopologyFitsDefaultBudgetAndTracksPendingLinks() async throws {
        let f = try await fixture()
        let ids = (0..<600).map { _ in f.graph.makeNodeID() }
        let first = ids[0], second = ids[1], third = ids[2]
        let edge = f.graph.makeNodeID(), reverse = f.graph.makeNodeID(), action = f.graph.makeNodeID()
        let graphID = f.graph.id
        try await f.graph.transaction { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                for id in ids {
                    try session.insert(GraphRecord(id: id, type: DescriptorItem.graphType, tags: id == second ? ["ready"] : []))
                }
                try session.insert(GraphRecord(id: edge, type: "link", endpoints: .relationship(subject: first, object: second)))
                try session.insert(GraphRecord(id: reverse, type: "link", endpoints: .relationship(subject: second, object: first)))
                try session.insert(GraphRecord(id: action, type: "batch", endpoints: .action(subjects: [first, third], objects: [second])))
            }
        }
        let descriptor = try query()
        let outgoing = descriptor.where(.related(.outgoing("link"), matching: .tag("ready")))
        let result = try await f.graph.query(outgoing)
        #expect(result.items.map(\.id) == [first])
        #expect(result.diagnostics.evaluationSteps < 100_000)
        #expect(try await f.graph.query(descriptor.where(.related(.incoming("link"), matching: .tag("ready")))).items.map(\.id) == [first])
        let subjects = try await f.graph.query(descriptor.where(.related(.actionObjects("batch"), matching: .tag("ready"))))
        #expect(Set(subjects.items.map(\.id)) == [first, third])
        #expect(try await f.graph.query(descriptor.where(.related(.actionSubjects("batch"), matching: .id(third)))).items.map(\.id) == [second])
        let traversal = try GraphTraversal(from: [first], via: .outgoing("link"), maximumDepth: 4,
            budget: descriptor.budget)
        #expect(try await f.graph.traverse(traversal).visits.map(\.id) == [second])
        let limited = try query(1_000, steps: 100).where(.related(.outgoing("link"), matching: .tag("ready")))
        await #expect(throws: GraphQueryError.budgetExceeded(.steps)) { try await f.graph.query(limited) }

        try await f.graph.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: edge, endpoints: .relationship(subject: third, object: second)))
            #expect(try scope.query(outgoing).items.map(\.id) == [third])
        }
        #expect(try await f.graph.query(outgoing).items.map(\.id) == [third])
        try await f.close()
    }

    @Test func topologyUsesOnlyDescriptorEdgeKindsAndTypes() async throws {
        let f = try await fixture(), a = f.graph.makeNodeID(), b = f.graph.makeNodeID()
        try await f.graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: DescriptorItem.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(GraphRecord(id: b, type: DescriptorItem.graphType, properties: ["rank": .integer(2)]))
            try scope.insert(GraphRecord(id: f.graph.makeNodeID(), type: "Friend", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: f.graph.makeNodeID(), type: "OtherEdge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: f.graph.makeNodeID(), type: "OtherAction", endpoints: .action(subjects: [a], objects: [b])))
        }
        try await f.graph.nativeOperation { container in
            try container.testNativeContext { context in
                for name in [ModelIdentifier.relationshipPropertyName, ModelIdentifier.actionPropertyName] {
                    let fetch = NSFetchRequest<NSManagedObject>(entityName: name)
                    fetch.predicate = NSPredicate(format: "name == %@ AND node.type IN %@", GraphTypedStoreAdapter.formatsKey, ["OtherEdge", "OtherAction"])
                    for row in try context.fetch(fetch) { row.setValue("invalid", forKey: "object") }
                }
                try context.save()
            }
        }
        let q = try query().where(.related(.outgoing("Friend"), matching: .property("rank", .equal, .integer(2))))
        #expect(try await f.graph.query(q).items.map(\.id) == [a])
        let traversal = try GraphTraversal(from: [a], via: .outgoing("Friend"), maximumDepth: 3,
            budget: GraphQueryBudget(maximumCandidates: 10))
        #expect(try await f.graph.traverse(traversal).visits.map(\.id) == [b])
        await #expect(throws: (any Error).self) { try await f.graph.validateIntegrity() }
        try await f.close()
    }

    @Test func traversalValidatesItsOriginEvenWithoutAnEdgeOrReturnedVisit() async throws {
        let f = try await fixture(), id = f.graph.makeNodeID()
        try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: DescriptorItem.graphType)) }
        try await f.graph.nativeOperation { container in
            try container.testNativeContext { context in
                let fetch = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
                fetch.predicate = NSPredicate(format: "name == %@ AND node.ge2NodeID == %@", GraphTypedStoreAdapter.formatsKey, id.rawValue.uuidString)
                let row = try #require(context.fetch(fetch).first)
                row.setValue("invalid", forKey: "object"); try context.save()
            }
        }
        #expect(try await f.graph.count(query()).value == 1)
        let traversal = try GraphTraversal(from: [id], via: .outgoing("Absent"), maximumDepth: 0,
            budget: GraphQueryBudget(maximumCandidates: 10))
        await #expect(throws: (any Error).self) { try await f.graph.traverse(traversal) }
        try await f.close()
    }

    @Test func pendingMemoryRowsAndCanonicalTypeSpellingsRetainTheResourceCandidateBoundary() async throws {
        let database = try await GraphDatabase.open(configuration: .init(location: .inMemory(UUID())),
            schema: GraphRuntimeSchema.typedProperties, adapter: GraphNativeIdentityDatabaseAdapter.database)
        let graph = try await database.createGraph(), other = try await database.createGraph()
        let id = graph.makeNodeID()
        try await other.transaction { try $0.insert(GraphRecord(id: other.makeNodeID(), type: "Unrelated")) }
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: id, type: "Cafe\u{301}", properties: ["rank": .integer(1)]))
            let q = GraphQuery<CanonicalDescriptorItem>(budget: try GraphQueryBudget(maximumCandidates: 6))
            #expect(try scope.count(q).value == 1)
            #expect(try scope.query(q).items.map(\.id) == [id])
            #expect(throws: GraphQueryError.budgetExceeded(.candidates)) {
                try scope.count(GraphQuery<CanonicalDescriptorItem>(budget: GraphQueryBudget(maximumCandidates: 5)))
            }
        }
        #expect(try await graph.count(GraphQuery<CanonicalDescriptorItem>(budget: GraphQueryBudget(maximumCandidates: 6))).value == 1)
        try await graph.close(); try await other.close()
        let native = try await fixture(), nativeID = native.graph.makeNodeID()
        try await native.graph.transaction {
            try $0.insert(GraphRecord(id: nativeID, type: "Cafe\u{301}", properties: ["rank": .integer(1)]))
        }
        let canonical = GraphQuery<CanonicalDescriptorItem>(budget: try GraphQueryBudget(maximumCandidates: 3))
        #expect(try await native.graph.count(canonical).value == 1)
        #expect(try await native.graph.query(canonical).items.map(\.id) == [nativeID])
        try await native.close()
    }
}
