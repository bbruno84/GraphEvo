import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

/// A deterministic transport bus, not physical CloudKit/server change-tag evidence.
private final class TransportBus: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: GraphCloudIncoming] = [:]
    private var fail = Set<String>()
    private var sends = 0
    func failNames(_ names: Set<String>) { lock.withLock { fail = names } }
    var sendCount: Int { lock.withLock { sends } }
    func inject(_ incoming: GraphCloudIncoming) { lock.withLock { records[incoming.recordName ?? UUID().uuidString] = incoming } }
    func send(_ batch: GraphCloudOutgoingBatch) throws -> GraphCloudSentReceipt {
        try lock.withLock {
            sends += 1
            var saves: [GraphCloudIncoming] = [], deletes: [String] = [], failures: [GraphCloudRecordFailure] = []
            for item in batch.items {
                if fail.contains(item.recordName) { failures.append(.init(recordName: item.recordName, code: CKError.Code.serverRecordChanged.rawValue)); continue }
                if let bytes = item.recordArchive {
                    guard let native = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes) else { throw GraphCloudError.invalidState }
                    let incoming = try GraphCloudRecordCodec.archive(native, scope: batch.zone.scope)
                    records[item.recordName] = incoming; saves.append(incoming)
                } else {
                    records[item.recordName] = GraphCloudIncoming(kind: .recordDeleted, zone: batch.zone, recordName: item.recordName, recordType: "GraphEvoNode")
                    deletes.append(item.recordName)
                }
            }
            return GraphCloudSentReceipt(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saves, deletedNames: deletes, failures: failures)
        }
    }
    func fetch(_ zones: [GraphCloudZone]) -> [GraphCloudIncoming] {
        lock.withLock { records.values.filter { zones.contains($0.zone) }.sorted { ($0.recordName ?? "") < ($1.recordName ?? "") } }
    }
    var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "transport-account" }, make: { [self] _, scope, _, callback in
            GraphCloudDriver(fetch: { zones in await callback(.incoming(self.fetch(zones))) }, cancel: {}, send: { batch in
                await callback(.sent(try self.send(batch)))
                await callback(.state(Data([1])))
            })
        })
    }
}
private final class TransportFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func enable() { lock.withLock { enabled = true } }
    func failOnce() throws {
        if lock.withLock({ let value = enabled; enabled = false; return value }) { throw GraphCloudError.persistence }
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudTransportTests {
    private struct Fixture {
        let directory: URL
        let storeURL: URL
        let config: GraphCloudConfiguration
        let manager: GraphContextManager
        let graph: GraphStore
        let binding: GraphCloudTransportBinding
    }
    private func fixture(bus: TransportBus, container: String = UUID().uuidString, graphID: GraphID = GraphID(),
                         adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter,
                         disk: GraphCloudDisk = .live) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Transport-\(UUID())")
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.transport." + container, environment: .development, directory: dir.appendingPathComponent("Cloud"))
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
        let graph = try await manager.createGraph(id: graphID, at: dir.appendingPathComponent("Graph.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: bus.adapter, disk: disk)
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "graph")
        try await manager.bindCloudZone(zone, to: graphID, configuration: config)
        let route = try #require(try await manager.cloudBinding(for: zone, configuration: config))
        return Fixture(directory: dir, storeURL: dir.appendingPathComponent("Graph.sqlite"), config: config, manager: manager, graph: graph,
                       binding: GraphCloudTransportBinding(identity: .init(container: config.containerIdentifier, environment: .development, account: "transport-account"), route: route))
    }
    private func finish(_ f: Fixture) async throws { try await f.graph.close(); try await f.manager.stopCloudSession(f.config) }
    private func incoming(_ record: GraphRecord, _ binding: GraphCloudBinding) throws -> GraphCloudIncoming {
        try GraphCloudRecordCodec.archive(GraphCloudNodeCodec.encode(record, binding: binding), scope: binding.zone.scope)
    }
    private func injected(_ modify: (GraphCloudStoreAdapter) -> GraphCloudStoreAdapter) throws -> GraphCoordinatorAdapter {
        let base = GraphCoordinatorFactory.adapter, sync = try #require(base.sync), cloud = try #require(sync.cloud)
        return GraphCoordinatorAdapter(graph: base.graph, sync: GraphSyncAdapter(cloud: modify(cloud), collect: sync.collect,
            prepare: sync.prepare, acknowledge: sync.acknowledge, importPatches: sync.importPatches), initialize: base.initialize)
    }

    @Test func privatePrimitivesReplicateAndImportsDoNotFeedUpload() async throws {
        let bus = TransportBus(), container = UUID().uuidString, graphID = GraphID()
        let a = try await fixture(bus: bus, container: container, graphID: graphID)
        defer { try? FileManager.default.removeItem(at: a.directory) }
        let first = a.graph.makeNodeID(), second = a.graph.makeNodeID(), edge = a.graph.makeNodeID(), action = a.graph.makeNodeID()
        try await a.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: "Item", properties: ["value": .integer(1), "null": .null], tags: ["initial"], groups: ["group"], createdDate: Date(timeIntervalSince1970: 12)))
            try $0.insert(GraphRecord(id: second, type: "Item"))
            try $0.insert(GraphRecord(id: edge, type: "links", endpoints: .relationship(subject: first, object: second)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [first], objects: [second])))
        }
        let sent = try await a.manager.sendCloudChanges(for: graphID, configuration: a.config)
        #expect(sent.succeeded == 4 && sent.failures.isEmpty && sent.transportError == nil)
        #expect(try await a.graph.collectSyncChanges() == 0)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus: bus, container: container, graphID: graphID)
        defer { try? FileManager.default.removeItem(at: b.directory) }
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        #expect(try await b.manager.applyCloudInbox(for: graphID, configuration: b.config).applied == 4)
        #expect(try await b.graph.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: first, object: second))
        #expect(try await b.graph.collectSyncChanges() == 0)
        try await b.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: first, properties: ["value": .set(.integer(2)), "null": .remove], removingTags: ["initial"])) }
        #expect(try await b.manager.sendCloudChanges(for: graphID, configuration: b.config).succeeded >= 1)
        try await b.manager.stopCloudSession(b.config)
        _ = try await a.manager.startCloudSession(a.config, adapter: bus.adapter)
        try await a.manager.fetchCloudChanges(.private, configuration: a.config)
        _ = try await a.manager.applyCloudInbox(for: graphID, configuration: a.config)
        #expect(try await a.graph.read { try $0.record(for: first)?.properties["value"] } == .integer(2))
        #expect(try await a.graph.read { try $0.record(for: first)?.properties["null"] } == nil)
        #expect(try await a.graph.collectSyncChanges() == 0)
        try await a.graph.delete(first)
        _ = try await a.manager.sendCloudChanges(for: graphID, configuration: a.config)
        try await a.manager.stopCloudSession(a.config)
        _ = try await b.manager.startCloudSession(b.config, adapter: bus.adapter)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: graphID, configuration: b.config)
        #expect(try await b.graph.read { try $0.record(for: first) } == nil)
        #expect(try await b.graph.read { try $0.record(for: edge) } == nil)
        #expect(try await b.graph.collectSyncChanges() == 0)
        try await a.graph.close(); try await finish(b)
    }

    @Test func removeAllUsesNormalBatchesAndPeerImportsDoNotReuploadDeletes() async throws {
        let bus = TransportBus(), container = UUID().uuidString, id = GraphID()
        let a = try await fixture(bus: bus, container: container, graphID: id)
        defer { try? FileManager.default.removeItem(at: a.directory) }
        let ids = (0..<137).map { _ in a.graph.makeNodeID() }
        try await a.graph.transaction { scope in
            for node in ids { try scope.insert(GraphRecord(id: node, type: "Removal.Bulk")) }
        }
        #expect(try await a.manager.sendCloudChanges(for: id, configuration: a.config).succeeded == 100)
        #expect(try await a.manager.sendCloudChanges(for: id, configuration: a.config).succeeded == 37)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus: bus, container: container, graphID: id)
        defer { try? FileManager.default.removeItem(at: b.directory) }
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: id, configuration: b.config)
        #expect(try await b.graph.read { try $0.record(for: ids[0]) != nil })
        try await b.manager.stopCloudSession(b.config)
        _ = try await a.manager.startCloudSession(a.config, adapter: bus.adapter)
        let ledger = try await a.manager.updateGraphLedger(for: id, configuration: a.config, mutation: .information(Data("{\"keep\":true}".utf8)))
        #expect(try await a.graph.removeAll() == 137)
        #expect(try await a.manager.graphLedger(for: id, configuration: a.config) == ledger)
        #expect(try await a.manager.cloudBinding(for: a.binding.route.zone, configuration: a.config) == a.binding.route)
        #expect(try await a.manager.sendCloudChanges(for: id, configuration: a.config).succeeded == 100)
        #expect(try await a.graph.collectSyncChanges() == 37)
        #expect(try await a.manager.sendCloudChanges(for: id, configuration: a.config).succeeded == 37)
        #expect(try await a.graph.collectSyncChanges() == 0)
        try await a.manager.stopCloudSession(a.config)
        _ = try await b.manager.startCloudSession(b.config, adapter: bus.adapter)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: id, configuration: b.config)
        let absent = try await b.graph.read { scope in try ids.allSatisfy { try scope.record(for: $0) == nil } }
        #expect(absent)
        #expect(try await b.graph.collectSyncChanges() == 0)
        #expect(try await b.graph.removeAll() == 0)
        try await a.graph.close(); try await finish(b)
    }

    @Test func lateSaveSuccessAfterRemoveAllKeepsPendingDeleteAndNeverRecreatesRecord() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Removal.InFlight")) }
        let frozen = try await f.graph.prepareTransport(f.binding)
        #expect(try await f.graph.removeAll() == 1)
        let receipt = try bus.send(frozen)
        try await f.graph.commitTransport(f.binding, receipt: receipt)
        #expect(try await f.graph.read { try $0.record(for: id) == nil })
        #expect(try await f.graph.collectSyncChanges() == 1)
        let deletion = try await f.graph.prepareTransport(f.binding)
        #expect(deletion.items.count == 1 && deletion.items[0].change.operation == .delete)
        #expect(deletion.items[0].change.generation > frozen.items[0].change.generation)
        try await f.graph.commitTransport(f.binding, receipt: bus.send(deletion))
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }

    @Test func failedRemovalUploadRetainsOnlyFailedDeleteAcrossStoreRestart() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = f.graph.makeNodeID(), b = f.graph.makeNodeID()
        try await f.graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "Removal.Partial"))
            try scope.insert(GraphRecord(id: b, type: "Removal.Partial"))
        }
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.removeAll() == 2)
        bus.failNames([try GraphCloudNodeCodec.recordID(for: b, binding: f.binding.route).recordName])
        let partial = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(partial.succeeded == 1 && partial.failures.count == 1)
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await f.graph.close()
        let reopened = try await f.manager.openGraph(id: f.graph.id, at: f.storeURL)
        #expect(try await reopened.read { try $0.record(for: b) == nil })
        #expect(try await reopened.collectSyncChanges() == 1)
        bus.failNames([])
        #expect(try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config).succeeded == 1)
        #expect(try await reopened.collectSyncChanges() == 0)
        try await reopened.close(); try await f.manager.stopCloudSession(f.config)
    }

    @Test func frozenAttemptAndMetadataSurviveReopenAndOldSuccessKeepsNewerEdit() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let batch = try await f.graph.prepareTransport(f.binding)
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])) }
        try await f.graph.close()
        let graph = try await f.manager.openGraph(id: f.graph.id, at: f.storeURL)
        #expect(try await graph.prepareTransport(f.binding) == batch)
        let raw = try await graph.prepareSyncBatch(maximumRecords: 100)
        await #expect(throws: GraphSyncError.unavailable) { try await graph.acknowledgeSyncBatch(raw.id, succeeded: [id]) }
        try await graph.abandonSyncBatch(raw.id)
        let receipt = try bus.send(batch)
        try await graph.commitTransport(f.binding, receipt: receipt)
        try await graph.commitTransport(f.binding, receipt: receipt)
        #expect(try await graph.collectSyncChanges() == 1)
        let newer = try await graph.prepareTransport(f.binding)
        #expect(newer.id != batch.id && newer.items[0].change.generation > batch.items[0].change.generation)
        try await graph.close(); try await f.manager.stopCloudSession(f.config)
    }

    @Test func partialSuccessRetainsFailedRecordsAndLetsOtherGraphsProgress() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = f.graph.makeNodeID(), b = f.graph.makeNodeID()
        try await f.graph.transaction { try $0.insert(GraphRecord(id: a, type: "Item")); try $0.insert(GraphRecord(id: b, type: "Item")) }
        let name = try GraphCloudNodeCodec.recordID(for: b, binding: f.binding.route).recordName
        bus.failNames([name])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.succeeded == 1 && report.failures.count == 1 && report.transportError == nil)
        #expect(try await f.graph.collectSyncChanges() == 1)
        let other = try await f.manager.createGraph(id: GraphID(), at: f.directory.appendingPathComponent("Other.sqlite"))
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "other")
        try await f.manager.bindCloudZone(zone, to: other.id, configuration: f.config)
        _ = try await other.transaction { try $0.insert(GraphRecord(id: other.makeNodeID(), type: "Other")) }
        #expect(try await f.manager.sendCloudChanges(for: other.id, configuration: f.config).succeeded == 1)
        bus.failNames([])
        #expect(try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config).succeeded == 1)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await other.close(); try await finish(f)
    }

    @Test func serverSuccessBeforeLocalCommitIsRecoveredWithoutAnotherSend() async throws {
        let bus = TransportBus(), fault = TransportFailureSwitch()
        let adapter = try injected { base in GraphCloudStoreAdapter(prepare: base.prepare, sent: { context, id, binding, receipt, limits in
            let result = try base.sent(context, id, binding, receipt, limits); try fault.failOnce(); return result
        }, apply: base.apply, trim: base.trim) }
        let f = try await fixture(bus: bus, adapter: adapter)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        fault.enable()
        await #expect(throws: GraphCloudError.persistence) { try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config) }
        #expect(bus.sendCount == 1)
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await finish(f)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await manager.startCloudSession(f.config, adapter: bus.adapter)
        let registration = try await manager.openGraph(id: f.graph.id, at: f.storeURL); try await registration.close()
        let report = try await manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.succeeded == 1 && bus.sendCount == 1)
        try await manager.stopCloudSession(f.config)
    }

    @Test func localSendCommitBeforeSessionConsumptionReplaysItsReceipt() async throws {
        let bus = TransportBus(), switcher = TransportFailureSwitch()
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, bytes in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: bytes)
            if doc.sent.isEmpty { try switcher.failOnce() }
            try GraphCloudDisk.live.write(url, bytes)
        })
        let f = try await fixture(bus: bus, disk: disk)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        switcher.enable()
        await #expect(throws: GraphCloudError.persistence) { try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config) }
        #expect(try await f.graph.collectSyncChanges() == 0)
        #expect(bus.sendCount == 1)
        try await finish(f)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await manager.startCloudSession(f.config, adapter: bus.adapter)
        let registration = try await manager.openGraph(id: f.graph.id, at: f.storeURL); try await registration.close()
        let replay = try await manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(replay.succeeded == 1 && bus.sendCount == 1)
        try await manager.stopCloudSession(f.config)
    }

    @Test func incomingEffectAndReceiptCommitTogetherAndReplayDoesNotOverwriteNewerLocalData() async throws {
        let bus = TransportBus(), switcher = TransportFailureSwitch()
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, bytes in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: bytes)
            if doc.inbox.isEmpty { try switcher.failOnce() }
            try GraphCloudDisk.live.write(url, bytes)
        })
        let f = try await fixture(bus: bus, disk: disk)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        bus.inject(try incoming(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)]), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        switcher.enable()
        await #expect(throws: GraphCloudError.persistence) { try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config) }
        #expect(try await f.graph.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])) }
        try await finish(f)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await manager.startCloudSession(f.config, adapter: bus.adapter)
        let registration = try await manager.openGraph(id: f.graph.id, at: f.storeURL); try await registration.close()
        #expect(try await manager.applyCloudInbox(for: f.graph.id, configuration: f.config).applied == 1)
        let graph = try await manager.openGraph(id: f.graph.id, at: f.storeURL)
        #expect(try await graph.read { try $0.record(for: id)?.properties["value"] } == .integer(2))
        #expect(try await graph.collectSyncChanges() == 1)
        try await graph.close(); try await manager.stopCloudSession(f.config)
    }

    @Test func incomingPreSaveFailureRollsBackBothDataAndReceipt() async throws {
        let bus = TransportBus(), fault = TransportFailureSwitch()
        let adapter = try injected { base in GraphCloudStoreAdapter(prepare: base.prepare, sent: base.sent, apply: { context, id, binding, effects, limits in
            let result = try base.apply(context, id, binding, effects, limits); try fault.failOnce(); return result
        }, trim: base.trim) }
        let f = try await fixture(bus: bus, adapter: adapter)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        bus.inject(try incoming(GraphRecord(id: id, type: "Item"), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        fault.enable()
        await #expect(throws: GraphCloudError.persistence) { try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config) }
        #expect(try await f.graph.read { try $0.record(for: id) } == nil)
        #expect(try await f.manager.cloudInbox(f.config).count == 1)
        #expect(try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config).applied == 1)
        #expect(try await f.graph.read { try $0.record(for: id) } != nil)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }

    @Test func pendingInverseChangesRollBackImportAndReceiptFingerprintsCannotBeReused() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = f.graph.makeNodeID(), b = f.graph.makeNodeID(), edge = f.graph.makeNodeID()
        try await f.graph.transaction { try $0.insert(GraphRecord(id: a, type: "Item")); try $0.insert(GraphRecord(id: b, type: "Item")) }
        let source = try incoming(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)), f.binding.route)
        let entry = GraphCloudInboxEntry(id: UUID(), change: source)
        await #expect(throws: GraphSyncError.pendingImport) { try await f.graph.applyTransport(f.binding, effects: [GraphCloudEffect(entry, binding: f.binding.route)]) }
        #expect(try await f.graph.read { try $0.record(for: edge) } == nil)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        try await f.graph.applyTransport(f.binding, effects: [GraphCloudEffect(entry, binding: f.binding.route)])
        let altered = try incoming(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: b, object: a)), f.binding.route)
        let sameID = GraphCloudInboxEntry(id: entry.id, change: altered)
        await #expect(throws: GraphCloudError.invalidState) { try await f.graph.applyTransport(f.binding, effects: [GraphCloudEffect(sameID, binding: f.binding.route)]) }
        #expect(try await f.graph.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: a, object: b))
        try await finish(f)
    }

    @Test func deletedZoneStopsSendingWithoutDeletingLocalGraphOrDecodingBadPayloads() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        // The generic secure archive is valid, but its CF01 body is not.
        let native = try GraphCloudNodeCodec.encode(GraphRecord(id: f.graph.makeNodeID(), type: "Item"), binding: f.binding.route)
        native["payload"] = Data([0, 1]) as CKRecordValue
        bus.inject(try GraphCloudRecordCodec.archive(native, scope: .private))
        bus.inject(GraphCloudIncoming(kind: .zoneDeleted, zone: f.binding.route.zone, deletionReason: "purged"))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        #expect(try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config, maximumEvents: 1).applied == 1)
        #expect(try await f.graph.read { try $0.record(for: id) } != nil)
        await #expect(throws: GraphCloudError.zoneUnavailable) { try await f.graph.prepareTransport(f.binding) }
        #expect(bus.sendCount == 0)
        try await finish(f)
    }

    @Test func cleanupFailureIsReportedAndPrunedOnNextOperation() async throws {
        let bus = TransportBus(), fault = TransportFailureSwitch()
        let adapter = try injected { base in GraphCloudStoreAdapter(prepare: base.prepare, sent: base.sent, apply: base.apply, trim: { context, id, binding, cleanup in
            if case .consumed = cleanup { try fault.failOnce() }
            try base.trim(context, id, binding, cleanup)
        }) }
        let f = try await fixture(bus: bus, adapter: adapter)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        fault.enable()
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.succeeded == 1 && report.cleanupPending)
        #expect(try await f.graph.collectSyncChanges() == 0)
        let retry = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(retry.succeeded == 0 && !retry.cleanupPending && bus.sendCount == 1)
        let remoteID = f.graph.makeNodeID()
        bus.inject(try incoming(GraphRecord(id: remoteID, type: "Remote"), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        fault.enable()
        let incomingOnly = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(incomingOnly.succeeded == 0 && incomingOnly.cleanupPending && bus.sendCount == 1)
        #expect(try await f.graph.read { try $0.record(for: remoteID) } != nil)
        try await finish(f)
    }

    @Test func corruptedFrozenBodyCannotUploadAnotherNode() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID(), other = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        _ = try await f.graph.prepareTransport(f.binding)
        let wrong = try incoming(GraphRecord(id: other, type: "Other"), f.binding.route)
        let bytes = try #require(wrong.recordArchive)
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
                let facade = GraphTypedStoreAdapter.facade(context)
                let root = try #require(Search<Entity>(graph: facade).where(.type(GraphTypedStoreAdapter.rootType)).sync().first)
                let data = try #require(root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] as? Data)
                var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                var attempt = try #require(document["attempt"] as? [String: Any])
                var items = try #require(attempt["items"] as? [[String: Any]])
                items[0]["recordArchive"] = bytes.base64EncodedString(); attempt["items"] = items; document["attempt"] = attempt
                root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] = try JSONSerialization.data(withJSONObject: document)
                try context.save()
            }
        }
        await #expect(throws: GraphCloudError.invalidState) { try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config) }
        #expect(bus.sendCount == 0)
        #expect(try await f.graph.read { try $0.record(for: other) } == nil)
        try await finish(f)
    }

    @Test func anotherAccountCannotReuseAClaimedGraph() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.graph.prepareTransport(f.binding)
        try await f.manager.stopCloudSession(f.config)
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development,
                                             directory: f.directory.appendingPathComponent("OtherAccount"))
        let adapter = GraphCloudAdapter(account: { _ in "different-account" }, make: bus.adapter.make)
        _ = try await f.manager.startCloudSession(config, adapter: adapter)
        try await f.manager.bindCloudZone(f.binding.route.zone, to: f.graph.id, configuration: config)
        await #expect(throws: GraphCloudError.invalidState) { try await f.manager.sendCloudChanges(for: f.graph.id, configuration: config) }
        #expect(bus.sendCount == 0)
        try await f.graph.close(); try await f.manager.stopCloudSession(config)
    }

    @Test func movingTheSandboxRestoresBindingsWithoutPersistedAbsolutePaths() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("NewContainer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: f.directory); try? FileManager.default.removeItem(at: moved) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let original = try await f.graph.prepareTransport(f.binding)
        let transportBytes = try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                let facade = GraphTypedStoreAdapter.facade(context)
                let root = try #require(Search<Entity>(graph: facade).where(.type(GraphTypedStoreAdapter.rootType)).sync().first)
                return try #require(root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] as? Data)
            }
        }
        let sessionBytes = try Data(contentsOf: f.config.directory.appendingPathComponent("session.json"))
        for bytes in [transportBytes, sessionBytes] {
            let json = try #require(String(data: bytes, encoding: .utf8))
            #expect(!json.contains("storeURL") && !json.contains(f.directory.path))
        }
        try await finish(f)
        try FileManager.default.moveItem(at: f.directory, to: moved)
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development, directory: moved.appendingPathComponent("Cloud"))
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        do {
            _ = try await manager.sendCloudChanges(for: f.graph.id, configuration: config)
            Issue.record("An unregistered resource was reopened from persisted routing.")
        } catch GraphStoreError.missingGraph { }
        let reopened = try await manager.openGraph(id: f.graph.id, at: moved.appendingPathComponent("Graph.sqlite"))
        let route = try #require(try await manager.cloudBinding(for: f.binding.route.zone, configuration: config))
        let binding = GraphCloudTransportBinding(identity: f.binding.identity, route: route)
        #expect(try await reopened.prepareTransport(binding) == original)
        let sent = try await manager.sendCloudChanges(for: f.graph.id, configuration: config)
        #expect(sent.succeeded == 1 && bus.sendCount == 1)
        #expect(try await reopened.collectSyncChanges() == 0)
        try await reopened.close(); try await manager.stopCloudSession(config)
    }

    @Test func oldEngineDocumentIsRefusedWithoutConversion() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await finish(f)
        let file = f.config.directory.appendingPathComponent("session.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["format"] = 1; json.removeValue(forKey: "sent")
        let bytes = try JSONSerialization.data(withJSONObject: json); try bytes.write(to: file)
        await #expect(throws: GraphCloudError.invalidState) { try await f.manager.startCloudSession(f.config, adapter: bus.adapter) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @available(iOS 17, macOS 14, *)
    @Test func nativeProviderOffersOnlyTheFrozenBatchAndRejectsForeignBodies() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let batch = try await f.graph.prepareTransport(f.binding), provider = GraphCloudNativeOutbox()
        let options = CKSyncEngine.SendChangesOptions(scope: .zoneIDs([CKRecordZone.ID(zoneName: batch.zone.name, ownerName: batch.zone.owner)]))
        try await provider.begin(batch)
        let offered = try #require(try await provider.next(options))
        #expect(offered.recordsToSave.count == 1)
        #expect(try await provider.next(options) == nil)
        try await provider.finish()
        let original = offered.recordsToSave[0], item = batch.items[0]
        #expect(GraphCloudNodeCodec.matchesFrozenServer(original, item: item, binding: f.binding.route))
        let altered = try GraphCloudNodeCodec.encode(GraphRecord(id: id, type: "Item", properties: ["value": .integer(2)]), binding: f.binding.route)
        #expect(!GraphCloudNodeCodec.matchesFrozenServer(altered, item: item, binding: f.binding.route))
        let other = try incoming(GraphRecord(id: f.graph.makeNodeID(), type: "Other"), f.binding.route)
        let corrupt = GraphCloudOutgoingBatch(id: batch.id, graphID: batch.graphID, zone: batch.zone,
            items: [GraphCloudOutgoingNode(change: item.change, recordName: item.recordName, recordArchive: other.recordArchive)])
        try await provider.begin(corrupt)
        await #expect(throws: GraphCloudError.invalidState) { try await provider.next(options) }
        try await provider.finish(); try await finish(f)
    }

    @Test func serverVersionEqualityNeverTreatsMissingTagsAsAnEcho() {
        #expect(GraphCloudNodeCodec.sameServerVersion("same", "same"))
        #expect(!GraphCloudNodeCodec.sameServerVersion("old", "new"))
        #expect(!GraphCloudNodeCodec.sameServerVersion(nil, nil))
        #expect(!GraphCloudNodeCodec.sameServerVersion("tag", nil))
    }

    @Test func pendingLocalWritesUseLastEditPolicyAndPublishWithoutManualResolution() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: a, type: "Item", properties: ["value": .integer(1)])) }
        bus.inject(try incoming(GraphRecord(id: a, type: "Item", properties: ["value": .integer(99)]), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        let applied = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(applied.resolvedConflicts == 1 && applied.pendingRetry)
        #expect(try await f.graph.read { try $0.record(for: a)?.properties["value"] } == .integer(1))
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(bus.sendCount == 1)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }

    @Test func missingEndpointsAreRetriedAndAbsentDatesStayAbsent() async throws {
        let bus = TransportBus(), f = try await fixture(bus: bus)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let a = f.graph.makeNodeID(), edge = f.graph.makeNodeID()
        bus.inject(try incoming(GraphRecord(id: a, type: "Item"), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        let missing = f.graph.makeNodeID()
        bus.inject(try incoming(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: missing)), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        await #expect(throws: (any Error).self) { try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config) }
        #expect(try await f.graph.read { try $0.record(for: edge) } == nil)
        bus.inject(try incoming(GraphRecord(id: missing, type: "Item", createdDate: nil), f.binding.route))
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: a, object: missing))
        #expect(try await f.graph.read { try $0.record(for: missing)?.createdDate } == nil)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }
}
