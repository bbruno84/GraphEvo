import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class PolicyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100)
    var beforeNow: (@Sendable () -> Void)?
    func set(_ seconds: Double) { lock.withLock { value = Date(timeIntervalSince1970: seconds) } }
    func now() -> Date { beforeNow?(); return lock.withLock { value } }
}
/// Scripted native receipts; actual server CAS/change-tag proof stays in device tests.
private final class PolicyBus: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[GraphCloudRecordFailure]] = []
    private var incoming: [GraphCloudIncoming] = []
    private var batches: [GraphCloudOutgoingBatch] = []
    var splitReceipts = false
    var beforeReceipt: (@Sendable () async throws -> Void)?
    func script(_ failures: [[GraphCloudRecordFailure]]) { lock.withLock { scripts = failures } }
    func fetch(_ changes: [GraphCloudIncoming]) { lock.withLock { incoming = changes } }
    var sent: [GraphCloudOutgoingBatch] { lock.withLock { batches } }
    func send(_ batch: GraphCloudOutgoingBatch) throws -> GraphCloudSentReceipt {
        try lock.withLock {
            batches.append(batch)
            let failures = scripts.isEmpty ? [] : scripts.removeFirst()
            let failed = Set(failures.map(\.recordName))
            var saved: [GraphCloudIncoming] = [], deleted: [String] = []
            for item in batch.items where !failed.contains(item.recordName) {
                if let bytes = item.recordArchive {
                    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes)
                    let native = try #require(decoded)
                    saved.append(try GraphCloudRecordCodec.archive(native, scope: batch.zone.scope))
                } else { deleted.append(item.recordName) }
            }
            return GraphCloudSentReceipt(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: failures)
        }
    }
    var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "policy-account" }, make: { [self] _, _, _, receive in
            GraphCloudDriver(fetch: { _ in await receive(.incoming(self.lock.withLock { self.incoming })) }, cancel: {}, send: { batch in
                let receipt = try self.send(batch)
                try await self.beforeReceipt?()
                if self.splitReceipts && !receipt.saved.isEmpty && !receipt.failures.isEmpty {
                    await receive(.sent(GraphCloudSentReceipt(batchID: receipt.batchID, graphID: receipt.graphID, zone: receipt.zone, saved: receipt.saved, deletedNames: [], failures: [])))
                    await receive(.sent(GraphCloudSentReceipt(batchID: receipt.batchID, graphID: receipt.graphID, zone: receipt.zone, saved: [], deletedNames: receipt.deletedNames, failures: receipt.failures)))
                } else { await receive(.sent(receipt)) }
            })
        })
    }
}

private final class PolicyBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false
    private var released = false
    var isReady: Bool { condition.lock(); defer { condition.unlock() }; return arrived }
    func wait() { condition.lock(); arrived = true; condition.broadcast(); while !released { condition.wait() }; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Suite(.timeLimit(.minutes(2))) struct GraphConflictPolicyTests {
    private struct Fixture {
        let directory: URL
        let manager: GraphContextManager
        let graph: GraphStore
        let config: GraphCloudConfiguration
        let binding: GraphCloudTransportBinding
        let bus: PolicyBus
        let clock: PolicyClock
    }
    private func fixture(_ policy: GraphConflictPolicy = .lastEditWins) async throws -> Fixture {
        let clock = PolicyClock(), bus = PolicyBus()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Policies-\(UUID())")
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity,
            adapter: GraphCoordinatorFactory.makeAdapter(clock: { clock.now() }))
        let graph = try await manager.createGraph(id: GraphID(), at: dir.appendingPathComponent("Graph.sqlite"), conflictPolicy: policy)
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.policies." + UUID().uuidString, environment: .development, directory: dir.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "graph")
        try await manager.bindCloudZone(zone, to: graph.id, configuration: config)
        let route = try #require(try await manager.cloudBinding(for: zone, configuration: config))
        return Fixture(directory: dir, manager: manager, graph: graph, config: config,
            binding: .init(identity: .init(container: config.containerIdentifier, environment: .development, account: "policy-account"), route: route), bus: bus, clock: clock)
    }
    private func finish(_ f: Fixture) async throws { try await f.graph.close(); try await f.manager.stopCloudSession(f.config); try FileManager.default.removeItem(at: f.directory) }
    private func record(_ id: GraphNodeID, _ value: Int64) throws -> GraphRecord { try GraphRecord(id: id, type: "Item", properties: ["value": .integer(value)], createdDate: Date(timeIntervalSince1970: 1)) }
    private func insert(_ f: Fixture, value: Int64 = 1) async throws -> GraphNodeID {
        let id = f.graph.makeNodeID(), record = try record(id, value)
        _ = try await f.graph.transaction { try $0.insert(record) }; return id
    }
    private func date(_ graph: GraphStore, _ id: GraphNodeID) async throws -> Date? {
        try await graph.read { scope in try scope.withContext { context, _ in
            let session = try GraphTypedStoreAdapter.Session(context, id.graphID, database: true)
            return try session.node(id).map { try GraphMutationMetadata.modifiedAt($0) } ?? nil
        } }
    }
    private func change(_ f: Fixture, _ id: GraphNodeID, _ value: Int64) async throws {
        let patch = try GraphRecordPatch(id: id, properties: ["value": .set(.integer(value))])
        _ = try await f.graph.transaction { try $0.patch(patch) }
    }
    private func remote(_ f: Fixture, _ id: GraphNodeID, value: Int64 = 2, time: Double?) throws -> GraphCloudIncoming {
        try GraphCloudRecordCodec.archive(GraphCloudNodeCodec.encode(record(id, value), binding: f.binding.route,
            modifiedAt: time.map { Date(timeIntervalSince1970: $0) }), scope: .private)
    }
    private func failure(_ incoming: GraphCloudIncoming) -> GraphCloudRecordFailure { .init(recordName: incoming.recordName!, code: CKError.Code.serverRecordChanged.rawValue, serverRecord: incoming) }

    @Test func timestampIsAtomicScopedAndNoOpDoesNotRefreshIt() async throws {
        let f = try await fixture(), id = try await insert(f)
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 100))
        f.clock.set(200); try await change(f, id, 1)
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 100))
        do {
            let patch = try GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])
            try await f.graph.transaction { scope in _ = try scope.patch(patch); throw GraphSyncError.invalidState }
        } catch GraphSyncError.invalidState { }
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 100))
        try await change(f, id, 3)
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 200))
        try await finish(f)
    }
    @Test func policyIsSharedPersistedAndDoesNotChangeApplicationDates() async throws {
        let f = try await fixture(.cloudWins), id = try await insert(f)
        let alias = try await f.manager.openGraph(id: f.graph.id, at: f.directory.appendingPathComponent("Graph.sqlite"))
        #expect(try await alias.conflictPolicy == .cloudWins)
        try await f.graph.setConflictPolicy(.lastEditWins)
        #expect(try await alias.conflictPolicy == .lastEditWins)
        #expect(try await date(alias, id) == Date(timeIntervalSince1970: 100))
        try await alias.close(); try await f.graph.close()
        let reopened = try await f.manager.openGraph(id: f.graph.id, at: f.directory.appendingPathComponent("Graph.sqlite"))
        #expect(try await reopened.conflictPolicy == .lastEditWins)
        try await reopened.close(); try await f.manager.stopCloudSession(f.config); try FileManager.default.removeItem(at: f.directory)
    }
    @Test(arguments: [GraphConflictPolicy.cloudWins, .lastEditWins])
    func newerRemoteWinsAndKeepsItsDateWithoutFeedback(_ policy: GraphConflictPolicy) async throws {
        let f = try await fixture(policy), id = try await insert(f)
        f.bus.script([[failure(try remote(f, id, time: 200))]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.resolvedConflicts == 1 && report.failures.isEmpty && !report.pendingRetry)
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, 2))
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 200))
        #expect(try await f.graph.collectSyncChanges() == 0 && f.bus.sent.count == 1)
        try await finish(f)
    }
    @Test(arguments: [GraphConflictPolicy.cloudWins, .lastEditWins])
    func currentLocalRatherThanFrozenBodyIsUsedAfterLateEdit(_ policy: GraphConflictPolicy) async throws {
        let f = try await fixture(policy), id = try await insert(f)
        let patch = try GraphRecordPatch(id: id, properties: ["value": .set(.integer(4))])
        f.bus.beforeReceipt = {
            if f.bus.sent.count == 1 { f.clock.set(400); _ = try await f.graph.transaction { try $0.patch(patch) } }
        }
        f.bus.script([[failure(try remote(f, id, time: 200))]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        let expected: Int64 = policy == .lastEditWins ? 4 : 2
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, expected))
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: policy == .lastEditWins ? 400 : 200))
        #expect(report.resolvedConflicts == 1 && !report.pendingRetry && report.failures.isEmpty)
        #expect(f.bus.sent.count == (policy == .lastEditWins ? 2 : 1))
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }
    @Test(arguments: [0.0, 100.0])
    func olderRemoteRebasesAndTieUsesCloud(_ remoteTime: Double) async throws {
        let f = try await fixture(), id = try await insert(f)
        f.bus.script([[failure(try remote(f, id, time: remoteTime))]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(f.bus.sent.count == (remoteTime == 100 ? 1 : 2))
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, remoteTime == 100 ? 2 : 1))
        #expect(!report.pendingRetry)
        try await finish(f)
    }
    @Test func retryIsBoundedAndPartialSuccessDoesNotReuploadTheLeaf() async throws {
        let f = try await fixture(), id = try await insert(f), leaf = try await insert(f, value: 9)
        let conflict = failure(try remote(f, id, time: 0))
        f.bus.script([[conflict], [conflict]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.succeeded == 1 && report.pendingRetry && report.resolvedConflicts == 2)
        #expect(f.bus.sent.count == 2 && f.bus.sent[1].items.map(\.change.id) == [id])
        #expect(try await f.graph.collectSyncChanges() == 1)
        #expect(try await f.graph.read { try $0.record(for: leaf) } == record(leaf, 9))
        try await finish(f)
    }
    @Test(arguments: [GraphConflictPolicy.cloudWins, .lastEditWins])
    func importedDeletionWinsAndOldSaveCannotResurrectOrReuseID(_ policy: GraphConflictPolicy) async throws {
        let f = try await fixture(policy), id = try await insert(f)
        let saved = try remote(f, id, time: 500)
        f.bus.fetch([.init(kind: .recordDeleted, zone: f.binding.route.zone, recordName: saved.recordName, recordType: GraphCloudNodeCodec.recordType)])
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: id) } == nil)
        #expect(try await f.graph.collectSyncChanges() == 0)
        f.bus.fetch([saved]); try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: id) } == nil)
        let record = try record(id, 5)
        do { _ = try await f.graph.transaction { try $0.insert(record) }; Issue.record("Deleted identity reused") }
        catch GraphStoreError.duplicateIdentity { }
        try await finish(f)
    }
    @Test func localDeletionBeatsNewerIncomingSave() async throws {
        let f = try await fixture(.cloudWins), id = try await insert(f)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        try await f.graph.delete(id)
        f.bus.fetch([try remote(f, id, time: 1000)])
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: id) } == nil)
        #expect(try await f.graph.collectSyncChanges() == 1)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }
    @Test(arguments: [false, true])
    func deletionDominatesStaleSaveInTheSameInboxCut(_ deletionFirst: Bool) async throws {
        let f = try await fixture(), id = try await insert(f)
        let saved = try remote(f, id, time: 500)
        let deleted = GraphCloudIncoming(kind: .recordDeleted, zone: f.binding.route.zone,
            recordName: saved.recordName, recordType: GraphCloudNodeCodec.recordType)
        f.bus.fetch(deletionFirst ? [deleted, saved] : [saved, deleted])
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        _ = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: id) } == nil)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }
    @Test func survivingActionIsStampedInTheDeletionTransaction() async throws {
        let f = try await fixture(), a = try await insert(f), b = try await insert(f)
        let action = f.graph.makeNodeID()
        let record = try GraphRecord(id: action, type: "Action", endpoints: .action(subjects: [a], objects: [b]))
        _ = try await f.graph.transaction { try $0.insert(record) }
        f.clock.set(200); try await f.graph.delete(b)
        #expect(try await date(f.graph, action) == Date(timeIntervalSince1970: 200))
        #expect(try await date(f.graph, a) == Date(timeIntervalSince1970: 100))
        try await finish(f)
    }
    @Test func cancellationBeforeSaveRollsBackTheTimestampAndBody() async throws {
        let f = try await fixture(), id = try await insert(f), barrier = PolicyBarrier()
        f.clock.set(200); f.clock.beforeNow = { barrier.wait() }
        let patch = try GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])
        let task = Task { try await f.graph.transaction { try $0.patch(patch) } }
        while !barrier.isReady { await Task.yield() }
        task.cancel(); barrier.release()
        do { _ = try await task.value; Issue.record("Cancelled mutation committed") } catch is CancellationError { }
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 100))
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, 1))
        try await finish(f)
    }
    private func setRawDate(_ f: Fixture, id: GraphNodeID, malformed: Bool) async throws {
        _ = try await f.graph.collectSyncChanges()
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                let session = try GraphTypedStoreAdapter.Session(context, id.graphID, database: true)
                let found = try session.node(id)
                let node = try #require(found)
                node[dynamicMember: GraphMutationMetadata.modifiedKey] = malformed ? "invalid" : nil
                context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
                try context.save()
            }
        }
    }
    @Test(arguments: [false, true])
    func unknownDateUsesCloudAndMalformedDateRefusesWithoutPublishing(_ malformed: Bool) async throws {
        let f = try await fixture(), id = try await insert(f)
        try await setRawDate(f, id: id, malformed: malformed)
        if malformed {
            await #expect(throws: GraphSyncError.invalidState) { try await f.graph.prepareTransport(f.binding) }
            #expect(f.bus.sent.isEmpty)
        } else {
            f.bus.script([[failure(try remote(f, id, time: nil))]])
            _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
            #expect(try await f.graph.read { try $0.record(for: id) } == record(id, 2))
            #expect(try await date(f.graph, id) == nil)
        }
        try await finish(f)
    }
    @Test func incomingNewerRecordResolvesPendingWithoutFeedingUpload() async throws {
        let f = try await fixture(), id = try await insert(f)
        f.bus.fetch([try remote(f, id, time: 200)])
        try await f.manager.fetchCloudChanges(.private, configuration: f.config)
        let applied = try await f.manager.applyCloudInbox(for: f.graph.id, configuration: f.config)
        #expect(applied.resolvedConflicts == 1 && !applied.pendingRetry)
        #expect(try await f.graph.collectSyncChanges() == 0)
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 200))
        #expect(f.bus.sent.isEmpty)
        try await finish(f)
    }
    @Test(arguments: [false, true])
    func knownDateBeatsUnknownInEitherDirection(_ localUnknown: Bool) async throws {
        let f = try await fixture(), id = try await insert(f)
        if localUnknown { try await setRawDate(f, id: id, malformed: false) }
        f.bus.script([[failure(try remote(f, id, time: localUnknown ? 0 : nil))]])
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, localUnknown ? 2 : 1))
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: localUnknown ? 0 : 100))
        try await finish(f)
    }
    @Test func unknownItemWithoutPriorServerAssociationRemainsAnError() async throws {
        let f = try await fixture(), id = try await insert(f)
        let name = try GraphCloudNodeCodec.recordID(for: id, binding: f.binding.route).recordName
        f.bus.script([[.init(recordName: name, code: CKError.Code.unknownItem.rawValue)]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.failures.count == 1 && report.resolvedConflicts == 0 && f.bus.sent.count == 1)
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, 1))
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await finish(f)
    }
    @Test func replayedConflictReceiptDoesNotOverrideAnEditAfterResolution() async throws {
        let f = try await fixture(.cloudWins), id = try await insert(f)
        let batch = try await f.graph.prepareTransport(f.binding)
        let receipt = GraphCloudSentReceipt(batchID: batch.id, graphID: f.graph.id, zone: batch.zone,
            saved: [], deletedNames: [], failures: [failure(try remote(f, id, time: 200))])
        let resolved = try await f.graph.commitTransport(f.binding, receipts: [receipt])
        #expect(resolved.resolved == 1)
        f.clock.set(300); try await change(f, id, 4)
        let replayed = try await f.graph.commitTransport(f.binding, receipts: [receipt])
        #expect(replayed.resolved == 0)
        #expect(try await f.graph.read { try $0.record(for: id) } == record(id, 4))
        #expect(try await date(f.graph, id) == Date(timeIntervalSince1970: 300))
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await finish(f)
    }
    @Test func oldTransportStateIsRefusedUnchanged() async throws {
        let f = try await fixture(), id = try await insert(f)
        _ = try await f.graph.prepareTransport(f.binding)
        let data = try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context -> Data in
                context.userInfo[StoreNativeContext.containerKey] = container
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: id.graphID)
                let raw = try #require(root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] as? Data)
                var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
                json["format"] = 1
                let changed = try JSONSerialization.data(withJSONObject: json)
                root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] = changed
                context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
                try context.save(); return changed
            }
        }
        await #expect(throws: GraphCloudError.invalidState) { try await f.graph.prepareTransport(f.binding) }
        let retained = try await f.graph.read { scope in try scope.withContext { context, _ in
            try GraphTypedStoreAdapter.controlRoot(context, id: id.graphID)[dynamicMember: GraphSyncCheckpointAdapter.transportKey] as? Data
        } }
        #expect(retained == data)
        try await finish(f)
    }

    @Test func splitReceiptsSettleBeforeReplacingTheFrozenAttempt() async throws {
        let f = try await fixture(), id = try await insert(f)
        _ = try await insert(f, value: 9)
        f.bus.splitReceipts = true
        f.bus.script([[failure(try remote(f, id, time: 0))]])
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(report.succeeded == 2 && report.resolvedConflicts == 1 && report.failures.isEmpty)
        #expect(f.bus.sent.count == 2 && f.bus.sent[1].items.map(\.change.id) == [id])
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await finish(f)
    }

}
