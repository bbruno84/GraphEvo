import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor CoordinatorGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        let pending = observers; observers.removeAll()
        for observer in pending { observer.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct GraphCoordinatorTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphCoordinator-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manager(_ registry: StoreRegistry = StoreRegistry()) -> GraphContextManager {
        GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func admitted(_ count: Int, by manager: GraphContextManager) async throws {
        for _ in 0..<5_000 {
            if await manager.registeredHandleCount == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The expected graph requests were not admitted.")
    }

    @Test func localFeaturesAndIdentitySurviveFinalCloseAndReopen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A.sqlite"), id = GraphID(), manager = GraphCoordinatorFactory.shared
        let a = try await manager.createGraph(id: id, at: url)
        let sibling = try await manager.openGraph(id: id, at: url)
        #expect(a !== sibling)
        let first = GraphNodeID(graphID: id), second = GraphNodeID(graphID: id)
        let edge = GraphNodeID(graphID: id), action = GraphNodeID(graphID: id)
        try await a.transaction {
            try $0.insert(GraphRecord(id: first, type: ObservedItem.graphType, properties: ["value": .integer(1)], tags: ["tag"], groups: ["group"]))
            try $0.insert(GraphRecord(id: second, type: "child"))
            try $0.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: first, object: second)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [first], objects: [second])))
        }
        let source = root.appendingPathComponent("input.bin"); try Data([1, 2, 3]).write(to: source)
        let attachment = try await a.importAttachment(from: source, ownedBy: first)
        let observation = try await sibling.observe(observationQuery())
        _ = try await waitForObservation(observation) { $0.items.count == 1 }
        try await a.transaction { _ = try $0.patch(GraphRecordPatch(id: first, properties: ["value": .set(.integer(2))])) }
        _ = try await waitForObservation(observation) { $0.items.first?.record.properties["value"] == .integer(2) }
        observation.cancel()
        try await a.close()
        #expect(try await sibling.read { try $0.record(for: first)?.tags } == ["tag"])
        try await sibling.close()
        #expect(await manager.registeredGraphCount == 0)
        let reopened = try await manager.openGraph(id: id, at: url)
        #expect(reopened.id == id)
        #expect(try await reopened.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: first, object: second))
        #expect(try await reopened.read { try $0.record(for: action)?.endpoints } == .action(subjects: [first], objects: [second]))
        #expect(try await reopened.read { try $0.record(for: first)?.groups } == ["group"])
        #expect(try await reopened.attachment(attachment.id)?.data == Data([1, 2, 3]))
        try await reopened.close()
    }

    @Test func concurrentCreationCoalescesBeforeLoadAndReturnsIndependentHandles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CoordinatorGate(), manager = manager(StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await gate.enter() })))
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let first = Task { try await manager.createGraph(id: id, at: url) }
        await gate.wait()
        let second = Task { try await manager.createGraph(id: id, at: url) }
        try await admitted(2, by: manager)
        await gate.release()
        let a = try await first.value, b = try await second.value
        let nativeA = try await a.nativeOperation { ObjectIdentifier($0) }
        #expect(try await b.nativeOperation { ObjectIdentifier($0) } == nativeA)
        await #expect(throws: GraphStoreError.self) { try await manager.createGraph(id: id, at: url) }
        try await a.close(); try await b.close()
    }

    @Test func cancelledOpeningWaiterDoesNotCancelItsSibling() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A.sqlite"), id = GraphID()
        let seed = manager(), initial = try await seed.createGraph(id: id, at: url); try await initial.close()
        let gate = CoordinatorGate(), manager = manager(StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await gate.enter() })))
        let cancelled = Task { try await manager.openGraph(id: id, at: url) }
        await gate.wait()
        let survivor = Task { try await manager.openGraph(id: id, at: url) }
        try await admitted(2, by: manager); cancelled.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let graph = try await survivor.value
        #expect(graph.id == id)
        try await graph.close()
        #expect(await manager.registeredGraphCount == 0)
    }

    @Test func duplicateBindingsAndConcurrentGenericOwnersAreRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A.sqlite"), id = GraphID(), manager = manager()
        let graph = try await manager.createGraph(id: id, at: url)
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: id, at: root.appendingPathComponent("Other.sqlite")) }
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: GraphID(), at: url) }
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
        #expect(throws: StoreRuntimeError.self) { try StoreGatewayLease.legacy(at: url) }
        let alias = root.appendingPathComponent("Alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let sibling = try await manager.openGraph(id: id, at: alias)
        try await graph.close(); try await sibling.close()
    }

    @Test func missingAndIncompatibleInputsAreNotCreatedOrConverted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(), missing = root.appendingPathComponent("missing/A.sqlite")
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: GraphID(), at: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let url = root.appendingPathComponent("Invalid.sqlite"), bytes = Data("not a store".utf8)
        try bytes.write(to: url)
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: GraphID(), at: url) }
        await #expect(throws: GraphStoreError.self) { try await manager.createGraph(id: GraphID(), at: url) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await manager.registeredGraphCount == 0)
    }

    @Test func multipleCatalogGraphsAndForeignOrphanRowsAreRefused() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Multi.sqlite"), db = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        let a = try await db.createGraph(), b = try await db.createGraph(), id = a.id
        try await a.close(); try await b.close(); try await db.close()
        let manager = manager()
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: id, at: url) }
        let check = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        #expect(try await check.graphIDs().count == 2); try await check.close()
        let orphanURL = root.appendingPathComponent("Orphan.sqlite")
        let original = try await GraphDatabase.open(at: orphanURL, schema: .nativeIdentity)
        let graph = try await original.createGraph(), originalID = graph.id
        try await original.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let facade = GraphTypedStoreAdapter.facade(context)
                let orphan = Entity("orphan", graph: facade)
                try GraphNativeIdentityColumns.stamp(orphan, graphID: GraphID(), nodeID: UUID())
                try context.save()
            }
        }
        try await graph.close(); try await original.close()
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: originalID, at: orphanURL) }
    }

    @Test func reopeningWaitsForLastCloseWhileAnotherGraphProgresses() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CoordinatorGate(), manager = manager(StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { await gate.enter() })))
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let graph = try await manager.createGraph(id: id, at: url)
        let closing = Task { try await graph.close() }; await gate.wait()
        closing.cancel()
        let sameClose = Task { try await graph.close() }
        let reopening = Task { try await manager.openGraph(id: id, at: url) }
        let other = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        #expect(await manager.registeredGraphCount == 2)
        await gate.release(); try await closing.value; try await sameClose.value
        let reopened = try await reopening.value
        try await reopened.close(); try await other.close()
    }

    @Test func failedDetachKeepsManagerAndRuntimeOwnership() async throws {
        struct DetachFailure: Error {}
        // Quarantined stores deliberately remain owned until the process exits.
        let root = try directory(), url = root.appendingPathComponent("A.sqlite"), id = GraphID()
        let manager = manager(StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { throw DetachFailure() })))
        let graph = try await manager.createGraph(id: id, at: url)
        await #expect(throws: GraphStoreError.self) { try await graph.close() }
        #expect(await manager.registeredGraphCount == 1)
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: id, at: url) }
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
    }

    @Test func abandonedHandleRetiresItsCoordinator() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A.sqlite"), manager = manager(), id = GraphID()
        func abandon() async throws { _ = try await manager.createGraph(id: id, at: url) }
        try await abandon()
        for _ in 0..<5_000 {
            if await manager.registeredGraphCount == 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await manager.registeredGraphCount == 0)
        let next = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
        try await next.close()
    }

    @Test func committedSharedCreationIsReturnedDespiteCallerCancellation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CoordinatorGate(), manager = manager(StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await gate.enter() })))
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let request = Task { try await manager.createGraph(id: id, at: url) }
        await gate.wait(); request.cancel(); await gate.release()
        let graph = try await request.value
        #expect(graph.id == id)
        try await graph.close()
        let reopened = try await manager.openGraph(id: id, at: url)
        try await reopened.close()
    }

    @Test func incompatibleNativeModelAndWrongGraphIDLeaveDataReadable() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Old.sqlite"), manager = manager()
        let old = try await GraphDatabase.open(at: url), graph = try await old.createGraph(), id = graph.id
        let node = GraphNodeID(graphID: id)
        try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "retained", properties: ["value": .integer(42)])) }
        try await graph.close(); try await old.close()
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: id, at: url) }
        let check = try await GraphDatabase.open(at: url), retained = try await check.openGraph(id)
        #expect(try await retained.read { try $0.record(for: node)?.properties["value"] } == .integer(42))
        try await retained.close(); try await check.close()
        let nativeURL = root.appendingPathComponent("Native.sqlite")
        let native = try await manager.createGraph(id: id, at: nativeURL); try await native.close()
        await #expect(throws: GraphStoreError.self) { try await manager.openGraph(id: GraphID(), at: nativeURL) }
        let correct = try await manager.openGraph(id: id, at: nativeURL); try await correct.close()
    }

    @Test func initializationAndPartialLoadCleanupFailuresRetainRegistration() async throws {
        struct InjectedFailure: Error {}
        // Both intentionally quarantined native resources remain owned until process exit.
        for failDuringLoad in [false, true] {
            let root = try directory(), url = root.appendingPathComponent("A.sqlite"), id = GraphID()
            let seed = manager(), graph = try await seed.createGraph(id: id, at: url); try await graph.close()
            let hooks = StoreLifecycleHooks(beforeDetach: { throw InjectedFailure() }, didLoadStore: { _ in
                if failDuringLoad { throw InjectedFailure() }
            })
            let owner = manager(StoreRegistry(hooks: hooks))
            // A wrong ID fails initialization after loading; the other case fails while loading.
            let requestedID = failDuringLoad ? id : GraphID()
            await #expect(throws: GraphStoreError.self) { try await owner.openGraph(id: requestedID, at: url) }
            #expect(await owner.registeredGraphCount == 1)
            await #expect(throws: GraphStoreError.self) { try await owner.openGraph(id: requestedID, at: url) }
            await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
        }
    }
}
