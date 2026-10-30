import CoreData
import Foundation
import Testing
import os
@testable import GraphEvo
import GraphEvoModel

@Suite struct GraphQueryMaterializationTests {
    private struct Item: GraphModel {
        static let graphType = "matrix.item"
        static let graphKind: GraphNodeKind = .entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) throws { record = graphRecord }
        func graphRecord() throws -> GraphRecord { record }
    }
    private struct Other: GraphModel {
        static let graphType = "matrix.other"
        static let graphKind: GraphNodeKind = .entity
        let id: GraphNodeID
        init(graphRecord: GraphRecord) throws { id = graphRecord.id }
        func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType) }
    }
    private func budget() throws -> GraphQueryBudget { try GraphQueryBudget(maximumCandidates: 100, maximumPropertyBytes: 16 * 1024) }

    @Test func identityGuardsSkipExcludedSameTypeBodiesWithoutChangingInventoryOrReturnedFields() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph(), other = try await database.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), large = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: Item.graphType, properties: ["rank": .integer(2), "extra": .string("complete"), "optional": .null]))
            try scope.insert(GraphRecord(id: b, type: Item.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(GraphRecord(id: large, type: Item.graphType, properties: ["body": .data(Data(repeating: 7, count: 1024 * 1024))]))
        }
        let query = GraphQuery<Item>(budget: try budget()).where(.id(a) || .id(b)).sorted(by: [GraphQuerySort(.property("rank"))]).limit(1)
        let page = try await graph.query(query)
        #expect(page.items.map(\.id) == [b])
        #expect(page.diagnostics.nativeCandidates == 7)
        #expect(page.diagnostics.scopedNodes == 3)
        let cursor = try #require(page.nextCursor)
        let next = try await graph.query(query.after(cursor))
        #expect(next.items.first?.record.properties == ["rank": .integer(2), "extra": .string("complete"), "optional": .null])
        #expect(try await graph.count(query).value == 2)
        #expect(try await graph.project(query, properties: ["optional", "extra"]).rows.first?.id == b)
        #expect(try await graph.aggregate(query, .sum("rank")).value == .integer(3))
        let missing = GraphQuery<Item>(budget: try budget()).where(.id(graph.makeNodeID()))
        #expect(try await graph.query(missing).items.isEmpty)
        await #expect(throws: GraphQueryError.self) { try await graph.query(GraphQuery<Item>(budget: budget())) }
        await #expect(throws: GraphQueryError.self) { try await graph.query(GraphQuery<Item>(budget: budget()).where(.id(large))) }
        let tooSmall = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 6)).where(.id(a))
        await #expect(throws: GraphQueryError.self) { try await graph.query(tooSmall) }
        try await graph.close(); try await other.close(); try await database.close()
    }

    @Test func propertyBeforeIdentityAndRelatedDependenciesRemainConservative() async throws {
        let graph = try await GraphStore.inMemory(), a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: Item.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(GraphRecord(id: b, type: Item.graphType, properties: ["rank": .string("incomparable"), "body": .data(Data(repeating: 1, count: 1024 * 1024))]))
            try scope.insert(GraphRecord(id: edge, type: "matrix.edge", endpoints: .relationship(subject: a, object: b)))
        }
        let base = GraphQuery<Item>(budget: try budget())
        #expect(try await graph.count(base.where(.id(a)).where(.property("rank", .greaterThan, .integer(0)))).value == 1)
        await #expect(throws: GraphQueryError.self) { try await graph.count(base.where(.property("rank", .greaterThan, .integer(0))).where(.id(a))) }
        await #expect(throws: GraphQueryError.self) { try await graph.query(base.where(.id(a) || .tag("unbounded"))) }
        await #expect(throws: GraphQueryError.self) { try await graph.query(base.where(!(.id(b)))) }
        let related = base.where(.id(a)).where(.related(.outgoing("matrix.edge"), matching: .exists("body")))
        await #expect(throws: GraphQueryError.self) { try await graph.count(related) }
        let finite = base.where((.id(a) && .property("rank", .equal, .integer(1))) || (.id(graph.makeNodeID()) && .exists("body")))
        #expect(try await graph.count(finite).value == 1)
        try await graph.close()
    }

    @Test func identityMaterializationSeesPendingEditsAndStillRejectsExcludedRoutingCorruption() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let a = graph.makeNodeID(), excluded = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: excluded, type: Item.graphType, properties: ["body": .data(Data(repeating: 2, count: 1024 * 1024))])) }
        let query = GraphQuery<Item>(budget: try budget()).where(.id(a))
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: Item.graphType, properties: ["rank": .integer(1)]))
            _ = try scope.patch(GraphRecordPatch(id: a, properties: ["rank": .set(.integer(4))]))
            #expect(try scope.query(query).items.first?.record.properties["rank"] == .integer(4))
            #expect(try scope.query(query).view.includesPendingChanges)
            try scope.delete(a)
            #expect(try scope.query(query).items.isEmpty)
        }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[excluded]), execute = try #require(GraphTypedStoreAdapter.database.graph.query)
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = ["body", "body"]
                #expect(throws: GraphStoreError.self) { try execute(context, graph.id, query.request) }
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = ["body"]
                node[dynamicMember: GraphTypedStoreAdapter.idKey] = "invalid"
                #expect(throws: GraphStoreError.self) { try execute(context, graph.id, query.request) }
            }
        }
        try await graph.close(); try await database.close()
    }

    @Test func completeModelsAndExplicitDependenciesStayChargedButUnrelatedBodiesDoNot() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let owner = graph.makeNodeID(), target = graph.makeNodeID(), edge = graph.makeNodeID()
        let payload = try GraphAttachmentPayload(id: target, ownerID: owner, fileName: "file.bin", contentType: "public.data", data: Data(repeating: 173, count: 1024 * 1024))
        let file = try GraphRecordPatch(id: payload.id, properties: ["state": .set(.string("ready"))]).applying(to: payload.graphRecord())
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, properties: ["rank": .integer(7), "optional": .null, "unrequested": .string("must survive full models")]))
            try scope.insert(file)
            try scope.insert(GraphRecord(id: edge, type: "matrix.edge", endpoints: .relationship(subject: owner, object: target)))
        }
        let query = GraphQuery<Item>(budget: try budget()).where(.property("rank", .equal, .integer(7)))
        #expect(try await graph.query(query).items.first?.record.properties["unrequested"] == .string("must survive full models"))
        #expect(try await graph.count(query).value == 1)
        #expect(try await graph.project(query, properties: ["rank", "optional", "missing"]).rows.first?.values == ["rank": .integer(7), "optional": .null])
        #expect(try await graph.aggregate(query, .sum("rank")).value == .integer(7))
        let traversal = try GraphTraversal(from: [owner], via: .outgoing("matrix.edge"), maximumDepth: 1, budget: budget())
        #expect(try await graph.traverse(traversal).visits.map(\.id) == [target])
        let fileQuery = GraphQuery<GraphAttachmentPayload>(budget: try budget())
        #expect(try await graph.count(fileQuery).value == 1)
        await #expect(throws: GraphQueryError.self) { try await graph.query(fileQuery) }
        await #expect(throws: GraphQueryError.self) { try await graph.project(fileQuery, properties: ["content"]) }
        let related = GraphQuery<Item>(budget: try budget()).where(.related(.outgoing("matrix.edge"), matching: .exists("content")))
        await #expect(throws: GraphQueryError.self) { try await graph.count(related) }
        let relatedID = GraphQuery<Item>(budget: try budget()).where(.related(.outgoing("matrix.edge"), matching: .id(target)))
        #expect(try await graph.count(relatedID).value == 1)
        let relatedState = GraphQuery<Item>(budget: try budget()).where(.related(.outgoing("matrix.edge"), matching: .not(.or([.property("state", .equal, .string("absent")), .none]))))
        #expect(try await graph.count(relatedState).value == 1)
        try await graph.close(); try await database.close()
    }

    @Test func unusedCorruptBodiesAreNotCertifiedAndRequestedMissingEncodedValuesStillFail() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let owner = graph.makeNodeID()
        let payload = try GraphAttachmentPayload(id: graph.makeNodeID(), ownerID: owner, fileName: "file.bin", contentType: "public.data", data: Data([1, 2]))
        let file = try payload.graphRecord()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(file)
        }
        let query = GraphQuery<Item>(budget: try budget())
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[payload.id])
                node[dynamicMember: "content"] = Data([0])
                let adapter = GraphTypedStoreAdapter.database.graph
                let execute = try #require(adapter.query)
                #expect(try execute(context, graph.id, query.request).records.map(\.id) == [owner])
                var bodyRequest = GraphQuery<GraphAttachmentPayload>(budget: try GraphQueryBudget(maximumCandidates: 100)).where(.exists("content")).request
                bodyRequest.operation = .count
                #expect(throws: (any Error).self) { try execute(context, graph.id, bodyRequest) }
                #expect(throws: (any Error).self) { try session.record(payload.id) }
                #expect(throws: (any Error).self) { try GraphTypedStoreAdapter.mirroringRoot(context, id: graph.id) }
                let item = try #require(session.nodes[owner])
                item[dynamicMember: "rank"] = nil
                #expect(throws: GraphStoreError.self) { try execute(context, graph.id, query.request) }
                var rankRequest = query.where(.property("rank", .equal, .integer(1))).request
                rankRequest.operation = .count
                #expect(throws: GraphStoreError.self) { try execute(context, graph.id, rankRequest) }
            }
        }
        try await graph.close(); try await database.close()
    }
}


/// Tracks native body transformation, not just the outer value codec.
private final class QueryBodyReadProbe: NSSecureUnarchiveFromDataTransformer, @unchecked Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { reads.withLock { $0 } }
    func reset() { reads.withLock { $0 = 0 } }
    override func transformedValue(_ value: Any?) -> Any? {
        let result = GraphValueTransformer().transformedValue(value)
        if result as? String == "matrix-body-poison" {
            reads.withLock { $0 += 1 }
            GraphValueDecodingDiagnostics.record(NSError(domain: "GraphQueryMaterialization.Poison", code: 1))
            return nil
        }
        return result
    }
    override func reverseTransformedValue(_ value: Any?) -> Any? { GraphValueTransformer().reverseTransformedValue(value) }
}

extension GraphQueryMaterializationTests {
    @Test @MainActor func propertyFetchFiltersNativeRowsBeforeTransformingUnusedBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QueryBodyProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transformer = QueryBodyReadProbe(), name = NSValueTransformerName("QueryBody-\(UUID())")
        ValueTransformer.setValueTransformer(transformer, forName: name)
        defer { ValueTransformer.setValueTransformer(nil, forName: name) }
        let model = Model.makeModel()
        for entity in model.entities {
            entity.attributesByName["object"]?.valueTransformerName = name.rawValue
        }
        let container = NSPersistentContainer(name: "QueryBodyProbe", managedObjectModel: model)
        let coordinator = container.persistentStoreCoordinator
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent("Graph.sqlite"))
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), other = GraphNodeID(graphID: graph)
        try await container.performBackgroundTask { @Sendable context in
            let facade = GraphTypedStoreAdapter.facade(context)
            let root = Entity(GraphTypedStoreAdapter.rootType, graph: facade)
            root[dynamicMember: GraphTypedStoreAdapter.graphKey] = graph.rawValue.uuidString
            root[dynamicMember: GraphTypedStoreAdapter.layoutKey] = GraphTypedStoreAdapter.databaseVersion
            let item = Entity(Item.graphType, graph: facade)
            try GraphTypedStoreAdapter.stamp(item, id: owner)
            item[dynamicMember: "rank"] = try GraphValueCodec.encode(.integer(1))
            item[dynamicMember: GraphTypedStoreAdapter.formatsKey] = ["rank"]
            let body = Entity("matrix.other", graph: facade)
            try GraphTypedStoreAdapter.stamp(body, id: other)
            body[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
            body[dynamicMember: "body"] = "matrix-body-poison"
            let members = Action(GraphTypedStoreAdapter.membersType, graph: facade)
            members[dynamicMember: GraphTypedStoreAdapter.graphKey] = graph.rawValue.uuidString
            members.add(subjects: root).add(objects: item, body)
            try context.save(); context.reset(); transformer.reset()
            let execute = try #require(GraphTypedStoreAdapter.database.graph.query)
            let query = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 100)).where(.property("rank", .equal, .integer(1)))
            #expect(try execute(context, graph, query.request).records.map(\.id) == [owner])
            #expect(transformer.count == 0)
            var requested = GraphQuery<Other>(budget: try GraphQueryBudget(maximumCandidates: 100)).where(.exists("body")).request
            requested.operation = .count
            #expect(throws: (any Error).self) { try execute(context, graph, requested) }
            #expect(transformer.count > 0)
            context.reset()
            #expect(throws: (any Error).self) { try GraphTypedStoreAdapter.Session(context, graph, database: true).record(other) }
            #expect(transformer.count > 0)
            context.reset()
            let session = try GraphTypedStoreAdapter.Session(context, graph, database: true)
            let poisoned = Entity(Item.graphType, graph: session.graph), poisonedID = GraphNodeID(graphID: graph)
            try GraphTypedStoreAdapter.stamp(poisoned, id: poisonedID)
            poisoned[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
            poisoned[dynamicMember: "body"] = "matrix-body-poison"
            session.membership?.add(objects: poisoned)
            try context.save(); context.reset(); transformer.reset()
            let selected = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 100)).where(.id(owner))
            #expect(try execute(context, graph, selected.request).records.map(\.id) == [owner])
            var projection = selected.request; projection.operation = .projection(["rank"])
            #expect(try execute(context, graph, projection).records.first?.properties["rank"] == .integer(1))
            #expect(transformer.count == 0)
            let requestedBody = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 100)).where(.id(poisonedID))
            #expect(throws: (any Error).self) { try execute(context, graph, requestedBody.request) }
            #expect(transformer.count > 0)
            context.reset()
        }
        try coordinator.remove(store)
    }
}
