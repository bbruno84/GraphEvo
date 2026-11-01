import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class RemovalCommitGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() {
        let values = lock.withLock { entered = true; let values = waiters; waiters.removeAll(); return values }
        for value in values { value.resume() }
        semaphore.wait()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if entered { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func release() { semaphore.signal() }
}

@Suite(.timeLimit(.minutes(2))) struct GraphRemovalTests {
    private struct Abort: Error {}
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("GraphRemoval-" + UUID().uuidString) }
    private func manager() -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func seed(_ graph: GraphStore) async throws -> [GraphNodeID] {
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID(), file = graph.makeNodeID()
        let attachment = try GraphAttachmentPayload(id: file, ownerID: edge, fileName: "removal.bin", contentType: "public.data", data: Data(repeating: 91, count: 2 * 1024 * 1024))
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "Removal.Item", properties: ["null": .null, "uuid": .uuid(UUID())], tags: ["tag"], groups: ["group"]))
            try scope.insert(GraphRecord(id: b, type: "Removal.Item"))
            try scope.insert(GraphRecord(id: edge, type: "Removal.Edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "Removal.Action", endpoints: .action(subjects: [a], objects: [b])))
            try scope.insert(attachment)
        }
        return [a,b,edge,action,file]
    }
    private func assertAbsent(_ graph: GraphStore, _ ids: [GraphNodeID]) async throws {
        try await graph.read { scope in for id in ids { let record = try scope.record(for: id); #expect(record == nil) } }
    }

    @Test func allPrimitiveKindsAndExternalContentAreRemovedButGraphReopensAndRepopulates() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID(), url = root.appendingPathComponent("Graph.sqlite")
        let graph = try await m.createGraph(id: id, at: url), ids = try await seed(graph)
        _ = try await graph.collectSyncChanges()
        let baseline = try await graph.prepareSyncBatch(maximumRecords: 100); _ = try await graph.acknowledgeSyncBatch(baseline.id, succeeded: Set(ids))
        try await graph.setConflictPolicy(.cloudWins)
        #expect(try await graph.removeAll(maximumRecords: 5) == 5)
        try await assertAbsent(graph, ids)
        #expect(try await graph.collectSyncChanges() == 5)
        let deleted = try await graph.prepareSyncBatch(maximumRecords: 100)
        #expect(Set(deleted.items.map(\.change.id)) == Set(ids))
        #expect(deleted.items.allSatisfy { $0.change.operation == .delete && $0.record == nil })
        _ = try await graph.acknowledgeSyncBatch(deleted.id, succeeded: Set(ids))
        #expect(try await graph.removeAll() == 0)
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close()
        let reopened = try await m.openGraph(id: id, at: url)
        #expect(reopened.id == id)
        #expect(try await reopened.conflictPolicy == .cloudWins)
        let fresh = reopened.makeNodeID()
        _ = try await reopened.transaction { try $0.insert(GraphRecord(id: fresh, type: "Removal.New")) }
        await #expect {
            try await reopened.transaction { try $0.insert(GraphRecord(id: ids[0], type: "Removal.New")) }
        } throws: { if case GraphStoreError.duplicateIdentity = $0 { return true }; return false }
        #expect(try await reopened.collectSyncChanges() == 1)
        try await reopened.close()
    }

    @Test func failedAndCancelledTransactionsRetainContentAndDoNotPublishDeletes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let ids = try await seed(graph)
        _ = try await graph.collectSyncChanges()
        let initial = try await graph.prepareSyncBatch(maximumRecords: 100); _ = try await graph.acknowledgeSyncBatch(initial.id, succeeded: Set(ids))
        await #expect(throws: Abort.self) {
            try await graph.transaction { scope throws -> Void in _ = try scope.removeAll(); throw Abort() }
        }
        let gate = RemovalCommitGate()
        let task = Task {
            try await graph.transaction { scope in
                _ = try scope.removeAll()
                gate.enter()
            }
        }
        await gate.wait(); task.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await graph.collectSyncChanges() == 0)
        #expect(try await graph.read { try $0.record(for: ids[0]) != nil })
        #expect(try await graph.attachment(ids[4])?.data.count == 2 * 1024 * 1024)
        try await graph.close()
    }

    @Test func explicitLimitsRefuseBeforeRemovingAnyData() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let ids = try await seed(graph)
        await #expect(throws: GraphRemovalError.invalidLimit) { try await graph.removeAll(maximumRecords: 0) }
        await #expect(throws: GraphRemovalError.recordLimitExceeded) { try await graph.removeAll(maximumRecords: 4) }
        #expect(try await graph.read { try $0.record(for: ids[2]) != nil })
        #expect(try await graph.attachment(ids[4]) != nil)
        try await graph.close()
    }

    @Test func emptyingAndRepopulationShareOneTransaction() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let old = try await seed(graph), fresh = graph.makeNodeID()
        let count = try await graph.transaction { scope in
            let removed = try scope.removeAll()
            try scope.insert(GraphRecord(id: fresh, type: "Removal.Replacement"))
            return removed
        }
        #expect(count == 5)
        try await assertAbsent(graph, old)
        #expect(try await graph.read { try $0.record(for: fresh) != nil })
        await #expect {
            try await graph.transaction { scope in
                _ = try scope.removeAll()
                try scope.insert(GraphRecord(id: fresh, type: "Removal.Reused"))
            }
        } throws: { if case GraphStoreError.duplicateIdentity = $0 { return true }; return false }
        #expect(try await graph.read { try $0.record(for: fresh)?.type == "Removal.Replacement" })
        try await graph.close()
    }

    @Test(arguments: [false, true]) func anotherGraphInTheSameResourceAndItsHiddenCatalogArePreserved(native: Bool) async throws {
        let db = try await GraphDatabase.inMemory(schema: native ? .nativeIdentity : .current)
        let a = try await db.createGraph(), b = try await db.createGraph(), aid = a.makeNodeID(), bid = b.makeNodeID()
        _ = try await a.transaction { try $0.insert(GraphRecord(id: aid, type: "Removal.A")) }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: bid, type: "Removal.B")) }
        #expect(try await a.removeAll() == 1)
        #expect(try await db.graphIDs().count == 2)
        #expect(try await b.read { try $0.record(for: bid) != nil })
        let reopened = try await db.openGraph(a.id)
        #expect(try await reopened.removeAll() == 0)
        _ = try await reopened.transaction { try $0.insert(GraphRecord(id: aid, type: "Removal.FreshLocal")) }
        try await reopened.close(); try await a.close(); try await b.close(); try await db.close()
    }

    @Test func standaloneTypedGraphIsSupported() async throws {
        let graph = try await GraphStore.inMemory(), ids = try await seed(graph)
        #expect(try await graph.removeAll() == 5)
        try await assertAbsent(graph, ids)
        try await graph.close()
        await #expect { try await graph.removeAll() } throws: { if case GraphStoreError.closed = $0 { return true }; return false }
    }

    @Test func malformedAttachmentRefusesWholeOperationBeforeDeletingOtherRecords() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let ids = try await seed(graph), graphID = graph.id
        try await graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                let file = try #require(session.nodes[ids[4]])
                file[dynamicMember: GraphAttachmentPayload.contentKey] = Data([0])
                context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
                try context.save()
            }
        }
        await #expect(throws: (any Error).self) { try await graph.removeAll() }
        #expect(try await graph.read { try $0.record(for: ids[0]) != nil })
        #expect(try await graph.read { try $0.record(for: ids[2]) != nil })
        try await graph.close()
    }

    @Test func observedQueriesRefreshToEmptyAfterCommittedRemoval() async throws {
        let graph = try await GraphStore.inMemory(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType)) }
        let observation = try await graph.observe(try observationQuery())
        _ = try await waitForObservation(observation) { $0.items.count == 1 }
        #expect(try await graph.removeAll() == 1)
        _ = try await waitForObservation(observation) { $0.items.isEmpty }
        observation.cancel(); try await graph.close()
    }

    @Test func readOnlyStoreRefusesRemovalAndPreservesContent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Graph.sqlite"), db = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        let graph = try await db.createGraph(), id = graph.makeNodeID(), graphID = graph.id
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "Removal.ReadOnly")) }
        try await graph.close(); try await db.close()
        let reader = try await GraphDatabase.openReadOnly(at: url, schema: .nativeIdentity), view = try await reader.openGraph(graphID)
        await #expect { try await view.removeAll() } throws: { if case GraphStoreError.readOnly = $0 { return true }; return false }
        #expect(try await view.read { try $0.record(for: id) != nil })
        try await view.close(); try await reader.close()
    }

    @Test func writeReservationsAndReadOnlyParticipantsRefuseEmptying() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID(), url = root.appendingPathComponent("Graph.sqlite")
        let graph = try await m.createGraph(id: id, at: url), ids = try await seed(graph)
        let hold = try await m.suspendLocalWrites(for: id)
        await #expect { try await graph.removeAll() } throws: { if case GraphStoreError.writesSuspended = $0 { return true }; return false }
        await hold.release()
        let peer = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Peer.sqlite"))
        let route = GraphCloudBinding(zone: .init(scope: .shared, owner: "owner", name: "zone"), graphID: peer.id)
        _ = try await peer.participantAccess(.init(binding: route, account: "account", permission: .readWrite, accepted: true))
        let item = peer.makeNodeID()
        _ = try await peer.transaction { try $0.insert(GraphRecord(id: item, type: "Removal.Shared")) }
        _ = try await peer.participantAccess(.init(binding: route, account: "account", permission: .readOnly, accepted: true))
        await #expect { try await peer.removeAll() } throws: { if case GraphStoreError.permissionDenied = $0 { return true }; return false }
        #expect(try await peer.read { try $0.record(for: item) != nil })
        #expect(try await graph.read { try $0.record(for: ids[0]) != nil })
        try await peer.close(); try await graph.close()
    }
}
