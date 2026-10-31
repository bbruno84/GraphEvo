import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor AssetSignal {
    private var open = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { continuations.append($0) } } }
    func release() { open = true; let values = continuations; continuations = []; for value in values { value.resume() } }
}

/// Materializes real CKAssets through the native provider, without emulating server CAS.
@available(iOS 17, macOS 14, *)
private actor AssetBus {
    var records: [String: GraphCloudIncoming] = [:]
    var fetches = 0
    private var conflict: GraphCloudIncoming?
    func failNext(_ server: GraphCloudIncoming) { conflict = server }
    var gate: AssetSignal?
    var entered: AssetSignal?
    func pause(_ gate: AssetSignal, entered: AssetSignal) { self.gate = gate; self.entered = entered }
    func fetch(_ zones: [GraphCloudZone]) async -> [GraphCloudIncoming] {
        fetches += 1
        await entered?.release()
        await gate?.wait()
        return records.values.filter { zones.contains($0.zone) }
    }
    func inject(_ change: GraphCloudIncoming) { records[change.recordName!] = change }
    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        let provider = GraphCloudNativeOutbox()
        try await provider.begin(batch)
        do {
            let zone = CKRecordZone.ID(zoneName: batch.zone.name, ownerName: batch.zone.owner)
            let offered = try #require(try await provider.next(.init(scope: .zoneIDs([zone]))))
            var saved: [GraphCloudIncoming] = [], failures: [GraphCloudRecordFailure] = []
            for record in offered.recordsToSave {
                if let server = conflict, server.recordName == record.recordID.recordName {
                    conflict = nil
                    failures.append(.init(recordName: record.recordID.recordName, code: CKError.Code.serverRecordChanged.rawValue, serverRecord: server))
                } else { saved.append(try GraphCloudRecordCodec.archive(record, scope: batch.zone.scope)) }
            }
            for item in saved { records[item.recordName!] = item }
            for id in offered.recordIDsToDelete {
                records[id.recordName] = .init(kind: .recordDeleted, zone: batch.zone, recordName: id.recordName, recordType: GraphCloudNodeCodec.recordType)
            }
            try await provider.finish()
            return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved,
                         deletedNames: offered.recordIDsToDelete.map(\.recordName), failures: failures)
        } catch { try? await provider.finish(); throw error }
    }
    nonisolated var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "asset-account" }, make: { [self] _, _, _, receive in
            GraphCloudDriver(fetch: { zones in await receive(.incoming(self.fetch(zones))) }, cancel: {},
                             send: { batch in await receive(.sent(try self.send(batch))) })
        })
    }
}

@Suite(.timeLimit(.minutes(3))) struct GraphCloudAssetTests {
    private struct Fixture {
        let directory: URL
        let graph: GraphStore
        let manager: GraphContextManager
        let config: GraphCloudConfiguration
        let binding: GraphCloudBinding
    }
    @available(iOS 17, macOS 14, *)
    private func fixture(_ bus: AssetBus, container: String = UUID().uuidString, id: GraphID = GraphID()) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssetTests-" + UUID().uuidString)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: id, at: directory.appendingPathComponent("Graph.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.asset." + container, environment: .development, directory: directory.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "graph")
        try await manager.bindCloudZone(zone, to: id, configuration: config)
        return Fixture(directory: directory, graph: graph, manager: manager, config: config, binding: .init(zone: zone, graphID: id))
    }
    private func close(_ f: Fixture) async throws {
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
        try FileManager.default.removeItem(at: f.directory)
    }
    private func seed(_ f: Fixture, count: Int = 512, legacy: Bool = false) async throws -> GraphAttachmentContent {
        let owner = f.graph.makeNodeID(), id = f.graph.makeNodeID()
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "photo.bin", contentType: "public.data", data: Data(repeating: 7, count: count))
        let record = try payload.graphRecord(legacy: legacy)
        try await f.graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: "Document"))
            try scope.insert(record)
        }
        return payload.content
    }
    @available(iOS 17, macOS 14, *)
    @Test(arguments: [0, 512, GraphAttachmentPayload.maximumByteCount])
    func assetRoundTripAndEmptyReplicaHaveExactBytes(_ count: Int) async throws {
        let bus = AssetBus(), container = UUID().uuidString, id = GraphID()
        let owner = try await fixture(bus, container: container, id: id)
        let expected = try await seed(owner, count: count)
        let report = try await owner.manager.sendCloudChanges(for: id, configuration: owner.config)
        #expect(report.succeeded == 2 && report.failures.isEmpty)
        try await owner.manager.stopCloudSession(owner.config)
        let peer = try await fixture(bus, container: container, id: id)
        let destination = peer.directory.appendingPathComponent("download.bin")
        let metadata = try await peer.manager.exportCloudAttachment(expected.metadata.id, to: destination, configuration: peer.config)
        let exported = try Data(contentsOf: destination)
        #expect(metadata == expected.metadata && exported == expected.data)
        #expect(try await peer.graph.attachment(expected.metadata.id) == expected)
        #expect(try await peer.graph.collectSyncChanges() == 0)
        let fetches = await bus.fetches
        _ = try await peer.manager.exportCloudAttachment(expected.metadata.id, to: peer.directory.appendingPathComponent("copy.bin"), configuration: peer.config)
        #expect(await bus.fetches == fetches)
        try await close(peer); try await close(owner)
    }
    @available(iOS 17, macOS 14, *)
    @Test(arguments: [false, true])
    func replacementAndOwnerCascadeStayAtomic(_ legacy: Bool) async throws {
        let bus = AssetBus(), container = UUID().uuidString, id = GraphID()
        let a = try await fixture(bus, container: container, id: id), expected = try await seed(a, legacy: legacy)
        _ = try await a.manager.sendCloudChanges(for: id, configuration: a.config)
        let source = a.directory.appendingPathComponent("replacement.bin"), data = Data(repeating: 9, count: 2048)
        try data.write(to: source)
        let updated = try await a.graph.replaceAttachment(expected.metadata.id, from: source)
        _ = try await a.manager.sendCloudChanges(for: id, configuration: a.config)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus, container: container, id: id)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: id, configuration: b.config)
        let imported = try #require(try await b.graph.attachment(updated.id))
        #expect(imported.metadata == updated && imported.data == data)
        #expect(try await b.graph.read { try $0.record(for: updated.id)?.properties[GraphAttachmentPayload.metadataKey] == nil } == legacy)
        try await b.graph.delete(updated.ownerID)
        #expect(try await b.graph.attachment(updated.id) == nil)
        #expect(try await b.graph.collectSyncChanges() == 2)
        try await close(b); try await close(a)
    }
    @available(iOS 17, macOS 14, *)
    @Test func nativeAssetsBecomePortableBeforeStagingDisappears() throws {
        let graphID = GraphID(), ownerID = GraphNodeID(graphID: graphID), nodeID = GraphNodeID(graphID: graphID)
        let route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: graphID)
        let payload = try GraphAttachmentPayload(id: nodeID, ownerID: ownerID, fileName: "data", contentType: "public.data", data: Data([1,2,3]))
        let native = try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: route)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssetPortable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try GraphCloudAsset.materialize(native, directory: directory)
        #expect(native["asset"] is CKAsset)
        let incoming = try GraphCloudRecordCodec.archive(native, scope: .private)
        try FileManager.default.removeItem(at: directory)
        try GraphCloudRecordCodec.validate(incoming)
        guard case .save(let decoded) = try GraphCloudNodeCodec.decode(incoming, binding: route) else { Issue.record("Missing save"); return }
        #expect(try GraphAttachmentPayload(graphRecord: decoded.record).content == payload.content)
        #expect(incoming.recordArchive?.range(of: Data(directory.path.utf8)) == nil)
    }
    @available(iOS 17, macOS 14, *)
    @Test func sharedWaitCancellationTimeoutAndLocalWritesRemainIndependent() async throws {
        let bus = AssetBus(), container = UUID().uuidString, id = GraphID()
        let a = try await fixture(bus, container: container, id: id), content = try await seed(a)
        _ = try await a.manager.sendCloudChanges(for: id, configuration: a.config)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus, container: container, id: id)
        let gate = AssetSignal(), entered = AssetSignal()
        await bus.pause(gate, entered: entered)
        let cancelled = b.directory.appendingPathComponent("cancelled.bin")
        let first = Task { try await b.manager.exportCloudAttachment(content.metadata.id, to: cancelled, configuration: b.config) }
        await entered.wait()
        let local = b.graph.makeNodeID()
        _ = try await b.graph.transaction { try $0.insert(GraphRecord(id: local, type: "Independent")) }
        let destination = b.directory.appendingPathComponent("complete.bin")
        let second = Task { try await b.manager.exportCloudAttachment(content.metadata.id, to: destination, configuration: b.config) }
        // Prove both callers joined the held refresh before cancelling/releasing either wait.
        // Merely constructing a Task does not establish overlap on a loaded simulator.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while await b.manager.attachmentRefreshWaiterCount < 2 {
            guard ContinuousClock.now < deadline else { await gate.release(); throw GraphCloudError.invalidState }
            try await Task.sleep(for: .milliseconds(1))
        }
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled wait returned content") } catch is CancellationError { }
        do {
            _ = try await b.manager.exportCloudAttachment(content.metadata.id, to: b.directory.appendingPathComponent("timeout.bin"), configuration: b.config, timeout: .milliseconds(30))
            Issue.record("Wait did not expire")
        } catch GraphCloudError.attachmentTimeout { }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        await gate.release()
        #expect(try await second.value == content.metadata)
        #expect(try Data(contentsOf: destination) == content.data)
        #expect(await bus.fetches == 1)
        #expect(try await b.graph.read { try $0.record(for: local) } != nil)
        try await close(b); try await close(a)
    }
    @available(iOS 17, macOS 14, *)
    @Test func corruptedAssetRetainsOldContentAndInbox() async throws {
        let bus = AssetBus(), container = UUID().uuidString, id = GraphID()
        let a = try await fixture(bus, container: container, id: id), expected = try await seed(a)
        _ = try await a.manager.sendCloudChanges(for: id, configuration: a.config)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus, container: container, id: id)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: id, configuration: b.config)
        let record = try #require(try await a.graph.read { try $0.record(for: expected.metadata.id) })
        let native = try GraphCloudNodeCodec.encode(record, binding: b.binding)
        native["asset"] = Data([0]) as CKRecordValue
        let corrupt = try GraphCloudRecordCodec.archive(native, scope: .private, portableAsset: true)
        await bus.inject(corrupt)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        await #expect(throws: (any Error).self) { try await b.manager.applyCloudInbox(for: id, configuration: b.config) }
        #expect(try await b.graph.attachment(expected.metadata.id) == expected)
        #expect(try await b.manager.cloudStatus(b.config).inboxCount > 0)
        #expect(try await b.graph.collectSyncChanges() == 0)
        try await close(b); try await close(a)
    }

    @available(iOS 17, macOS 14, *)
    @Test(arguments: [GraphConflictPolicy.cloudWins, .lastEditWins])
    func conflictSelectsOneCompleteAttachmentRevision(_ policy: GraphConflictPolicy) async throws {
        let bus = AssetBus(), f = try await fixture(bus), original = try await seed(f)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        try await f.graph.setConflictPolicy(policy)
        let payload = try GraphAttachmentPayload(id: original.metadata.id, ownerID: original.metadata.ownerID,
            fileName: "remote.bin", contentType: "public.data", data: Data([9,8,7]))
        let native = try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: f.binding, modifiedAt: .distantPast)
        await bus.failNext(try GraphCloudRecordCodec.archive(native, scope: .private, portableAsset: true))
        let patch = try GraphRecordPatch(id: original.metadata.id, addingTags: ["local"])
        _ = try await f.graph.transaction { try $0.patch(patch) }
        let report = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        let result = try await f.graph.attachment(original.metadata.id)
        #expect(result == (policy == .cloudWins ? payload.content : original))
        #expect(report.resolvedConflicts == 1 && report.failures.isEmpty && !report.pendingRetry)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await close(f)
    }
    @available(iOS 17, macOS 14, *)
    @Test func attachmentOwnedByAnEdgeImportsAfterItsOwner() async throws {
        let bus = AssetBus(), container = UUID().uuidString, graphID = GraphID()
        let a = try await fixture(bus, container: container, id: graphID)
        let first = a.graph.makeNodeID(), second = a.graph.makeNodeID(), edge = a.graph.makeNodeID()
        let file = GraphNodeID(graphID: graphID, rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let payload = try GraphAttachmentPayload(id: file, ownerID: edge, fileName: "edge.bin", contentType: "public.data", data: Data([1,2]))
        let record = try payload.graphRecord()
        try await a.graph.transaction {
            try $0.insert(GraphRecord(id: first, type: "Item"))
            try $0.insert(GraphRecord(id: second, type: "Item"))
            try $0.insert(GraphRecord(id: edge, type: "links", endpoints: .relationship(subject: first, object: second)))
            try $0.insert(record)
        }
        _ = try await a.manager.sendCloudChanges(for: graphID, configuration: a.config)
        try await a.manager.stopCloudSession(a.config)
        let b = try await fixture(bus, container: container, id: graphID)
        try await b.manager.fetchCloudChanges(.private, configuration: b.config)
        _ = try await b.manager.applyCloudInbox(for: graphID, configuration: b.config)
        #expect(try await b.graph.attachment(file) == payload.content)
        #expect(try await b.graph.collectSyncChanges() == 0)
        try await close(b); try await close(a)
    }

    @available(iOS 17, macOS 14, *)
    @Test func conflictAssetsAreFetchedBeforePortableReceiptPublication() async throws {
        let id = GraphID(), route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: id)
        let payload = try GraphAttachmentPayload(id: .init(graphID: id), ownerID: .init(graphID: id), fileName: "photo", contentType: "public.data", data: Data([4,5,6]))
        let record = try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: route)
        // A reference without usable content stands for the SDK's unmaterialized conflict asset.
        record["asset"] = CKAsset(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let originalID = record.recordID
        let complete = try await GraphCloudAsset.completeConflict(record) { requested in
            #expect(requested == originalID)
            return try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: route)
        }
        #expect(try GraphCloudNodeCodec.decode(complete, binding: route).record == payload.graphRecord())
        await #expect(throws: GraphCloudError.invalidState) {
            _ = try await GraphCloudAsset.completeConflict(record) { _ in CKRecord(recordType: "Wrong") }
        }
        await #expect(throws: CKError.self) {
            _ = try await GraphCloudAsset.completeConflict(record) { _ in throw CKError(.unknownItem) }
        }
    }

    @available(iOS 17, macOS 14, *)
    @Test func frozenAssetArchivesNeverFollowPersistedSDKPaths() async throws {
        let id = GraphID(), route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: id)
        let payload = try GraphAttachmentPayload(id: .init(graphID: id), ownerID: .init(graphID: id), fileName: "photo", contentType: "public.data", data: Data([1]))
        let native = try GraphCloudNodeCodec.encode(payload.graphRecord(), binding: route)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersistedAssetPath-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GraphCloudAsset.materialize(native, directory: directory)
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: native, requiringSecureCoding: true)
        #expect(throws: GraphCloudError.unsupportedAsset) { try GraphCloudRecordCodec.restore(bytes) }
        let change = GraphSyncChange(id: payload.id, nativeKind: "ManagedEntity", operation: .save, generation: 1)
        let item = GraphCloudOutgoingNode(change: change, recordName: native.recordID.recordName, recordArchive: bytes)
        let outbox = GraphCloudNativeOutbox()
        try await outbox.begin(.init(id: UUID(), graphID: id, zone: route.zone, items: [item]))
        await #expect(throws: GraphCloudError.unsupportedAsset) {
            _ = try await outbox.next(.init(scope: .zoneIDs([native.recordID.zoneID])))
        }
        try await outbox.finish()
    }

}
