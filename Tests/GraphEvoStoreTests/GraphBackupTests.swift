import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime
@testable import GraphEvoModel

private actor BackupArrival {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() { entered = true; let all = waiters; waiters = []; for waiter in all { waiter.resume() } }
    func wait() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
}
private struct BackupValidationGate: Sendable {
    let arrival = BackupArrival()
    let resume = DispatchSemaphore(value: 0)
    func block() throws {
        Task { await arrival.arrive() }
        guard resume.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphBackupTests {
    private func manager() -> GraphContextManager {
        GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func legacyBackup(_ m: GraphContextManager, graph: GraphStore, root: URL,
                              artifacts: [GraphBackupArtifact] = []) async throws -> GraphBackup {
        let package = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"), artifacts: artifacts)
        let restored = try await m.backups.restore(at: package.url, to: root.appendingPathComponent("Legacy"))
        return GraphBackup(url: restored.directory, manifest: restored.manifest)
    }
    @Test(arguments: ["direct", "symlink", "case"]) func rejectedNestedRestorePreservesSourceBackup(alias: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupReview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await legacyBackup(m, graph: graph, root: root)
        let source: URL
        switch alias {
        case "symlink":
            source = root.appendingPathComponent("Alias")
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: backup.url)
        case "case":
            source = backup.url.deletingLastPathComponent().appendingPathComponent(backup.url.lastPathComponent.lowercased())
            if !FileManager.default.fileExists(atPath: source.path) { try await graph.close(); return }
        default: source = backup.url
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: backup.url.path).sorted()
        await #expect(throws: GraphBackupError.invalidDestination) {
            try await m.backups.restore(at: backup.url, to: source.appendingPathComponent("Nested/Restored"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.url.path).sorted() == before)
        #expect(!FileManager.default.fileExists(atPath: backup.url.appendingPathComponent("Nested").path))
        #expect(try await m.backups.verify(at: backup.url).manifest == backup.manifest)
        try await graph.close()
    }

    @Test func observedQueryRecoversAfterCancelledMaintenanceWithoutRefreshOrWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupObservation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let restricted = AsyncStream<Void>.makeStream(), gate = BackupValidationGate()
        let registry = StoreRegistry(hooks: .init(didRestrictWrites: { restricted.continuation.yield(()) }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let observation = try await graph.observe(observationQuery())
        var values = observation.makeAsyncIterator()
        if case .value = await values.next() {} else { Issue.record("Expected initial query snapshot") }
        let reader = Task { try await graph.read { _ in try gate.block() } }
        await gate.arrival.wait()
        let operation = Task { try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups")) }
        var restrictions = restricted.stream.makeAsyncIterator(); _ = await restrictions.next()
        // Force a rescan while admission is restricted; recovery must need no subsequent refresh.
        observation.refresh()
        if case .failure(let error) = await values.next() {
            if case GraphStoreError.resourceReserved = error {} else { Issue.record("Expected maintenance admission error") }
        } else { Issue.record("Expected failed read during maintenance") }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        // Refresh and admission hints can leave more than one expected failure in flight.
        // Require automatic recovery, without assuming the next buffered state is already the value.
        var recovered = false
        recovery: while let state = await values.next() {
            switch state {
            case .value(let result): #expect(result.items.isEmpty); recovered = true; break recovery
            case .failure(let error):
                if case GraphStoreError.resourceReserved = error { continue }
                Issue.record("Unexpected error during maintenance recovery"); break recovery
            }
        }
        #expect(recovered, "Expected automatic recovery after maintenance cancellation")
        observation.cancel(); gate.resume.signal(); try await reader.value
        try await graph.close(); restricted.continuation.finish()
    }

    @Test func completeBackupReasonAndRestorePreserveFilesHistoryAndIndependentContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID()
        let graph = try await m.createGraph(id: id, at: root.appendingPathComponent("Source.sqlite"))
        let node = graph.makeNodeID(), fileID = graph.makeNodeID(), bytes = Data(repeating: 42, count: 2 * 1024 * 1024)
        _ = try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: node, type: "Item", properties: ["value": .integer(1)]))
            return try scope.insert(GraphAttachmentPayload(id: fileID, ownerID: node, fileName: "payload.bin", contentType: "public.data", data: bytes))
        }
        let backup = try await m.createBackup(for: id, in: root.appendingPathComponent("Backups"), reason: "Before repair", artifacts: [.init(name: "journal.json", data: Data("{}".utf8))])
        #expect(backup.manifest.reason == "Before repair")
        #expect(backup.manifest.files.contains { $0.path == "artifacts/journal.json" })
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        _ = try await m.backups.verify(at: backup.url)
        _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: node, properties: ["value": .set(.integer(2))])) }
        let restored = try await m.backups.restore(at: backup.url, to: root.appendingPathComponent("Restored"))
        let peer = manager(), recovered = try await peer.openGraph(id: id, at: restored.storeURL)
        #expect(try await recovered.read { try $0.record(for: node)?.properties["value"] } == .integer(1))
        #expect(try await graph.read { try $0.record(for: node)?.properties["value"] } == .integer(2))
        #expect(try await recovered.attachment(fileID)?.data == bytes)
        #expect(try await recovered.collectSyncChanges() == 2)
        #expect(try await m.cloudSynchronizationState(for: id) == .active)
        let encoded = String(decoding: try JSONEncoder().encode(backup.manifest), as: UTF8.self)
        #expect(!encoded.contains(root.path))
        try await recovered.close(); try await graph.close()
    }
    @Test func overlappingWriteReservationsProtectAllHandlesAndAllowOtherGraphs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let a = try await m.createGraph(id: id, at: url), alias = try await m.openGraph(id: id, at: url)
        let b = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        let first = try await m.suspendLocalWrites(for: id), second = try await m.suspendLocalWrites(for: id)
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        _ = try await alias.read { _ in true }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: b.makeNodeID(), type: "Other")) }
        await first.release(); await first.release()
        try await a.close(); try await alias.close()
        let reopened = try await m.openGraph(id: id, at: url)
        await #expect(throws: (any Error).self) { try await reopened.transaction { _ in () } }
        await second.release()
        _ = try await reopened.transaction { _ in true }
        try await reopened.close(); try await b.close()
    }
    @Test func corruptionPinsAndOccupiedDestinationsNeverReplaceConsumerData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"), reason: "Manual")
        let held = try await m.backups.retain(at: backup.url)
        await #expect(throws: (any Error).self) { try await m.backups.remove(at: backup.url) }
        let another = manager()
        await #expect(throws: (any Error).self) { try await another.backups.remove(at: backup.url) }
        let occupied = root.appendingPathComponent("Keep")
        try Data([1,2,3]).write(to: occupied)
        await #expect(throws: (any Error).self) { try await m.backups.restore(at: backup.url, to: occupied) }
        #expect(try Data(contentsOf: occupied) == Data([1,2,3]))
        var damaged = try Data(contentsOf: backup.url)
        damaged[damaged.count - 1] ^= 0xff
        try damaged.write(to: backup.url)
        await #expect(throws: (any Error).self) { try await m.backups.verify(at: backup.url) }
        await held.release(); try await m.backups.remove(at: backup.url)
        #expect(!FileManager.default.fileExists(atPath: backup.url.path))
        try await graph.close()
    }

    @Test func cancellationDuringValidationPreservesSourceAndConcurrentManualPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BackupValidationGate(), base = GraphCoordinatorFactory.adapter
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            validateBackup: { context, id in try gate.block(); try base.validateBackup?(context, id) }, initialize: base.initialize)
        let m = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
        let graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let other = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Other.sqlite"))
        let operation = Task { try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups")) }
        await gate.arrival.wait()
        _ = try await graph.transaction { _ in true }
        _ = try await other.transaction { _ in true }
        try await m.pauseCloudSynchronization(for: graph.id)
        #expect(try await m.cloudSynchronizationState(for: graph.id) == .paused)
        operation.cancel(); gate.resume.signal()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await m.cloudSynchronizationState(for: graph.id) == .paused)
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        #expect(try await m.backups.discardIncomplete(in: root.appendingPathComponent("Backups")) == 0)
        _ = try await graph.transaction { _ in true }
        try await graph.close(); try await other.close()
    }
    @Test func nativeValidationFindsMissingAttachmentEvenWithRewrittenInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let node = graph.makeNodeID(), file = graph.makeNodeID()
        _ = try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: node, type: "Owner"))
            return try scope.insert(GraphAttachmentPayload(id: file, ownerID: node, fileName: "large.bin", contentType: "public.data", data: Data(repeating: 24, count: 2 * 1024 * 1024)))
        }
        let backup = try await legacyBackup(m, graph: graph, root: root)
        let external = try #require(backup.manifest.files.first { $0.path != backup.manifest.storePath && $0.bytes > 1024 * 1024 })
        try FileManager.default.removeItem(at: backup.url.appendingPathComponent(external.path))
        let path = backup.url.appendingPathComponent("manifest.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        raw["files"] = try #require(raw["files"] as? [[String: Any]]).filter { $0["path"] as? String != external.path }
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        await #expect(throws: (any Error).self) { try await m.backups.verify(at: backup.url) }
        #expect(try await graph.attachment(file)?.data.count == 2 * 1024 * 1024)
        try await graph.close()
    }
    @Test func movedBundlesRestoreAndIncompleteCleanupLeavesForeignFilesAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"), reason: "Before import")
        let movedRoot = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        let moved = movedRoot.appendingPathComponent("Renamed.geb")
        try FileManager.default.moveItem(at: backup.url, to: moved)
        #expect(try await m.backups.verify(at: moved).manifest.reason == "Before import")
        let id = UUID(), stage = movedRoot.appendingPathComponent(".stage-" + id.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let intent: [String: Any] = ["format": 1, "id": id.uuidString, "backupID": id.uuidString]
        try JSONSerialization.data(withJSONObject: intent).write(to: stage.appendingPathComponent("intent.json"))
        try Data([1,2]).write(to: stage.appendingPathComponent("partial.bin"))
        let unknown = movedRoot.appendingPathComponent("consumer.txt"); try Data([3]).write(to: unknown)
        #expect(try await m.backups.discardIncomplete(in: movedRoot) == 1)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try Data(contentsOf: unknown) == Data([3]))
        try await graph.close()
    }
    @Test func backupPreservesAnExistingCloudPauseAndCleansFailedStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        try await m.pauseCloudSynchronization(for: graph.id)
        _ = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        #expect(try await m.cloudSynchronizationState(for: graph.id) == .paused)
        await #expect(throws: (any Error).self) { try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"), reason: " ") }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        #expect(try await m.backups.discardIncomplete(in: root.appendingPathComponent("Backups")) == 0)
        _ = try await graph.transaction { _ in true }
        try await m.resumeCloudSynchronization(for: graph.id); try await graph.close()
    }

    @Test func durableRetentionIsRecoveredByAnotherManagerWithoutALifetimeFileLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backups = root.appendingPathComponent("Backups")
        let backup = try await m.createBackup(for: graph.id, in: backups)
        let owner = UUID(), held = try await m.backups.retain(at: backup.url, owner: owner)
        let other = manager()
        #expect(try await other.backups.retentionOwners(at: backup.url) == [owner])
        // A retained backup does not prevent creation/verification in the same root.
        _ = try await m.createBackup(for: graph.id, in: backups)
        _ = try await other.backups.verify(at: backup.url)
        await #expect(throws: (any Error).self) { try await other.backups.remove(at: backup.url) }
        await held.release()
        let recoveredOwner = UUID()
        let persisted: [String: Any] = ["format": 1, "backupID": backup.manifest.id.uuidString, "owners": [recoveredOwner.uuidString]]
        let marker = backups.appendingPathComponent(".retention-" + backup.manifest.id.uuidString + ".json")
        try JSONSerialization.data(withJSONObject: persisted).write(to: marker, options: .atomic)
        #expect(try await other.backups.retentionOwners(at: backup.url) == [recoveredOwner])
        await #expect(throws: (any Error).self) { try await other.backups.remove(at: backup.url) }
        try await other.backups.releaseRetention(at: backup.url, owner: recoveredOwner)
        try await other.backups.remove(at: backup.url)
        try await graph.close()
    }
    @Test func symlinksAndTraversalArtifactsAreRefusedAndOriginalRemainsWritable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backups = root.appendingPathComponent("Backups")
        await #expect(throws: (any Error).self) {
            try await m.createBackup(for: graph.id, in: backups, artifacts: [.init(name: "../outside.json", data: Data())])
        }
        let backup = try await legacyBackup(m, graph: graph, root: root, artifacts: [.init(name: "journal.json", data: Data([1]))])
        let file = backup.url.appendingPathComponent("artifacts/journal.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("Source.sqlite"))
        await #expect(throws: (any Error).self) { try await m.backups.verify(at: backup.url) }
        _ = try await graph.transaction { _ in true }
        #expect(try await m.cloudSynchronizationState(for: graph.id) == .active)
        try await graph.close()
    }


    @Test func cloudRecoveryEvidenceIsGraphScopedAndNeverRewindsSharedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let b = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.backup.\(UUID())", environment: .development, directory: root.appendingPathComponent("Engine"))
        let fake = GraphCloudAdapter(account: { _ in "backup-account" }, make: { _, _, _, _ in GraphCloudDriver(fetch: { _ in }, cancel: {}) })
        _ = try await m.startCloudSession(config, adapter: fake)
        let aZone = GraphCloudZone(scope: .private, owner: "owner", name: "A"), bZone = GraphCloudZone(scope: .private, owner: "owner", name: "B")
        try await m.bindCloudZone(aZone, to: graph.id, configuration: config)
        try await m.bindCloudZone(bZone, to: b.id, configuration: config)
        let session = try await m.cloud(config)
        await session.receive(.incoming([.init(kind: .zoneChanged, zone: aZone), .init(kind: .zoneChanged, zone: bZone)]), scope: .private)
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        let evidence = try #require(backup.manifest.files.first { $0.path.hasSuffix("__graphevo_cloud_0.json") })
        let materialized = try await m.backups.restore(at: backup.url, to: root.appendingPathComponent("Evidence"))
        let data = try Data(contentsOf: materialized.directory.appendingPathComponent(evidence.path))
        let snapshot = try JSONDecoder().decode(GraphCloudBackupSnapshot.self, from: data)
        #expect(snapshot.binding?.graphID == graph.id && snapshot.inbox.count == 1)
        #expect(snapshot.inbox.allSatisfy { $0.change.zone == aZone })
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["states"] == nil)
        _ = try await m.backups.restore(at: backup.url, to: root.appendingPathComponent("Restored"))
        #expect(try await m.cloudStatus(config).inboxCount == 2)
        #expect(try await m.cloudBinding(for: bZone, configuration: config)?.graphID == b.id)
        try await graph.close(); try await b.close(); try await m.stopCloudSession(config)
    }


    @Test func changedManifestIdentityCannotBypassRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await legacyBackup(m, graph: graph, root: root)
        let held = try await m.backups.retain(at: backup.url)
        let path = backup.url.appendingPathComponent("manifest.json"), saved = try Data(contentsOf: path)
        var raw = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        raw["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        await #expect(throws: (any Error).self) { try await m.backups.remove(at: backup.url) }
        #expect(FileManager.default.fileExists(atPath: backup.url.appendingPathComponent(backup.manifest.storePath).path))
        try saved.write(to: path)
        await held.release(); try await graph.close()
    }


    @Test func participantAliasesCanOpenAndNestReservationsWhileWritesAreSuspended() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID(), url = root.appendingPathComponent("Participant.sqlite")
        let graph = try await m.createGraph(id: id, at: url)
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.backup.\(UUID())", environment: .development, directory: root.appendingPathComponent("Engine"))
        let fake = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, _, _ in throw GraphCloudSharingError.ownerRequired },
            accept: { _, _, _ in .readOnly }), account: { _ in "participant" },
            make: { _, _, _, _ in GraphCloudDriver(fetch: { _ in }, cancel: {}) })
        _ = try await m.startCloudSession(config, adapter: fake)
        let invite = GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment, graphID: id,
            owner: "owner", zoneName: "A", recipient: "participant", url: URL(string: "https://www.icloud.com/share/A")!)
        try await m.acceptCloudInvitation(invite, configuration: config)
        let first = try await m.suspendLocalWrites(for: id)
        let alias = try await m.openGraph(id: id, at: url)
        let second = try await m.suspendLocalWrites(for: id)
        _ = try await alias.read { _ in true }
        await first.release(); await second.release()
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        _ = try await graph.read { _ in true }
        try await alias.close(); try await graph.close(); try await m.stopCloudSession(config)
        let unverified = manager()
        let fenced = try await unverified.openGraph(id: id, at: url)
        await #expect(throws: (any Error).self) {
            try await unverified.createBackup(for: id, in: root.appendingPathComponent("Refused"))
        }
        #expect(try await unverified.backups.list(in: root.appendingPathComponent("Refused")).isEmpty)
        try await fenced.close()
    }

}
