import CoreData
import Foundation
import GraphEvo
@testable import GraphEvoRuntime
import Testing

private actor ObservationReadGate {
    private var paused = false
    let entered = AsyncStream<Void>.makeStream()
    let permits = AsyncStream<Void>.makeStream()
    func pause() { paused = true }
    func checkpoint() async {
        if paused {
            entered.continuation.yield(())
            var iterator = permits.stream.makeAsyncIterator(); _ = await iterator.next()
        }
    }
    func release() { permits.continuation.yield(()) }
}

private struct FailableDecodedItem: GraphModel {
    static let graphType = ObservedItem.graphType
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws {
        if graphRecord.properties["decode"] == .string("fail") { throw ObservationTestFailure() }
        record = graphRecord
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

private struct IndependentlyDecodedItem: GraphModel {
    static let graphType = ObservedItem.graphType
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    let construction = UUID()
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(1))) struct GraphSharedObservationLabTests {
    @Test func equalDescriptorsShareOnlyFreshExecutionsAndCancelIndependently() async throws {
        let graph = try await GraphStore.inMemory(), hub = StoreInvalidationHub(), gate = ObservationReadGate()
        let lab = GraphSharedObservationLab(graph: graph, source: { hub.subscribe(owner: UUID()) }, beforeRead: { await gate.checkpoint() })
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType, properties: ["v": .integer(0)])) }
        let query = try observationQuery()
        let a = try await lab.observe(query), b = try await lab.observe(query)
        _ = try await waitForObservation(a) { _ in true }; _ = try await waitForObservation(b) { _ in true }
        await gate.pause(); a.refresh()
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["v": .set(.integer(1))])) }
        await gate.release()
        let left = try await waitForObservation(a) { $0.items.first?.record.properties["v"] == .integer(1) }
        let right = try await waitForObservation(b) { $0.items.first?.record.properties["v"] == .integer(1) }
        #expect(left.view == right.view)
        #expect(await lab.diagnostics.activeGroups == 1)
        #expect(await lab.diagnostics.subscribers == 2)
        a.cancel()
        #expect(await lab.diagnostics.subscribers == 1)
        b.refresh(); _ = await entered.next(); await gate.release()
        #expect(try await waitForObservation(b) { $0.items.map(\.id) == [id] }.items.count == 1)
        b.cancel()
        #expect(await lab.diagnostics.activeGroups == 0)
        #expect(await lab.diagnostics.subscribers == 0)
        let fresh = try await lab.observe(query)
        _ = await entered.next(); await gate.release()
        #expect(try await waitForObservation(fresh) { $0.items.map(\.id) == [id] }.items.count == 1)
        fresh.cancel(); try await graph.close()
    }

    @Test func descriptorBudgetAndHandleBoundariesArePreserved() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph(), sibling = try await database.openGraph(graph.id)
        let lab = GraphSharedObservationLab(graph: graph), other = GraphSharedObservationLab(graph: sibling)
        let a = try await lab.observe(observationQuery())
        let b = try await lab.observe(observationQuery().limit(1))
        let c = try await lab.observe(observationQuery().where(.tag("selected")))
        let d = try await lab.observe(GraphQuery<ObservedItem>(budget: GraphQueryBudget(maximumCandidates: 1)))
        let e = try await other.observe(observationQuery())
        _ = try await waitForObservation(a) { _ in true }; _ = try await waitForObservation(b) { _ in true }
        _ = try await waitForObservation(c) { _ in true }; _ = try await waitForObservation(e) { _ in true }
        var iterator = d.makeAsyncIterator()
        if case .failure(let error) = await iterator.next() { #expect(error is GraphQueryError) }
        else { Issue.record("A smaller work allowance must fail independently.") }
        #expect(await lab.diagnostics.activeGroups == 4)
        try await graph.close()
        for stream in [a,b,c,d] { var iterator = stream.makeAsyncIterator(); while await iterator.next() != nil {} }
        e.refresh(); _ = try await waitForObservation(e) { _ in true }
        await #expect(throws: GraphStoreError.self) { try await lab.observe(observationQuery()) }
        for stream in [a,b,c,d,e] { stream.cancel() }
        try await sibling.close(); try await database.close()
    }

    @Test func broadRelationActionFileChangesAndFailureRecoveryRemainVisible() async throws {
        let graph = try await GraphStore.inMemory(), lab = GraphSharedObservationLab(graph: graph)
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: ObservedItem.graphType, properties: ["rank": .integer(1)]))
            try scope.insert(GraphRecord(id: b, type: ObservedItem.graphType, properties: ["rank": .integer(2)]))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b])))
        }
        let relation = try await lab.observe(observationQuery().where(.related(.outgoing("edge"), matching: .tag("ready"))))
        let actions = try await lab.observe(observationQuery().where(.related(.actionObjects("action"), matching: .tag("ready"))))
        let ordered = try await lab.observe(observationQuery().sorted(by: [GraphQuerySort(.property("rank"))]).limit(1))
        _ = try await waitForObservation(relation) { $0.items.isEmpty }; _ = try await waitForObservation(actions) { $0.items.isEmpty }
        _ = try await waitForObservation(ordered) { $0.items.first?.id == a }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: b, properties: ["rank": .set(.integer(0))], addingTags: ["ready"])) }
        _ = try await waitForObservation(relation) { $0.items.map(\.id) == [a] }; _ = try await waitForObservation(actions) { $0.items.map(\.id) == [a] }
        _ = try await waitForObservation(ordered) { $0.items.first?.id == b }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: b, properties: ["rank": .set(.data(Data([1])))])) }
        var iterator = ordered.makeAsyncIterator()
        while let state = await iterator.next() { if case .failure = state { break } }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: b, properties: ["rank": .set(.integer(3))])) }
        _ = try await waitForObservation(ordered) { $0.items.first?.id == a }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data([1]).write(to: source)
        let file = try await graph.importAttachment(from: source, ownedBy: a)
        let before = try await waitForObservation(relation) { $0.items.map(\.id) == [a] }
        try Data([2]).write(to: source); _ = try await graph.replaceAttachment(file.id, from: source)
        _ = try await waitForObservation(relation) { $0.view.scopeID != before.view.scopeID }
        #expect(try await graph.attachment(file.id)?.data == Data([2]))
        try await graph.delete(b)
        _ = try await waitForObservation(relation) { $0.items.isEmpty }; _ = try await waitForObservation(actions) { $0.items.isEmpty }
        for stream in [relation,actions,ordered] { stream.cancel() }
        try await graph.close()
    }

    @Test func lateJoinDoesNotConsumeAnInflightReadAndAccountChangeSupersedesIt() async throws {
        let graph = try await GraphStore.inMemory(), hub = StoreInvalidationHub(), gate = ObservationReadGate()
        let lab = GraphSharedObservationLab(graph: graph, source: { hub.subscribe(owner: UUID()) }, beforeRead: { await gate.checkpoint() })
        let a = try await lab.observe(observationQuery())
        _ = try await waitForObservation(a) { _ in true }
        await gate.pause(); a.refresh()
        var started = gate.entered.stream.makeAsyncIterator(); _ = await started.next()
        let b = try await lab.observe(observationQuery())
        await gate.release()
        let first = try await waitForObservation(a) { _ in true }
        _ = await started.next(); await gate.release()
        let joined = try await waitForObservation(b) { _ in true }
        #expect(first.view.scopeID != joined.view.scopeID)
        a.refresh(); _ = await started.next()
        hub.publish(.accountChange)
        await gate.release()
        for observation in [a,b] {
            var iterator = observation.makeAsyncIterator()
            while let state = await iterator.next() {
                if case .failure(let error) = state { #expect(error is GraphObservationError); break }
            }
            #expect(await iterator.next() == nil)
            observation.cancel()
        }
        #expect(hub.subscriberCount == 0)
        try await graph.close()
    }

    @Test func sharedSnapshotsDecodeModelsIndependentlyAndDroppingLastOwnerRetiresTheSource() async throws {
        let graph = try await GraphStore.inMemory(), hub = StoreInvalidationHub(), gate = ObservationReadGate()
        let lab = GraphSharedObservationLab(graph: graph, source: { hub.subscribe(owner: UUID()) }, beforeRead: { await gate.checkpoint() })
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType, properties: ["v": .integer(0)])) }
        func value(_ observation: GraphObservation<GraphQueryState<IndependentlyDecodedItem>>, version: Int64) async throws -> GraphQueryResult<IndependentlyDecodedItem> {
            for await state in observation {
                if case .failure(let error) = state { throw error }
                if case .value(let result) = state, result.items.first?.record.properties["v"] == .integer(version) { return result }
            }
            throw ObservationTestFailure()
        }
        func consume() async throws {
            let query = GraphQuery<IndependentlyDecodedItem>(budget: try GraphQueryBudget(maximumCandidates: 256))
            let a = try await lab.observe(query), b = try await lab.observe(query)
            _ = try await value(a, version: 0); _ = try await value(b, version: 0)
            await gate.pause(); a.refresh()
            var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
            try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["v": .set(.integer(1))])) }
            await gate.release()
            let left = try await value(a, version: 1), right = try await value(b, version: 1)
            #expect(left.view == right.view)
            #expect(left.items.first?.construction != right.items.first?.construction)
            // Leave without explicit cancel; the final observation/iterator owner must retire.
        }
        try await consume()
        #expect(await lab.diagnostics.subscribers == 0)
        #expect(await lab.diagnostics.activeGroups == 0)
        #expect(hub.subscriberCount == 0)
        try await graph.close()
    }

    @Test func applicationDecoderFailuresRecoverWithoutContaminatingAnotherModel() async throws {
        let graph = try await GraphStore.inMemory(), lab = GraphSharedObservationLab(graph: graph), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType, properties: ["decode": .string("good")])) }
        let query = GraphQuery<FailableDecodedItem>(budget: try GraphQueryBudget(maximumCandidates: 256))
        let a = try await lab.observe(query), b = try await lab.observe(query), ordinary = try await lab.observe(observationQuery())
        var left = a.makeAsyncIterator(), right = b.makeAsyncIterator()
        #expect(await left.next() != nil); #expect(await right.next() != nil)
        _ = try await waitForObservation(ordinary) { $0.items.count == 1 }
        #expect(await lab.diagnostics.activeGroups == 2)
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["decode": .set(.string("fail"))])) }
        for observation in [a,b] {
            var iterator = observation.makeAsyncIterator()
            var failed = false
            while let state = await iterator.next() { if case .failure(let error) = state { #expect(error is ObservationTestFailure); failed = true; break } }
            #expect(failed)
        }
        _ = try await waitForObservation(ordinary) { $0.items.first?.record.properties["decode"] == .string("fail") }
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["decode": .set(.string("recovered"))])) }
        for observation in [a,b] {
            var recovered = false
            for await state in observation {
                if case .value(let value) = state, value.items.first?.record.properties["decode"] == .string("recovered") { recovered = true; break }
            }
            #expect(recovered)
            observation.cancel()
        }
        ordinary.cancel(); try await graph.close()
    }

    @Test func nativeStoreNotificationsRefreshWithoutReusingAnOldView() async throws {
        let graph = try await GraphStore.inMemory(), lab = GraphSharedObservationLab(graph: graph)
        let observation = try await lab.observe(observationQuery())
        let initial = try await waitForObservation(observation) { _ in true }
        try await graph.nativeOperation { container in
            NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator)
        }
        _ = try await waitForObservation(observation) { $0.view.scopeID != initial.view.scopeID }
        observation.cancel(); try await graph.close()
    }

    @Test func cancellationRacingAJoinDoesNotFinishTheJoiningSubscriber() async throws {
        let graph = try await GraphStore.inMemory(), lab = GraphSharedObservationLab(graph: graph)
        for _ in 0..<30 {
            let first = try await lab.observe(observationQuery())
            let cancel = Task { first.cancel() }
            let joined = try await lab.observe(observationQuery())
            await cancel.value
            _ = try await waitForObservation(joined) { _ in true }
            joined.cancel()
        }
        #expect(await lab.diagnostics.activeGroups == 0)
        #expect(await lab.diagnostics.subscribers == 0)
        try await graph.close()
    }

    @Test func accountChangeFinishesGroupsAndCancelledSubscriptionsDoNotAccumulate() async throws {
        let graph = try await GraphStore.inMemory(), hub = StoreInvalidationHub()
        let lab = GraphSharedObservationLab(graph: graph, source: { hub.subscribe(owner: UUID()) })
        for _ in 0..<30 {
            let observation = try await lab.observe(observationQuery())
            _ = try await waitForObservation(observation) { _ in true }; observation.cancel()
        }
        #expect(await lab.diagnostics.activeGroups == 0)
        #expect(await lab.diagnostics.subscribers == 0)
        let observation = try await lab.observe(observationQuery())
        _ = try await waitForObservation(observation) { _ in true }
        hub.publish(.accountChange)
        var iterator = observation.makeAsyncIterator()
        while let state = await iterator.next() {
            if case .failure(let error) = state { #expect(error is GraphObservationError); break }
        }
        #expect(await iterator.next() == nil)
        observation.cancel()
        #expect(hub.subscriberCount == 0)
        try await graph.close()
    }
}
