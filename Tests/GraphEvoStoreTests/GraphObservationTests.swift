import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoRuntime

struct ObservedItem: GraphModel {
    static let graphType = "observe.item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}
struct ObservationTestFailure: Error {}
func observationQuery() throws -> GraphQuery<ObservedItem> {
    GraphQuery(budget: try GraphQueryBudget(maximumCandidates: 256))
}
func waitForObservation(_ observation: GraphObservation<GraphQueryState<ObservedItem>>,
                        matching: @escaping @Sendable (GraphQueryResult<ObservedItem>) -> Bool) async throws -> GraphQueryResult<ObservedItem> {
    for await state in observation {
        switch state {
        case .value(let result): if matching(result) { return result }
        case .failure(let error): throw error
        }
    }
    throw ObservationTestFailure()
}

@Suite(.timeLimit(.minutes(1))) struct GraphObservationTests {
    @Test func relatedMembershipValueAndDeletionRefreshFromOtherHandles() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let writer = try await database.openGraph(graph.id)
        let first = graph.makeNodeID(), second = graph.makeNodeID(), edge = graph.makeNodeID()
        try await writer.transaction { scope in
            try scope.insert(GraphRecord(id: first, type: ObservedItem.graphType, properties: ["name": .string("first")]))
            try scope.insert(GraphRecord(id: second, type: ObservedItem.graphType, properties: ["name": .string("second")]))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: first, object: second)))
        }
        let query = try observationQuery().where(.related(.outgoing("edge"), matching: .tag("selected")))
        let observation = try await graph.observe(query)
        #expect(try await waitForObservation(observation) { $0.items.isEmpty }.items.isEmpty)
        try await writer.transaction { _ = try $0.patch(GraphRecordPatch(id: second, addingTags: ["selected"])) }
        let selected = try await waitForObservation(observation) { $0.items.map(\.id) == [first] }
        try await writer.transaction { _ = try $0.patch(GraphRecordPatch(id: first, properties: ["name": .set(.string("changed"))])) }
        let changed = try await waitForObservation(observation) { $0.items.first?.record.properties["name"] == .string("changed") }
        #expect(selected.view.scopeID != changed.view.scopeID)
        try await writer.delete(second)
        #expect(try await waitForObservation(observation) { $0.items.isEmpty }.items.isEmpty)
        observation.cancel()
        try await writer.close(); try await graph.close(); try await database.close()
    }

    @Test func orderAndActionDependenciesRefreshWithoutEditingTheSelectedNode() async throws {
        let graph = try await GraphStore.inMemory(), first = graph.makeNodeID(), second = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: first, type: ObservedItem.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(GraphRecord(id: second, type: ObservedItem.graphType, properties: ["rank": .integer(2)]))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [first], objects: [second])))
        }
        let ordered = try await graph.observe(observationQuery().sorted(by: [GraphQuerySort(.property("rank"))]))
        let related = try await graph.observe(observationQuery().where(.related(.actionObjects("action"), matching: .tag("ready"))))
        _ = try await waitForObservation(ordered) { $0.items.map(\.id) == [first, second] }
        _ = try await waitForObservation(related) { $0.items.isEmpty }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: second, properties: ["rank": .set(.integer(0))], addingTags: ["ready"])) }
        #expect(try await waitForObservation(ordered) { $0.items.map(\.id) == [second, first] }.items.count == 2)
        #expect(try await waitForObservation(related) { $0.items.map(\.id) == [first] }.items.count == 1)
        ordered.cancel(); related.cancel(); try await graph.close()
    }

    @Test func closeEndsOnlyItsHandlesFeedsAndFreshSubscriptionReadsCurrentState() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let other = try await database.openGraph(graph.id)
        let first = try await graph.changes(), second = try await other.changes()
        var a = first.makeAsyncIterator(), b = second.makeAsyncIterator()
        #expect(await a.next()?.reason == .initial)
        #expect(await b.next()?.reason == .initial)
        try await graph.close()
        #expect(await a.next() == nil)
        second.refresh()
        #expect(await b.next()?.reason == .refresh)
        let item = other.makeNodeID()
        _ = try await other.transaction { try $0.insert(GraphRecord(id: item, type: ObservedItem.graphType)) }
        let current = try await other.observe(observationQuery())
        #expect(try await waitForObservation(current) { $0.items.map(\.id) == [item] }.items.count == 1)
        current.cancel(); second.cancel()
        await #expect(throws: GraphStoreError.self) { try await graph.observe(observationQuery()) }
        try await other.close(); try await database.close()
    }

    @Test func failedRefreshIsVisibleAndCanRecoverWithoutResubscribing() async throws {
        let graph = try await GraphStore.inMemory()
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType, properties: ["rank": .data(Data([1]))])) }
        let query = try observationQuery().sorted(by: [GraphQuerySort(.property("rank"))])
        let observation = try await graph.observe(query)
        var iterator = observation.makeAsyncIterator()
        if case .failure(let error) = await iterator.next() { #expect(error is GraphQueryError) }
        else { Issue.record("Unsupported stored ordering must be visible as a failed refresh.") }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["rank": .set(.integer(2))])) }
        #expect(try await waitForObservation(observation) { $0.items.count == 1 }.items[0].id == id)
        observation.cancel(); try await graph.close()
    }

    @Test func sourceRegistrationPrecedesFirstReadAndSlowReadersCanRescanFinalState() async throws {
        let graph = try await GraphStore.inMemory(), query = try observationQuery()
        let observation = try await graph.observe(query)
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType, properties: ["version": .integer(0)])) }
        for version in 1...50 {
            try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["version": .set(.integer(Int64(version)))])) }
        }
        observation.refresh()
        #expect(try await waitForObservation(observation) { $0.items.first?.record.properties["version"] == .integer(50) }.items.count == 1)
        observation.cancel()
        let fresh = try await graph.observe(query)
        #expect(try await waitForObservation(fresh) { $0.items.first?.record.properties["version"] == .integer(50) }.items.count == 1)
        fresh.cancel(); try await graph.close()
    }

    @Test func nativeStoreSignalRefreshesPinnedSQLiteReadsAndFileReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GraphObservation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let graph = try await GraphStore.open(at: folder.appendingPathComponent("Graph.sqlite"))
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType)) }
        let changes = try await graph.changes()
        var iterator = changes.makeAsyncIterator(); _ = await iterator.next()
        try await graph.nativeOperation { container in
            NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator)
        }
        #expect(await iterator.next()?.requiresRescan == true)
        let source = folder.appendingPathComponent("source.bin"); try Data([1]).write(to: source)
        let metadata = try await graph.importAttachment(from: source, ownedBy: id)
        let observation = try await graph.observe(observationQuery())
        _ = try await waitForObservation(observation) { $0.items.count == 1 }
        try Data([2]).write(to: source)
        _ = try await graph.replaceAttachment(metadata.id, from: source)
        // Any file change conservatively invalidates application queries even without an owner field edit.
        _ = try await waitForObservation(observation) { $0.items.count == 1 }
        #expect(try await graph.attachment(metadata.id)?.data == Data([2]))
        observation.cancel(); changes.cancel(); try await graph.close()
    }
}
