import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor PauseSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !signalled { await withCheckedContinuation { waiters.append($0) } } }
    func signal() { signalled = true; let current = waiters; waiters = []; for waiter in current { waiter.resume() } }
}

private final class PauseNativeBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var isReady: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func wait() throws {
        condition.lock(); defer { condition.unlock() }
        entered = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(15)
        while !released {
            guard condition.wait(until: deadline) else { throw GraphCloudError.invalidState }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor PauseBus {
    private var records: [GraphCloudZone: [String: GraphCloudIncoming]] = [:]
    var fetchRequests: [[GraphCloudZone]] = []
    private var sendBlock: (PauseSignal, PauseSignal)?
    private var fetchBlock: (PauseSignal, PauseSignal)?
    private var failSend = false
    func blockSend(_ entered: PauseSignal, _ proceed: PauseSignal, failing: Bool = false) { sendBlock = (entered, proceed); failSend = failing }
    func blockFetch(_ entered: PauseSignal, _ proceed: PauseSignal) { fetchBlock = (entered, proceed) }
    func inject(_ record: GraphCloudIncoming) { records[record.zone, default: [:]][record.recordName!] = record }
    func fetch(_ zones: [GraphCloudZone]) async -> [GraphCloudIncoming] {
        fetchRequests.append(zones)
        if let block = fetchBlock { await block.0.signal(); await block.1.wait() }
        return zones.flatMap { Array(records[$0, default: [:]].values) }
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        if let block = sendBlock { await block.0.signal(); await block.1.wait() }
        if failSend { throw GraphCloudError.transportUnavailable }
        var saved: [GraphCloudIncoming] = [], deleted: [String] = []
        for item in batch.items {
            if let bytes = item.recordArchive {
                let native = try GraphCloudRecordCodec.restore(bytes)
                let record = try GraphCloudRecordCodec.archive(native, scope: batch.zone.scope, portableAsset: true)
                inject(record); saved.append(record)
            } else {
                inject(.init(kind: .recordDeleted, zone: batch.zone, recordName: item.recordName, recordType: GraphCloudNodeCodec.recordType))
                deleted.append(item.recordName)
            }
        }
        return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: [])
    }
    nonisolated var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "pause-account" }, make: { [self] _, _, _, receive in
            GraphCloudDriver(fetch: { zones in await receive(.incoming(self.fetch(zones))) }, cancel: {},
                             send: { batch in await receive(.sent(try self.send(batch))) })
        })
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudPauseTests {
    private struct Fixture {
        let root: URL
        let manager: GraphContextManager
        let config: GraphCloudConfiguration
        let bus: PauseBus
        let a: GraphStore
        let b: GraphStore
        let nodeA: GraphNodeID
        let nodeB: GraphNodeID
        let routeA: GraphCloudBinding
        let routeB: GraphCloudBinding
    }
    private func fixture(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pause-" + UUID().uuidString), bus = PauseBus()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
        let a = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let b = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.pause." + UUID().uuidString, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        let zoneA = GraphCloudZone(scope: .private, owner: "owner", name: "A"), zoneB = GraphCloudZone(scope: .private, owner: "owner", name: "B")
        try await manager.bindCloudZone(zoneA, to: a.id, configuration: config)
        try await manager.bindCloudZone(zoneB, to: b.id, configuration: config)
        let nodeA = a.makeNodeID(), nodeB = b.makeNodeID()
        _ = try await a.transaction { try $0.insert(GraphRecord(id: nodeA, type: "Item", properties: ["value": .integer(1)])) }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: nodeB, type: "Item", properties: ["value": .integer(1)])) }
        _ = try await manager.sendCloudChanges(for: a.id, configuration: config)
        _ = try await manager.sendCloudChanges(for: b.id, configuration: config)
        return Fixture(root: root, manager: manager, config: config, bus: bus, a: a, b: b, nodeA: nodeA, nodeB: nodeB,
                       routeA: .init(zone: zoneA, graphID: a.id), routeB: .init(zone: zoneB, graphID: b.id))
    }
    private func close(_ f: Fixture) async throws {
        try await f.a.close(); try await f.b.close(); try await f.manager.stopCloudSession(f.config)
        try FileManager.default.removeItem(at: f.root)
    }
    private func patch(_ graph: GraphStore, id: GraphNodeID, value: Int64) async throws {
        let patch = try GraphRecordPatch(id: id, properties: ["value": .set(.integer(value))])
        _ = try await graph.transaction { try $0.patch(patch) }
    }
    private func remote(_ f: Fixture, a: Bool, value: Int64) async throws {
        let record = try GraphRecord(id: a ? f.nodeA : f.nodeB, type: "Item", properties: ["value": .integer(value)])
        let native = try GraphCloudNodeCodec.encode(record, binding: a ? f.routeA : f.routeB, modifiedAt: .distantFuture)
        await f.bus.inject(try GraphCloudRecordCodec.archive(native, scope: .private))
    }
    private func file(_ f: Fixture, a: Bool) async throws -> GraphAttachmentContent {
        let payload = try GraphAttachmentPayload(id: a ? f.a.makeNodeID() : f.b.makeNodeID(), ownerID: a ? f.nodeA : f.nodeB,
            fileName: "file.bin", contentType: "public.data", data: Data([1,2,3]))
        let native = try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: a ? f.routeA : f.routeB)
        await f.bus.inject(try GraphCloudRecordCodec.archive(native, scope: .private, portableAsset: true))
        return payload.content
    }

    @Test func idlePauseIsIdempotentLocalWritesContinueAndOtherGraphFetches() async throws {
        let f = try await fixture()
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .active)
        try await f.manager.pauseCloudSynchronization(for: f.a.id)
        try await f.manager.pauseCloudSynchronization(for: f.a.id)
        #expect(await iterator.next() == .paused)
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .paused)
        await #expect(throws: GraphCloudError.graphPaused) { try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config) }
        await #expect(throws: GraphCloudError.graphPaused) { try await f.manager.applyCloudInbox(for: f.a.id, configuration: f.config) }
        try await patch(f.a, id: f.nodeA, value: 3)
        #expect(try await f.a.collectSyncChanges() == 1)
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        #expect(await f.bus.fetchRequests.last == [f.routeB.zone])
        try await f.manager.resumeCloudSynchronization(for: f.a.id)
        try await f.manager.resumeCloudSynchronization(for: f.a.id)
        #expect(await iterator.next() == .active)
        #expect(try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config).succeeded == 1)
        #expect(try await f.a.collectSyncChanges() == 0)
        try await close(f)
        #expect(await iterator.next() == nil)
    }

    @Test func requestedPauseDrainsFrozenSendAndCancellationDoesNotUndoIt() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        try await patch(f.a, id: f.nodeA, value: 3)
        await f.bus.blockSend(entered, proceed)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let sending = Task { try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config) }
        await entered.wait()
        let cancelled = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Cancelled pause wait returned") } catch is CancellationError { }
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .pauseRequested)
        await #expect(throws: GraphCloudError.busy) { try await f.manager.resumeCloudSynchronization(for: f.a.id) }
        await #expect(throws: GraphCloudError.graphPaused) { try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config) }
        try await patch(f.a, id: f.nodeA, value: 4)
        try await patch(f.b, id: f.nodeB, value: 2)
        await proceed.signal()
        #expect(try await sending.value.succeeded == 1)
        try await pausing.value
        #expect(await iterator.next() == .paused)
        #expect(try await f.a.collectSyncChanges() == 1)
        #expect(try await f.a.read { try $0.record(for: f.nodeA)?.properties["value"] } == .integer(4))
        #expect(try await f.manager.sendCloudChanges(for: f.b.id, configuration: f.config).succeeded == 1)
        try await f.manager.resumeCloudSynchronization(for: f.a.id)
        #expect(try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config).succeeded == 1)
        #expect(try await f.a.collectSyncChanges() == 0)
        try await close(f)
    }

    @Test func requestedPauseDrainsFetchButRetainsUnappliedIncomingWork() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        try await remote(f, a: true, value: 2); try await remote(f, a: false, value: 2)
        await f.bus.blockFetch(entered, proceed)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let fetching = Task { try await f.manager.fetchCloudChanges(.private, configuration: f.config) }
        await entered.wait()
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        await proceed.signal(); try await fetching.value; try await pausing.value
        #expect(await iterator.next() == .paused)
        await #expect(throws: GraphCloudError.graphPaused) { try await f.manager.applyCloudInbox(for: f.a.id, configuration: f.config) }
        _ = try await f.manager.applyCloudInbox(for: f.b.id, configuration: f.config)
        #expect(try await f.a.read { try $0.record(for: f.nodeA)?.properties["value"] } == .integer(1))
        #expect(try await f.b.read { try $0.record(for: f.nodeB)?.properties["value"] } == .integer(2))
        try await f.manager.resumeCloudSynchronization(for: f.a.id)
        _ = try await f.manager.applyCloudInbox(for: f.a.id, configuration: f.config)
        #expect(try await f.a.read { try $0.record(for: f.nodeA)?.properties["value"] } == .integer(2))
        #expect(try await f.a.collectSyncChanges() == 0)
        try await close(f)
    }

    @Test func failedSendSettlesPauseAndPreservesTheImmutableAttempt() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        try await patch(f.a, id: f.nodeA, value: 3)
        let binding = GraphCloudTransportBinding(identity: .init(container: f.config.containerIdentifier, environment: .development, account: "pause-account"), route: f.routeA)
        let frozen = try await f.a.prepareTransport(binding)
        await f.bus.blockSend(entered, proceed, failing: true)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let sending = Task { try await f.manager.sendCloudChanges(for: f.a.id, configuration: f.config) }
        await entered.wait()
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        await proceed.signal()
        let report = try await sending.value
        #expect(report.transportError as? GraphCloudError == .transportUnavailable)
        try await pausing.value
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .paused)
        #expect(try await f.a.prepareTransport(binding) == frozen)
        #expect(try await f.a.collectSyncChanges() == 1)
        try await close(f)
    }

    @Test func aliasesSharePauseStopDoesNotResumeAndFullCloseResets() async throws {
        let f = try await fixture()
        let alias = try await f.manager.openGraph(id: f.a.id, at: f.root.appendingPathComponent("A.sqlite"))
        try await f.manager.pauseCloudSynchronization(for: f.a.id)
        try await f.a.close()
        #expect(try await f.manager.cloudSynchronizationState(for: alias.id) == .paused)
        try await f.manager.stopCloudSession(f.config)
        #expect(try await f.manager.cloudSynchronizationState(for: alias.id) == .paused)
        _ = try await f.manager.startCloudSession(f.config, adapter: f.bus.adapter)
        #expect(try await f.manager.cloudSynchronizationState(for: alias.id) == .paused)
        try await alias.close()
        let reopened = try await f.manager.openGraph(id: f.a.id, at: f.root.appendingPathComponent("A.sqlite"))
        #expect(try await f.manager.cloudSynchronizationState(for: reopened.id) == .active)
        try await reopened.close(); try await close(f)
    }

    @Test func cancelledAssetWaitStillDrainsTheAdmittedRefreshBeforePausing() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        let content = try await file(f, a: true), destination = f.root.appendingPathComponent("cancelled.bin")
        await f.bus.blockFetch(entered, proceed)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let exporting = Task { try await f.manager.exportCloudAttachment(content.metadata.id, to: destination, configuration: f.config) }
        await entered.wait()
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        exporting.cancel()
        do { _ = try await exporting.value; Issue.record("Cancelled export returned") } catch is CancellationError { }
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .pauseRequested)
        try await patch(f.a, id: f.nodeA, value: 3)
        await proceed.signal(); try await pausing.value
        #expect(try await f.a.attachment(content.metadata.id) == content)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .paused)
        _ = try await f.manager.exportCloudAttachment(content.metadata.id, to: f.root.appendingPathComponent("local.bin"), configuration: f.config)
        try await close(f)
    }

    @Test func resumedGraphGetsItsOwnFetchWhenTheSharedCutExcludedIt() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        let fileA = try await file(f, a: true), fileB = try await file(f, a: false)
        try await f.manager.pauseCloudSynchronization(for: f.b.id)
        await f.bus.blockFetch(entered, proceed)
        let a = Task { try await f.manager.exportCloudAttachment(fileA.metadata.id, to: f.root.appendingPathComponent("A.bin"), configuration: f.config) }
        await entered.wait()
        try await f.manager.resumeCloudSynchronization(for: f.b.id)
        let stream = try await f.manager.observeCloudSynchronization(for: f.b.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let b = Task { try await f.manager.exportCloudAttachment(fileB.metadata.id, to: f.root.appendingPathComponent("B.bin"), configuration: f.config) }
        // Both admitted graph refreshes must await the same already-selected database fetch.
        let deadline = ContinuousClock.now + .seconds(10)
        while await f.manager.attachmentFetchWaiterCount < 2 {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline {
                await proceed.signal()
                _ = try? await a.value; _ = try? await b.value
                Issue.record("The second refresh did not join the selected fetch")
                try await close(f); return
            }
            await Task.yield()
        }
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.b.id) }
        #expect(await iterator.next() == .pauseRequested)
        await proceed.signal()
        #expect(try await a.value == fileA.metadata)
        #expect(try await b.value == fileB.metadata)
        try await pausing.value
        let requests = await f.bus.fetchRequests
        #expect(requests.count == 2 && requests[0] == [f.routeA.zone] && requests[1] == [f.routeB.zone])
        try await close(f)
    }
    @Test(arguments: [false, true])
    func pauseWaitsForNativeImportCommitOrRollback(_ fail: Bool) async throws {
        let barrier = PauseNativeBarrier()
        defer { barrier.release() }
        let base = GraphCoordinatorFactory.adapter, originalSync = try #require(base.sync), originalCloud = try #require(originalSync.cloud)
        let cloud = GraphCloudStoreAdapter(prepare: originalCloud.prepare, sent: originalCloud.sent, apply: { context, id, binding, effects, limits in
            let result = try originalCloud.apply(context, id, binding, effects, limits)
            try barrier.wait()
            if fail { throw GraphCloudError.invalidState }
            return result
        }, trim: originalCloud.trim)
        var sync = GraphSyncAdapter(cloud: cloud, collect: originalSync.collect, prepare: originalSync.prepare,
                                   acknowledge: originalSync.acknowledge, importPatches: originalSync.importPatches)
        sync.policy = originalSync.policy
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: sync, initializePolicy: base.initializePolicy, initialize: base.initialize)
        let f = try await fixture(adapter: adapter)
        try await remote(f, a: true, value: 2)
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let applying = Task { try await f.manager.applyCloudInbox(for: f.a.id, configuration: f.config) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !barrier.isReady {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw GraphCloudError.invalidState }
            await Task.yield()
        }
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        #expect(try await f.a.read { try $0.record(for: f.nodeA)?.properties["value"] } == .integer(1))
        barrier.release()
        if fail {
            do { _ = try await applying.value; Issue.record("Faulted import committed") } catch GraphCloudError.invalidState { }
        } else { _ = try await applying.value }
        try await pausing.value
        #expect(try await f.manager.cloudSynchronizationState(for: f.a.id) == .paused)
        #expect(try await f.a.read { try $0.record(for: f.nodeA)?.properties["value"] } == .integer(fail ? 1 : 2))
        let retained = try await f.manager.cloudInbox(f.config)
        #expect(retained.contains { $0.change.zone == f.routeA.zone } == fail)
        #expect(try await f.a.collectSyncChanges() == 0)
        try await close(f)
    }
    @Test func allPausedBoundZonesDoNotStartAnotherFetch() async throws {
        let f = try await fixture()
        try await f.manager.pauseCloudSynchronization(for: f.a.id)
        try await f.manager.pauseCloudSynchronization(for: f.b.id)
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        #expect(await f.bus.fetchRequests.isEmpty)
        try await close(f)
    }
    @Test func closingTheLastHandleDuringFetchRetainsTheDrainThenReopensActive() async throws {
        let f = try await fixture(), entered = PauseSignal(), proceed = PauseSignal()
        await f.bus.blockFetch(entered, proceed)
        let stream = try await f.manager.observeCloudSynchronization(for: f.a.id)
        var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
        let fetching = Task { try await f.manager.fetchCloudChanges(.private, configuration: f.config) }
        await entered.wait()
        let pausing = Task { try await f.manager.pauseCloudSynchronization(for: f.a.id) }
        #expect(await iterator.next() == .pauseRequested)
        try await f.a.close()
        await proceed.signal(); try await fetching.value; try await pausing.value
        // Newest-state delivery may end immediately after the final drain/close.
        let last = await iterator.next()
        #expect(last == .paused || last == nil)
        let reopened = try await f.manager.openGraph(id: f.a.id, at: f.root.appendingPathComponent("A.sqlite"))
        #expect(try await f.manager.cloudSynchronizationState(for: reopened.id) == .active)
        try await reopened.close(); try await close(f)
    }

}
