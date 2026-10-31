import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoModel
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor LifecycleCloud {
    let account: String
    var permission: GraphCloudSharePermission? = .readWrite
    var inspectionError: (any Error)?
    var removedZones = Set<String>()
    var commandError: (any Error)?
    var commands: [GraphCloudShareCommand] = []
    var callbacks: [GraphCloudScope: [@Sendable (GraphCloudEvent) async -> Void]] = [:]
    var restored: [GraphCloudScope: [Data?]] = [:]
    var incoming: [GraphCloudIncoming] = []
    init(account: String = "participant") { self.account = account }
    func setPermission(_ value: GraphCloudSharePermission?) { permission = value; removedZones.removeAll() }
    func failInspection(_ error: (any Error)?) { inspectionError = error }
    func failCommand(_ error: (any Error)?) { commandError = error }
    func queue(_ events: [GraphCloudIncoming]) { incoming = events }
    func register(_ scope: GraphCloudScope, state: Data?, receive: @escaping @Sendable (GraphCloudEvent) async -> Void) {
        callbacks[scope, default: []].append(receive); restored[scope, default: []].append(state)
    }
    func late(_ event: GraphCloudEvent, scope: GraphCloudScope) async { await callbacks[scope]?.first?(event) }
    func inspect(_ binding: GraphCloudBinding) throws -> GraphCloudShareSnapshot? {
        if let inspectionError { throw inspectionError }
        guard let permission, !removedZones.contains(binding.zone.name) else { return nil }
        return .init(identity: GraphCloudShareIdentity.of(URL(string: "https://www.icloud.com/share/" + binding.zone.name)!),
            role: binding.zone.scope == .private ? .owner : .participant, permission: permission,
            participants: [.init(identity: account, permission: .readWrite, accepted: true, owner: true),
                           .init(identity: "guest", permission: permission, accepted: true, owner: false)])
    }
    func execute(_ command: GraphCloudShareCommand, zone: String) throws {
        commands.append(command)
        if let commandError { throw commandError }
        switch command { case .leave, .stop: removedZones.insert(zone); case .permission(_, let value): permission = value; case .remove: break }
    }
    func fetch(_ receive: @Sendable (GraphCloudEvent) async -> Void) async {
        let values = incoming; incoming.removeAll()
        if !values.isEmpty { await receive(.incoming(values)) }
    }
    nonisolated var adapter: GraphCloudAdapter {
        GraphCloudAdapter(sharing: .init(operations: .init(inspect: { [self] _, binding, _ in try await inspect(binding) },
            execute: { [self] _, binding, _, intent in try await execute(intent.command, zone: binding.zone.name) }), invite: { config, binding, account, recipient, _, create, beforeCreate in
                if create { try await beforeCreate() }
                return GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
                    graphID: binding.graphID, owner: account, zoneName: binding.zone.name, recipient: recipient,
                    url: URL(string: "https://www.icloud.com/share/" + binding.zone.name)!)
            }, accept: { [self] _, _, _ in await permission ?? .readWrite }), account: { [self] _ in account }, make: { [self] _, scope, state, receive in
                Task { await register(scope, state: state, receive: receive) }
                return GraphCloudDriver(fetch: { [self] _ in await fetch(receive) }, cancel: {}, send: { batch in
                    let saved = batch.items.compactMap { item -> GraphCloudIncoming? in
                        guard let data = item.recordArchive else { return nil }
                        return .init(kind: .recordChanged, zone: batch.zone, recordName: item.recordName,
                                     recordType: GraphCloudNodeCodec.recordType, recordArchive: data)
                    }
                    await receive(.sent(.init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone,
                        saved: saved, deletedNames: batch.items.filter { $0.change.operation == .delete }.map(\.recordName), failures: [])))
                })
            })
    }
}
private actor RemovalGate {
    var arrived = false
    var open = false
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var waits: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        arrived = true; let values = arrivals; arrivals.removeAll(); for value in values { value.resume() }
        if !open { await withCheckedContinuation { waits.append($0) } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { open = true; let values = waits; waits.removeAll(); for value in values { value.resume() } }
}
@Suite(.timeLimit(.minutes(2))) struct GraphSharingLifecycleTests {
    private struct Fixture: Sendable {
        let root: URL
        let url: URL
        let config: GraphCloudConfiguration
        let manager: GraphContextManager
        let cloud: LifecycleCloud
        let graph: GraphStore
        let invitation: GraphCloudInvitation
    }
    private func fixture(registry: StoreRegistry = StoreRegistry(), disk: GraphCloudDisk = .live) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lifecycle-\(UUID())")
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.lifecycle.\(UUID())", environment: .development, directory: root.appendingPathComponent("Engine"))
        let manager = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let cloud = LifecycleCloud(), id = GraphID(), url = root.appendingPathComponent("Graph.sqlite")
        let graph = try await manager.createGraph(id: id, at: url)
        _ = try await manager.startCloudSession(config, adapter: cloud.adapter, disk: disk)
        let invitation = GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment, graphID: id,
            owner: "owner", zoneName: "A", recipient: "participant", url: URL(string: "https://www.icloud.com/share/A")!)
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        return Fixture(root: root, url: url, config: config, manager: manager, cloud: cloud, graph: graph, invitation: invitation)
    }
    private func waitRemoved(_ f: Fixture) async throws {
        try await f.manager.registerCloudGraphLocation(f.graph.id, at: f.url, configuration: f.config)
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .removed)
    }
    @Test func leaveRemovesPendingDataFilesAndAllAliasesButNotConsumerExports() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let alias = try await f.manager.openGraph(id: f.graph.id, at: f.url), id = f.graph.makeNodeID()
        let observation = try await alias.observe(observationQuery())
        _ = try await waitForObservation(observation) { _ in true }
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Note", properties: ["value": .integer(1)])) }
        let file = try GraphAttachmentPayload(id: f.graph.makeNodeID(), ownerID: id, fileName: "file.bin", contentType: "public.data", data: Data(repeating: 42, count: 2 * 1024 * 1024))
        _ = try await f.graph.transaction { try $0.insert(file) }
        let exported = f.root.appendingPathComponent("consumer-export.bin")
        try Data([1,2,3]).write(to: exported)
        #expect(try await f.graph.collectSyncChanges() == 2)
        let status = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        #expect(status.phase == .removed && !status.remoteOperationPending && status.reason == .left)
        let diagnostic = "Remaining files: \(try FileManager.default.contentsOfDirectory(atPath: f.root.path)), attributes: \(String(describing: try? FileManager.default.attributesOfItem(atPath: f.url.path)))"
        #expect(!FileManager.default.fileExists(atPath: f.url.path), Comment(rawValue: diagnostic))
        #expect(try Data(contentsOf: exported) == Data([1,2,3]))
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(Set(files) == ["Engine", "consumer-export.bin"])
        await #expect(throws: (any Error).self) { try await alias.read { _ in () } }
        var changes = observation.makeAsyncIterator()
        while await changes.next() != nil {}
        try await alias.close(); try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func confirmedRevocationWinsOverPendingWritesEvenWhilePaused() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: f.graph.makeNodeID(), type: "Pending")) }
        try await f.manager.pauseCloudSynchronization(for: f.graph.id)
        await f.cloud.setPermission(nil)
        await #expect(throws: GraphCloudError.zoneUnavailable) { try await f.manager.refreshCloudSharing(for: f.graph.id, configuration: f.config) }
        try await waitRemoved(f)
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).reason == .accessLost)
        #expect(await f.cloud.commands.isEmpty)
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func networkOrQuotaFailureDoesNotPurgeAndPreservesLocalWrites() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.cloud.failInspection(CKError(.networkUnavailable))
        await #expect(throws: CKError.self) { try await f.manager.refreshCloudSharing(for: f.graph.id, configuration: f.config) }
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .accessUnverified)
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: f.graph.makeNodeID(), type: "Offline")) }
        await f.cloud.failInspection(CKError(.quotaExceeded))
        await #expect(throws: CKError.self) { try await f.manager.refreshCloudSharing(for: f.graph.id, configuration: f.config) }
        #expect(FileManager.default.fileExists(atPath: f.url.path))
        await f.cloud.failInspection(nil)
        _ = try await f.manager.refreshCloudSharing(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func offlineLeavePersistsRemoteCommandAcrossRestartAndRejectsRejoin() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.cloud.failCommand(CKError(.networkUnavailable))
        let status = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        #expect(status.phase == .removed && status.remoteOperationPending)
        await #expect(throws: GraphCloudError.busy) {
            try await f.manager.acceptCloudInvitation(f.invitation, at: f.root.appendingPathComponent("new.sqlite"), configuration: f.config)
        }
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
        _ = try await f.manager.startCloudSession(f.config, adapter: f.cloud.adapter)
        await f.cloud.failCommand(nil)
        let recovered = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        #expect(!recovered.remoteOperationPending)
        try await f.manager.stopCloudSession(f.config)
    }
    @Test func newInvitationUsesEmptyStoreNewGenerationAndRejectsLateEngineEvents() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let oldGeneration = try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).generation
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: f.graph.makeNodeID(), type: "Discarded")) }
        _ = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        await f.cloud.setPermission(.readWrite)
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .removed)
        let fresh = try await f.manager.acceptCloudInvitation(f.invitation, at: f.root.appendingPathComponent("New.sqlite"), configuration: f.config)
        let newGeneration = try await f.manager.cloudSharingStatus(for: fresh.id, configuration: f.config).generation
        #expect(newGeneration != oldGeneration)
        #expect(try await fresh.collectSyncChanges() == 0)
        await f.cloud.late(.incoming([.init(kind: .zoneDeleted, zone: f.invitation.zone)]), scope: .shared)
        #expect(try await f.manager.cloudInbox(f.config).isEmpty)
        await #expect(throws: (any Error).self) { try await f.graph.read { _ in () } }
        #expect(await f.cloud.restored[.shared]?.count == 2)
        try await fresh.close(); try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func purgeDrainsAdmittedNativeWorkAndRejectsNewReads() async throws {
        let f = try await fixture(), gate = RemovalGate()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let admitted = Task { try await f.graph.nativeOperation { _ in await gate.enter() } }
        await gate.wait()
        let leave = Task { try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config) }
        while try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .active { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: f.url.path))
        await gate.release(); try await admitted.value
        #expect(try await leave.value.phase == .removed)
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    private actor FailureOnce {
        var remaining = 1
        func fail() throws { if remaining > 0 { remaining -= 1; throw GraphCloudError.persistence } }
    }
    @Test(arguments: [false, true]) func failedNativeDestructionRetainsClaimsAndCanResume(_ after: Bool) async throws {
        let failure = FailureOnce()
        var hooks = StoreLifecycleHooks()
        if after { hooks.didDestroy = { try await failure.fail() } }
        else { hooks.beforeDestroy = { try await failure.fail() } }
        let registry = StoreRegistry(hooks: hooks), f = try await fixture(registry: registry)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: (any Error).self) { try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config) }
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .purging)
        let other = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        if !after { await #expect(throws: (any Error).self) { try await other.openGraph(id: f.graph.id, at: f.url) } }
        await #expect(throws: (any Error).self) { try await f.graph.read { _ in () } }
        let recovered = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        #expect(recovered.phase == .removed && !FileManager.default.fileExists(atPath: f.url.path))
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func restartAfterDestructionBeforeJournalCompletionUsesRegisteredCurrentURL() async throws {
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, data in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: data)
            if doc.memberships.contains(where: { $0.phase == .removed }) { throw GraphCloudError.persistence }
            try GraphCloudDisk.live.write(url, data)
        })
        let f = try await fixture(disk: disk)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: GraphCloudError.persistence) { try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config) }
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
        let restarted = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await restarted.startCloudSession(f.config, adapter: f.cloud.adapter)
        try await restarted.registerCloudGraphLocation(f.graph.id, at: f.url, configuration: f.config)
        #expect(try await restarted.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .removed)
        _ = try await restarted.leaveCloudShare(for: f.graph.id, configuration: f.config)
        try await restarted.stopCloudSession(f.config)
    }
    @Test func downgradeKeepsPendingUploadsButImportsOtherRemoteRecordsAndCanUpgrade() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pendingID = f.graph.makeNodeID(), remoteID = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: pendingID, type: "Pending")) }
        await f.cloud.setPermission(.readOnly)
        _ = try await f.manager.refreshCloudSharing(for: f.graph.id, configuration: f.config)
        await #expect(throws: (any Error).self) { try await f.graph.transaction { _ in () } }
        let record = try GraphRecord(id: remoteID, type: "Remote")
        let native = try GraphCloudNodeCodec.encode(record, binding: .init(zone: f.invitation.zone, graphID: f.graph.id))
        await f.cloud.queue([try GraphCloudRecordCodec.archive(native, scope: .shared)])
        try await f.manager.fetchCloudChanges(.shared, configuration: f.config)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.read { try $0.record(for: remoteID) } == record)
        #expect(try await f.graph.collectSyncChanges() == 1)
        await f.cloud.setPermission(.readWrite)
        _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    @Test func ownerCommandsKeepPrivateDataAndAreRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LifecycleOwner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.owner.\(UUID())", environment: .development, directory: root.appendingPathComponent("Engine"))
        let cloud = LifecycleCloud(account: "owner"), id = GraphID()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: id, at: root.appendingPathComponent("Private.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: cloud.adapter)
        try await manager.bindCloudZone(.init(scope: .private, owner: CKCurrentUserDefaultName, name: "A"), to: id, configuration: config)
        _ = try await manager.inviteCloudParticipant("guest", to: id, configuration: config)
        #expect(try await manager.cloudParticipants(for: id, configuration: config).count == 2)
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: graph.makeNodeID(), type: "Private")) }
        await cloud.failCommand(CKError(.networkUnavailable))
        let pending = try await manager.setCloudParticipantPermission(.readOnly, participant: "guest", for: id, configuration: config)
        #expect(pending.remoteOperationPending)
        await cloud.failCommand(nil)
        #expect(try await manager.setCloudParticipantPermission(.readOnly, participant: "guest", for: id, configuration: config).remoteOperationPending == false)
        _ = try await manager.removeCloudParticipant("guest", from: id, configuration: config)
        _ = try await manager.stopCloudSharing(for: id, configuration: config)
        #expect(try await graph.collectSyncChanges() == 1)
        try await graph.transaction { _ in () }
        try await graph.close(); try await manager.stopCloudSession(config)
    }
    @Test func sharedEngineReplacementPreservesOtherGraphsAndTheirPendingWork() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bID = GraphID(), b = try await f.manager.createGraph(id: bID, at: f.root.appendingPathComponent("B.sqlite"))
        let invite = GraphCloudInvitation(container: f.config.containerIdentifier, environment: f.config.environment, graphID: bID,
            owner: "owner", zoneName: "B", recipient: "participant", url: URL(string: "https://www.icloud.com/share/B")!)
        try await f.manager.acceptCloudInvitation(invite, configuration: f.config)
        let pending = b.makeNodeID()
        _ = try await b.transaction { try $0.insert(GraphRecord(id: pending, type: "Preserved")) }
        _ = try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config)
        await f.cloud.setPermission(.readWrite)
        let fresh = try await f.manager.acceptCloudInvitation(f.invitation, at: f.root.appendingPathComponent("Fresh.sqlite"), configuration: f.config)
        #expect(try await b.collectSyncChanges() == 1)
        #expect(try await b.read { try $0.record(for: pending) } != nil)
        _ = try await f.manager.sendCloudChanges(for: bID, configuration: f.config)
        #expect(try await b.collectSyncChanges() == 0)
        try await b.close(); try await fresh.close(); try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }

    @Test func currentURLRegistrationAcceptsMovedStoreWithoutPersistedPaths() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Moved")) }
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
        let moved = f.root.appendingPathComponent("Current.sqlite")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: f.url.path + suffix) {
            try FileManager.default.moveItem(atPath: f.url.path + suffix, toPath: moved.path + suffix)
        }
        let restarted = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        _ = try await restarted.startCloudSession(f.config, adapter: f.cloud.adapter)
        try await restarted.registerCloudGraphLocation(f.graph.id, at: moved, configuration: f.config)
        let graph = try await restarted.openGraph(id: f.graph.id, at: moved)
        #expect(try await graph.read { try $0.record(for: id)?.type } == "Moved")
        #expect(try await restarted.leaveCloudShare(for: graph.id, configuration: f.config).phase == .removed)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        try await graph.close(); try await restarted.stopCloudSession(f.config)
    }
    @Test func wrongStoreRegistrationCannotClaimOrDestroyUnrelatedGraph() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.graph.close()
        let other = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let url = f.root.appendingPathComponent("Unrelated.sqlite"), otherID = GraphID()
        let foreign = try await other.createGraph(id: otherID, at: url), nodeID = foreign.makeNodeID()
        _ = try await foreign.transaction { try $0.insert(GraphRecord(id: nodeID, type: "Unrelated")) }
        try await foreign.close()
        await #expect(throws: GraphCloudError.ownershipConflict) {
            try await f.manager.registerCloudGraphLocation(f.graph.id, at: url, configuration: f.config)
        }
        let retained = try await other.openGraph(id: otherID, at: url)
        #expect(try await retained.read { try $0.record(for: nodeID)?.type } == "Unrelated")
        try await retained.close(); try await f.manager.stopCloudSession(f.config)
    }

    #if DEBUG
    @Test func stopDrainsAlreadyStartedPurgeBeforeReleasingSession() async throws {
        let f = try await fixture(), gate = RemovalGate()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.manager.setPurgeProbeBarrier { _ in await gate.enter() }
        let leave = Task { try await f.manager.leaveCloudShare(for: f.graph.id, configuration: f.config) }
        await gate.wait()
        let stop = Task { try await f.manager.stopCloudSession(f.config) }
        while await f.manager.automaticClosingCount == 0 { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: f.url.path))
        await gate.release()
        do { _ = try await leave.value } catch {
            #expect(error as? GraphCloudError == .stopping || error as? GraphCloudError == .stopped)
        }
        try await stop.value
        #expect(!FileManager.default.fileExists(atPath: f.url.path))
        _ = try await f.manager.startCloudSession(f.config, adapter: f.cloud.adapter)
        #expect(try await f.manager.cloudSharingStatus(for: f.graph.id, configuration: f.config).phase == .removed)
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    #endif

}
