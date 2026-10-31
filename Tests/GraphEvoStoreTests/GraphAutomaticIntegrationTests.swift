import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor AutomaticReplicaBus {
    private var records: [GraphCloudZone: [String: GraphCloudIncoming]] = [:]
    var sent: [GraphCloudOutgoingBatch] = []
    var fetches = 0
    var held: CheckedContinuation<Void, Never>?
    var shouldHold = false
    var fetchFault: NSError?
    var cancelled = false
    var holdCancellation = false
    var cancellation: CheckedContinuation<Void, Never>?
    func fetch(_ zones: [GraphCloudZone]) throws -> [GraphCloudIncoming] {
        fetches += 1
        if let fetchFault { throw fetchFault }
        return zones.flatMap { Array(records[$0, default: [:]].values) }
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        sent.append(batch)
        if shouldHold { await withCheckedContinuation { held = $0 } }
        var saved: [GraphCloudIncoming] = [], deleted: [String] = []
        for item in batch.items {
            if let archive = item.recordArchive {
                let native = try GraphCloudRecordCodec.restore(archive)
                let value = try GraphCloudRecordCodec.archive(native, scope: batch.zone.scope, portableAsset: true)
                records[batch.zone, default: [:]][item.recordName] = value; saved.append(value)
            } else {
                records[batch.zone, default: [:]][item.recordName] = .init(kind: .recordDeleted, zone: batch.zone,
                    recordName: item.recordName, recordType: GraphCloudNodeCodec.recordType)
                deleted.append(item.recordName)
            }
        }
        return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: [])
    }
    func release() { shouldHold = false; let value = held; held = nil; value?.resume() }
    func hold() { shouldHold = true }
    func blockCancellation() { holdCancellation = true }
    func unblockCancellation() { let value = cancellation; cancellation = nil; holdCancellation = false; value?.resume() }
    func cancel() async {
        cancelled = true
        if holdCancellation { await withCheckedContinuation { cancellation = $0 } }
        release()
    }
    nonisolated var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "automatic-test" }, make: { [self] _, _, _, receive in
            GraphCloudDriver(fetch: { zones in await receive(.incoming(try self.fetch(zones))) }, cancel: { await self.cancel() },
                             send: { batch in await receive(.sent(try self.send(batch))) })
        })
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphAutomaticIntegrationTests {
    private struct Replica {
        let manager: GraphContextManager
        let graph: GraphStore
        let config: GraphCloudConfiguration
        let root: URL
        let clock: AutomaticTestClock
    }
    private func replica(_ bus: AutomaticReplicaBus, id: GraphID, container: String, root: URL? = nil) async throws -> Replica {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticReplica-" + UUID().uuidString)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let url = root.appendingPathComponent("Graph.sqlite")
        let graph: GraphStore
        if FileManager.default.fileExists(atPath: url.path) { graph = try await manager.openGraph(id: id, at: url) }
        else { graph = try await manager.createGraph(id: id, at: url) }
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.automatic." + container, environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        try await manager.bindCloudZone(.init(scope: .private, owner: "owner", name: "A"), to: id, configuration: config)
        return Replica(manager: manager, graph: graph, config: config, root: root, clock: AutomaticTestClock())
    }
    private func active(_ r: Replica) async throws {
        try await r.manager.setAutomaticCloudSynchronizationActive(true, configuration: r.config, clock: r.clock.value)
    }
    private func wait(line: Int = #line, _ condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            do { if try await condition() { return } }
            catch GraphSyncError.busy { }
            catch GraphCloudError.busy { }
            guard ContinuousClock.now < deadline else { Issue.record("Wait expired at integration line \(line)"); throw GraphCloudError.invalidState }
            await Task.yield()
        }
    }
    private func close(_ r: Replica, remove: Bool = true) async throws {
        try await r.manager.setAutomaticCloudSynchronizationActive(false, configuration: r.config)
        try await r.manager.stopCloudSession(r.config)
        try await r.graph.close()
        if remove { try FileManager.default.removeItem(at: r.root) }
    }

    @Test func consumerCommitPublishesAndFreshReplicaImportsWithoutFeedback() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), container = UUID().uuidString
        let owner = try await replica(bus, id: id, container: container), node = GraphNodeID(graphID: id)
        _ = try await owner.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item", properties: ["value": .integer(1)])) }
        try await active(owner)
        try await wait { await bus.sent.count == 1 }
        try await wait { await owner.manager.automaticSynchronizationIdle(owner.config) }
        #expect(try await owner.graph.collectSyncChanges() == 0)
        // The session process claim is intentionally independent of the local graph owner.
        try await owner.manager.stopCloudSession(owner.config)
        let peer = try await replica(bus, id: id, container: container)
        try await active(peer)
        try await wait { try await peer.graph.read { try $0.record(for: node)?.properties["value"] } == .integer(1) }
        try await wait { await peer.manager.automaticSynchronizationIdle(peer.config) }
        #expect(try await peer.graph.collectSyncChanges() == 0)
        #expect(await bus.sent.count == 1)
        peer.clock.advance(60)
        try await wait { await bus.fetches >= 3 }
        #expect(await bus.sent.count == 1)
        try await close(peer)
        try await owner.graph.close(); try FileManager.default.removeItem(at: owner.root)
    }

    @Test func pausedWritesResumeAndFrozenGenerationDoesNotAcknowledgeNewerEdit() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), r = try await replica(bus, id: id, container: UUID().uuidString)
        let node = GraphNodeID(graphID: id)
        _ = try await r.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item", properties: ["value": .integer(1)])) }
        try await r.manager.pauseCloudSynchronization(for: id)
        try await active(r)
        #expect(await bus.sent.isEmpty)
        await bus.hold()
        try await r.manager.resumeCloudSynchronization(for: id)
        try await wait { await bus.held != nil }
        _ = try await r.graph.transaction { try $0.patch(GraphRecordPatch(id: node, properties: ["value": .set(.integer(2))])) }
        let pause = Task { try await r.manager.pauseCloudSynchronization(for: id) }
        try await wait { try await r.manager.cloudSynchronizationState(for: id) == .pauseRequested }
        await bus.release(); try await pause.value
        try await wait { await r.manager.automaticSynchronizationIdle(r.config) }
        #expect(try await r.graph.collectSyncChanges() == 1)
        #expect(await bus.sent.count == 1)
        try await r.manager.resumeCloudSynchronization(for: id)
        try await wait { await bus.sent.count == 2 }
        try await wait { await r.manager.automaticSynchronizationIdle(r.config) }
        #expect(try await r.graph.collectSyncChanges() == 0)
        try await close(r)
    }

    @Test func restartRecoversPendingWritesWithoutConsumerReplayAndCloseDoesNotRetainALease() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), container = UUID().uuidString
        let first = try await replica(bus, id: id, container: container), node = GraphNodeID(graphID: id)
        _ = try await first.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item")) }
        try await close(first, remove: false)
        let second = try await replica(bus, id: id, container: container, root: first.root)
        try await active(second)
        try await wait { await second.manager.automaticSynchronizationIdle(second.config) }
        #expect(try await second.graph.collectSyncChanges() == 0)
        #expect(await bus.sent.count == 1)
        try await second.graph.close()
        try await wait { await second.manager.registeredGraphCount == 0 }
        second.clock.advance(60)
        #expect(await second.manager.registeredGraphCount == 0)
        #expect(await bus.sent.count == 1)
        try await second.manager.stopCloudSession(second.config)
        try FileManager.default.removeItem(at: second.root)
    }

    @Test func actualUnknownAuthorBlocksWithoutUploadingOrSilentlyAdvancingHistory() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), r = try await replica(bus, id: id, container: UUID().uuidString)
        let node = r.graph.makeNodeID()
        _ = try await r.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item")) }
        try await r.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                context.transactionAuthor = "unsupported-writer"
                try #require(session.nodes[node]).add(tags: "foreign")
                try context.save()
            }
        }
        try await active(r)
        try await wait { try await r.manager.automaticCloudSynchronizationStatus(for: id, configuration: r.config).phase == .blocked }
        #expect(await bus.sent.isEmpty)
        let status = try await r.manager.automaticCloudSynchronizationStatus(for: id, configuration: r.config)
        #expect(status.failure?.hasPrefix("history:") == true)
        try await close(r)
    }

    @Test func commitAfterActivationTriggersPHWithoutPollingOrManualRequest() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), r = try await replica(bus, id: id, container: UUID().uuidString)
        try await active(r)
        try await wait { await r.manager.automaticSynchronizationIdle(r.config) }
        let node = r.graph.makeNodeID()
        _ = try await r.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item")) }
        try await wait { await r.manager.automaticSynchronizationDeadline(id, configuration: r.config) != nil }
        r.clock.advance(0.249)
        #expect(await bus.sent.isEmpty)
        r.clock.advance(0.001)
        try await wait { await bus.sent.count == 1 }
        try await wait { await r.manager.automaticSynchronizationIdle(r.config) }
        #expect(try await r.graph.collectSyncChanges() == 0)
        try await close(r)
    }
    @Test func stoppingRejectsReactivationAndRetainsAdmittedReceiptForRestart() async throws {
        let bus = AutomaticReplicaBus(), id = GraphID(), r = try await replica(bus, id: id, container: UUID().uuidString)
        let node = r.graph.makeNodeID()
        _ = try await r.graph.transaction { try $0.insert(GraphRecord(id: node, type: "Item")) }
        await bus.hold(); await bus.blockCancellation()
        try await active(r)
        try await wait { await bus.held != nil }
        let stopping = Task { try await r.manager.stopCloudSession(r.config) }
        try await wait { await bus.cancelled }
        await #expect(throws: GraphCloudError.stopping) {
            try await r.manager.setAutomaticCloudSynchronizationActive(true, configuration: r.config)
        }
        await bus.unblockCancellation(); try await stopping.value
        _ = try await r.manager.startCloudSession(r.config, adapter: bus.adapter)
        try await active(r)
        try await wait { await r.manager.automaticSynchronizationIdle(r.config) }
        #expect(try await r.graph.collectSyncChanges() == 0)
        #expect(await bus.sent.count == 1)
        try await close(r)
    }

}
