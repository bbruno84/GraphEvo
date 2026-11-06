import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor NativeInvitationServer {
    let graphID = GraphID()
    let url = URL(string: "https://www.icloud.com/share/native-fixture")!
    let permission: GraphCloudSharePermission
    var remoteRecord: GraphRecord?
    init(permission: GraphCloudSharePermission = .readOnly) { self.permission = permission }
    func seedRemote(_ record: GraphRecord) { remoteRecord = record }
    var descriptorAvailable = false
    var accepted = false
    var acceptWrites = 0
    var discarded = false
    var currentAccount = "participant"
    var switchAfterAccept = false
    var revoked = false
    func setRevoked(_ value: Bool) { revoked = value }
    var failLeave = false
    func setLeaveFailure(_ value: Bool) { failLeave = value }
    var sharedFetches = 0
    var inspectHook: (@Sendable () async -> Void)?
    func setInspectHook(_ hook: (@Sendable () async -> Void)?) { inspectHook = hook }
    func inspectInvitation() async -> GraphCloudNativeInvitation { await inspectHook?(); return invitation() }
    func fetched(_ scope: GraphCloudScope) { if scope == .shared { sharedFetches += 1 } }
    func switchOnAcceptance() { switchAfterAccept = true }
    func restoreAccount() { currentAccount = "participant"; switchAfterAccept = false }
    func switchAccount() { currentAccount = "other-account" }
    func available() { descriptorAvailable = true }
    func accept() {
        if !accepted { acceptWrites += 1; accepted = true }
        if switchAfterAccept { currentAccount = "other-account" }
    }
    func discover() throws -> GraphID {
        guard descriptorAvailable else { throw GraphCloudDiscoveryError.metadataPending }
        return graphID
    }
    func discard() { discarded = true }
    func invitation() -> GraphCloudNativeInvitation {
        .init(url: url, zone: .init(scope: .shared, owner: "owner", name: "native-zone"), owner: "owner", permission: permission, accepted: accepted)
    }
    nonisolated var adapter: GraphCloudAdapter {
        let operations = GraphCloudSharingOperations(inspect: { _, _, _ in
            if await self.revoked { return nil }
            return .init(identity: GraphCloudShareIdentity.of(self.url), role: .participant, permission: self.permission, participants: [])
        }, execute: { _, _, _, _ in
            if await self.failLeave { throw GraphCloudError.transportUnavailable }
        })
        return GraphCloudAdapter(nativeSharing: .init(prepare: { _, _, _, _, _ in throw GraphCloudSharingError.unavailable },
            inspect: { _, _, _ in await self.inspectInvitation() }, accept: { _, _, _ in await self.accept() },
            discover: { _, _ in try await self.discover() }, discard: { _, _, _ in await self.discard() }),
            sharing: .init(operations: operations, invite: { _, _, _, _, _, _, _ in throw GraphCloudSharingError.unavailable },
                accept: { _, _, _ in self.permission }),
            account: { _ in await self.currentAccount }, make: { _, scope, _, receive in .init(fetch: { _ in
                await self.fetched(scope)
                if scope == .shared, let record = await self.remoteRecord {
                    let route = GraphCloudBinding(zone: await self.invitation().zone, graphID: record.id.graphID)
                    let incoming = try GraphCloudRecordCodec.archive(GraphCloudNodeCodec.encode(record, binding: route), scope: scope)
                    await receive(.incoming([incoming]))
                }
            }, cancel: {}) })
    }
}

private actor NativeInviteGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func release() { opened = true; let values = waiters; waiters.removeAll(); for value in values { value.resume() } }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct GraphNativeInvitationTests {
    private func config() -> GraphCloudConfiguration {
        .init(containerIdentifier: "iCloud.native." + UUID().uuidString, environment: .development,
              directory: FileManager.default.temporaryDirectory.appendingPathComponent("NativeInvite-" + UUID().uuidString), allowsSessionUpgradeFromV8: true)
    }
    @Test func descriptorIsIndependentOfNodePayloadAndSupportsEmptyGraphs() throws {
        let binding = GraphCloudBinding(zone: .init(scope: .shared, owner: "owner", name: "empty"), graphID: GraphID())
        let record = GraphCloudGraphDescriptor.encode(binding)
        #expect(try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) == binding.graphID)
        record["futureOptional"] = "small" as CKRecordValue
        #expect(try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) == binding.graphID)
        record["format"] = NSNumber(value: 2)
        #expect(throws: GraphCloudDiscoveryError.unsupportedDescriptor) { try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) }
        record["format"] = NSNumber(value: true)
        #expect(throws: GraphCloudDiscoveryError.invalidDescriptor) { try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) }
    }
    @Test func descriptorRejectsForeignZoneOversizeAndNoncanonicalIdentity() throws {
        let binding = GraphCloudBinding(zone: .init(scope: .shared, owner: "owner", name: "empty"), graphID: GraphID())
        let record = GraphCloudGraphDescriptor.encode(binding)
        #expect(throws: (any Error).self) { try GraphCloudGraphDescriptor.decode(record, zone: .init(scope: .shared, owner: "other", name: "empty")) }
        record["graphID"] = binding.graphID.rawValue.uuidString.uppercased() as CKRecordValue
        #expect(throws: (any Error).self) { try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) }
        record["graphID"] = binding.graphID.rawValue.uuidString.lowercased() as CKRecordValue
        record["extra"] = Data(repeating: 0, count: 17 * 1024) as CKRecordValue
        #expect(throws: (any Error).self) { try GraphCloudGraphDescriptor.decode(record, zone: binding.zone) }
    }
    @Test func acceptanceBeforeDiscoverySurvivesRestartWithoutAReplica() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        let first = try await session.nativeBeginJoin(server.url)
        await #expect(throws: GraphCloudDiscoveryError.metadataPending) { try await session.nativeAdvanceJoin(first.id) }
        #expect(try await session.nativeJoin(first.id).phase == .discoveringGraph)
        #expect(await server.acceptWrites == 1)
        try await session.stop()
        await server.available()
        let recovered = try await GraphCloudSession.open(config, adapter: server.adapter)
        let duplicate = try await recovered.nativeBeginJoin(server.url)
        #expect(duplicate.id == first.id)
        try await recovered.nativeAdvanceJoin(first.id)
        #expect(try await recovered.nativeJoin(first.id).graphID == server.graphID)
        #expect(try await recovered.nativeJoin(first.id).phase == .ready)
        #expect(await server.acceptWrites == 1)
        #expect(try await recovered.routes(in: .shared).isEmpty)
        try await recovered.stop()
    }
    @Test func discardUsesExactAcceptedIntentAndPersistsTerminalState() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        let join = try await session.nativeBeginJoin(server.url)
        await #expect(throws: (any Error).self) { try await session.nativeAdvanceJoin(join.id) }
        try await session.nativeDiscardJoin(join.id)
        #expect(await server.discarded)
        #expect(try await session.nativeJoin(join.id).phase == .discarded)
        try await session.stop()
    }
    @Test func formatEightUpgradePreservesOpaqueEngineStateAndRejectsMalformedJoin() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        try FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
        var doc = GraphCloudDocument(container: config.containerIdentifier, environment: config.environment, account: "participant")
        doc.format = 8; doc.states["private"] = Data([4, 7, 9])
        let path = config.directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(doc).write(to: path)
        let refused = GraphCloudConfiguration(containerIdentifier: config.containerIdentifier, environment: config.environment, directory: config.directory)
        let original = try Data(contentsOf: path)
        await #expect(throws: GraphCloudDiscoveryError.sessionUpgradeRequired) { try await GraphCloudSession.open(refused, adapter: server.adapter) }
        #expect(try Data(contentsOf: path) == original)
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        let upgraded = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: path))
        #expect(upgraded.format == 9 && upgraded.states == doc.states)
        try await session.stop()
        doc.format = 8
        doc.joins = [.init(id: UUID(), invitation: await server.invitation())]
        let bad = try JSONEncoder().encode(doc); try bad.write(to: path)
        await #expect(throws: (any Error).self) { try await GraphCloudSession.open(config, adapter: server.adapter) }
        #expect(try Data(contentsOf: path) == bad)
    }
    @available(iOS 17, macOS 14, *)
    @Test func publicNativeJoinOpensAnEmptyReadOnlyReplicaAndCanReopenIt() async throws {
        let native = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: native.directory) }
        await server.available()
        let context = GraphContext(manager: GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()), adapter: server.adapter)
        let config = try GraphCloudConnectionConfiguration(containerIdentifier: native.containerIdentifier, environment: native.environment, directory: native.directory)
        let connection = try await context.connectCloud(using: config)
        for _ in 0..<2000 {
            if try await connection.state == .ready { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let join = try await connection.acceptInvitation(at: server.url)
        #expect(try await join.state.phase == .ready)
        let url = native.directory.appendingPathComponent("Replica.sqlite")
        let graph = try await connection.openReplica(for: join, at: url)
        #expect(graph.id == server.graphID)
        #expect(try await join.state.phase == .joined)
        await #expect(throws: (any Error).self) { try await graph.transaction { _ in () } }
        try await connection.pauseSynchronization(for: graph.id)
        try await connection.resumeSynchronization(for: graph.id)
        try await graph.close()
        let reopened = try await connection.openReplica(for: join, at: url)
        #expect(reopened.id == graph.id)
        let removed = try await connection.leaveSharedGraph(reopened)
        #expect(removed.phase == .removed && !removed.remoteOperationPending)
        await #expect(throws: (any Error).self) { try await reopened.read { _ in () } }
        try await reopened.close()
        let forbidden = native.directory.appendingPathComponent("OldJoin.sqlite")
        await #expect(throws: GraphCloudDiscoveryError.invalidJoin) { try await connection.openReplica(for: join, at: forbidden) }
        #expect(!FileManager.default.fileExists(atPath: forbidden.path))
        let reinvited = try await connection.acceptInvitation(at: server.url)
        #expect(reinvited.id != join.id)
        let second = try await connection.openReplica(for: reinvited, at: native.directory.appendingPathComponent("Rejoined.sqlite"))
        #expect(second.id == graph.id)
        await #expect(throws: GraphStoreError.self) { try await connection.leaveSharedGraph(reopened) }
        #expect(try await connection.sharingStatus(for: second.id).phase == .active)
        try await second.close(); try await connection.close()
    }
    @available(iOS 17, macOS 14, *)
    @Test func publicAppGroupParticipantCanPatchAnImportedRecordFromTheSecondary() async throws {
        let native = config(), server = NativeInvitationServer(permission: .readWrite)
        defer { try? FileManager.default.removeItem(at: native.directory) }
        let group = AppGroupStoreLocation(container: native.directory)
        let context = GraphContext(manager: GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group,
            publicAppGroup: .init(identifier: "fixture", role: .primary, allowsCloudSynchronization: true)), adapter: server.adapter)
        let id = await server.graphID, note = GraphNodeID(graphID: id)
        await server.available()
        await server.seedRemote(try .init(id: note, type: "Note", properties: ["value": .integer(1)]))
        let connection = try await context.connectCloud(using: .init(containerIdentifier: native.containerIdentifier,
            environment: native.environment, directory: native.directory.appendingPathComponent("Session")))
        try await context.setForegroundActive(true)
        for _ in 0..<200 {
            if try await connection.state == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let join = try await connection.acceptInvitation(at: server.url)
        let graph = try await connection.openAppGroupReplica(for: join)
        for _ in 0..<200 {
            if try await graph.read({ try $0.record(for: note) }) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await graph.read { try $0.record(for: note)?.properties["value"] } == .integer(1))
        try await context.setForegroundActive(false)
        try await graph.close()
        try await connection.close()

        let secondary = GraphContext(manager: GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group,
            publicAppGroup: .init(identifier: "fixture", role: .secondary, secondaryAccess: .readWrite)))
        let result = try await secondary.transactionAppGroupGraph(id: id) {
            try $0.patch(.init(id: note, properties: ["value": .set(.integer(2))]))
        }
        #expect(result.value.properties["value"] == .integer(2))
        #expect(!result.closePending)
        #expect(await secondary.manager.cloudSessions.isEmpty)
    }

    enum RemovalPath: String, CaseIterable, Sendable { case leave, deferredLeave, revocation }

    @available(iOS 17, macOS 14, *)
    @Test(arguments: RemovalPath.allCases)
    func settledLeaveReleasesThePurgedGraphForANewWorkspaceContext(path: RemovalPath) async throws {
        let native = config(), server = NativeInvitationServer(), registry = StoreRegistry()
        defer { try? FileManager.default.removeItem(at: native.directory) }
        await server.available()
        func context() -> GraphContext {
            GraphContext(manager: GraphContextManager(registry: registry, schema: GraphRuntimeSchema.typedProperties,
                adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()), adapter: server.adapter)
        }
        func ready(_ connection: GraphCloudConnection) async throws {
            for _ in 0..<2000 {
                if try await connection.state == .ready { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            throw GraphCloudError.invalidState
        }
        let oldContext = context()
        let oldConfiguration = try GraphCloudConnectionConfiguration(containerIdentifier: native.containerIdentifier,
            environment: .development, directory: native.directory.appendingPathComponent("OldSession"))
        let oldConnection = try await oldContext.connectCloud(using: oldConfiguration)
        try await ready(oldConnection)
        let oldJoin = try await oldConnection.acceptInvitation(at: server.url)
        let oldURL = native.directory.appendingPathComponent("Old.sqlite")
        let oldGraph = try await oldConnection.openReplica(for: oldJoin, at: oldURL)
        let newContext = context()
        if path == .revocation {
            await server.setRevoked(true)
            do {
                _ = try await oldConnection.refreshSharing(for: oldGraph.id)
                Issue.record("Revoked access unexpectedly remained active.")
            } catch GraphCloudConnectionError.operationFailed(_, let underlying) {
                #expect(underlying as? GraphCloudError == .zoneUnavailable)
            }
            for _ in 0..<2000 {
                if try await oldConnection.sharingStatus(for: oldGraph.id).phase == .removed { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(try await oldConnection.sharingStatus(for: oldGraph.id).phase == .removed)
            await server.setRevoked(false)
        } else {
            await server.setLeaveFailure(path == .deferredLeave)
            let removal = try await oldConnection.leaveSharedGraph(oldGraph)
            #expect(removal.phase == .removed && removal.remoteOperationPending == (path == .deferredLeave))
        }
        if path == .deferredLeave {
            let forbidden = native.directory.appendingPathComponent("PendingLeave.sqlite")
            await #expect(throws: GraphStoreError.self) { try await newContext.createGraph(id: oldGraph.id, at: forbidden) }
            #expect(!FileManager.default.fileExists(atPath: forbidden.path))
            await server.setLeaveFailure(false)
            let session = try await oldContext.manager.cloud(oldConfiguration.native)
            let member = try #require(try await session.membership(oldGraph.id))
            #expect(try await oldContext.manager.executeSharingIntent(member, session: session).remoteOperationPending == false)
        }
        try await oldGraph.close(); try await oldConnection.close()
        let newConfiguration = try GraphCloudConnectionConfiguration(containerIdentifier: native.containerIdentifier,
            environment: .development, directory: native.directory.appendingPathComponent("NewSession"))
        let newConnection = try await newContext.connectCloud(using: newConfiguration)
        try await ready(newConnection)
        let join = try await newConnection.acceptInvitation(at: server.url)
        let graph = try await newConnection.openReplica(for: join, at: native.directory.appendingPathComponent("New.sqlite"))
        #expect(graph.id == oldGraph.id)
        #expect(try await graph.validateIntegrity() == 0)
        await #expect(throws: GraphCloudError.zoneUnavailable) { try await oldContext.openGraph(id: graph.id, at: oldURL) }
        await #expect(throws: GraphStoreError.self) { try await newConnection.leaveSharedGraph(oldGraph) }
        #expect(try await newConnection.sharingStatus(for: graph.id).phase == .active)
        try await graph.close(); try await newConnection.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func firstLocalSaveCarriesARecoverableJoinMarkerBeforeMembershipPublication() async throws {
        let native = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: native.directory) }
        await server.available()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID())
        _ = try await manager.startCloudSession(native, adapter: server.adapter)
        let session = try await manager.cloud(native)
        var intent = try await session.nativeBeginJoin(server.url)
        try await session.nativeAdvanceJoin(intent.id)
        intent = try await session.nativeJoin(intent.id)
        intent.phase = .openingReplica; try await session.updateJoin(intent)
        let id = try #require(intent.graphID), identity = try await session.identity()
        let access = GraphCloudParticipantAccess(binding: .init(zone: intent.invitation.zone, graphID: id), account: identity.account,
            permission: nil, accepted: false, identity: identity, generation: intent.id)
        let url = native.directory.appendingPathComponent("Interrupted.sqlite")
        let prepared = try await manager.createJoiningGraph(id: id, at: url, access: access)
        #expect(try await prepared.participantAccess() == access)
        await #expect(throws: (any Error).self) { try await prepared.read { _ in () } }
        #expect(try await session.membership(id) == nil)
        try await prepared.close(); try await manager.stopCloudSession(native)
        let recovered = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID())
        _ = try await recovered.startCloudSession(native, adapter: server.adapter)
        let graph = try await recovered.openNativeReplica(intent.id, at: url, configuration: native)
        #expect(graph.id == id)
        #expect(try await graph.read { try $0.record(for: GraphNodeID(graphID: id)) } == nil)
        #expect(try await recovered.cloud(native).nativeJoin(intent.id).phase == .joined)
        try await graph.close(); try await recovered.stopCloudSession(native)
    }
    @Test func failedIntentPublicationPreventsAcceptance() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let session = try await GraphCloudSession.open(config, adapter: server.adapter,
            disk: .init(read: { _ in nil }, write: { _, bytes in
                let value = try JSONDecoder().decode(GraphCloudDocument.self, from: bytes)
                if value.joins?.isEmpty == false { throw GraphCloudError.persistence }
            }))
        await #expect(throws: GraphCloudError.persistence) { try await session.nativeBeginJoin(server.url) }
        #expect(await server.acceptWrites == 0)
        #expect(try await session.nativeJoins().isEmpty)
        try await session.stop()
    }
    @Test func descriptorControlsAreValidatedBeforeApplicationImport() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        let id = await server.graphID
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("Control.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: server.adapter)
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "control")
        try await manager.bindCloudZone(zone, to: id, configuration: config)
        let session = try await manager.cloud(config), binding = GraphCloudBinding(zone: zone, graphID: id)
        let descriptor = try GraphCloudRecordCodec.archive(GraphCloudGraphDescriptor.encode(binding), scope: .private)
        await session.receive(.incoming([descriptor]), scope: .private)
        _ = try await manager.applyCloudInbox(for: id, configuration: config)
        #expect(try await session.incoming(for: zone, limit: 1).isEmpty)
        let wrong = GraphCloudGraphDescriptor.encode(.init(zone: zone, graphID: GraphID()))
        await session.receive(.incoming([try GraphCloudRecordCodec.archive(wrong, scope: .private)]), scope: .private)
        await #expect(throws: GraphCloudDiscoveryError.invalidDescriptor) { try await manager.applyCloudInbox(for: id, configuration: config) }
        #expect(try await session.incoming(for: zone, limit: 1).count == 1)
        try await graph.close(); try await manager.stopCloudSession(config)
    }
    @Test func busyNativePreparationCannotReplaceAnotherGraphsCreateReservation() async throws {
        let config = config(), server = NativeInvitationServer(), entered = NativeInviteGate(), proceed = NativeInviteGate()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        var adapter = server.adapter
        adapter.nativeSharing = .init(prepare: { _, _, _, mayCreate, reserve in
            #expect(mayCreate)
            await entered.release(); await proceed.wait()
            try await reserve()
            return Data([1])
        }, inspect: { _, _, _ in await server.invitation() }, accept: { _, _, _ in }, discover: { _, _ in await server.graphID }, discard: { _, _, _ in })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        let first = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "first"), graphID: GraphID())
        let other = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "other"), graphID: GraphID())
        try await session.bind(first); try await session.bind(other)
        let preparing = Task { try await session.nativePrepareShare(first, title: "First") }
        await entered.wait()
        await #expect(throws: GraphCloudError.busy) { try await session.nativePrepareShare(other, title: "Other") }
        await proceed.release()
        #expect(try await preparing.value == Data([1]))
        let document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: config.directory.appendingPathComponent("session.json")))
        #expect(document.shareAttempts == [first.zone])
        try await session.stop()
    }
    @Test func replicaOpeningCannotOverwriteAnInterveningDiscardIntent() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        await server.available()
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        let join = try await session.nativeBeginJoin(server.url)
        try await session.nativeAdvanceJoin(join.id)
        var stale = try await session.nativeJoin(join.id)
        try await session.nativeDiscardJoin(join.id)
        stale.phase = .openingReplica
        await #expect(throws: GraphCloudDiscoveryError.busy) { try await session.updateJoin(stale, expectedPhase: .ready) }
        #expect(try await session.nativeJoin(join.id).phase == .discarded)
        try await session.stop()
    }
    @Test func malformedDescriptorCannotHideAPermissionReductionBehindTheEventLimit() async throws {
        let config = config(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("Reduction.sqlite"))
        let invitation = GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
            graphID: id, owner: "owner", zoneName: "reduction", recipient: "participant", url: URL(string: "https://www.icloud.com/share/reduction")!)
        let descriptor = try GraphCloudRecordCodec.archive(GraphCloudGraphDescriptor.encode(.init(zone: invitation.zone, graphID: GraphID())), scope: .shared)
        let reduction = GraphCloudIncoming(kind: .recordDeleted, zone: invitation.zone, recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        let adapter = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, _, _ in throw GraphCloudSharingError.unavailable },
            accept: { _, _, _ in .readWrite }), account: { _ in "participant" }, make: { _, _, _, receive in
                .init(fetch: { _ in await receive(.incoming([descriptor, reduction])) }, cancel: {})
            })
        _ = try await manager.startCloudSession(config, adapter: adapter)
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        try await manager.fetchCloudChanges(.shared, configuration: config)
        do { _ = try await manager.applyCloudInbox(for: id, configuration: config, maximumEvents: 1) } catch { }
        #expect(try await graph.participantAccess()?.writable == false)
        #expect(try await manager.cloudInbox(config).count == 1)
        try await graph.close(); try await manager.stopCloudSession(config)
    }
    @Test func changedAccountCannotAdvanceAnAcceptedInvitationIntent() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        let join = try await session.nativeBeginJoin(server.url)
        await server.switchAccount()
        await #expect(throws: GraphCloudError.accountChanged) { try await session.nativeAdvanceJoin(join.id) }
        #expect(await server.acceptWrites == 0)
        try await session.stop()
    }
    @Test func confirmedOwnerPresentationCanRecoverAStopButAnAmbiguousCreateCannot() async throws {
        let config = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        var adapter = server.adapter
        adapter.sharing?.operations = .init(inspect: { _, _, _ in nil }, execute: { _, _, _, _ in })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "owner-ui"), graphID: GraphID())
        try await session.bind(binding)
        var member = GraphCloudMembership(binding: binding, identity: try await session.identity(), generation: UUID(),
            role: .owner, phase: .active, permission: .readWrite, hadAccess: true)
        member.nativePresentationPending = true
        try await session.updateMembership(member)
        await #expect(throws: GraphCloudSharingError.metadataPending) { try await session.nativeReconcileOwnerShare(binding, stopped: false) }
        member.shareIdentity = "confirmed-share-identity"
        try await session.updateMembership(member)
        try await session.nativeReconcileOwnerShare(binding, stopped: false)
        #expect(try await session.membership(binding.graphID)?.nativePresentationPending == nil)
        #expect(try await session.membership(binding.graphID)?.shareIdentity == nil)
        try await session.stop()
    }
    @available(iOS 17, macOS 14, *)
    @Test func accountLossAfterNativeAcceptanceStillReturnsTheDurableJoinID() async throws {
        let native = config(), server = NativeInvitationServer()
        defer { try? FileManager.default.removeItem(at: native.directory) }
        let context = GraphContext(manager: .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()), adapter: server.adapter)
        let connection = try await context.connectCloud(using: .init(containerIdentifier: native.containerIdentifier,
            environment: native.environment, directory: native.directory))
        for _ in 0..<2000 {
            if try await connection.state == .ready { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await server.switchOnAcceptance()
        let join = try await connection.acceptInvitation(at: server.url)
        #expect(await server.acceptWrites == 1)
        try await connection.close()
        await server.restoreAccount()
        let recovered = try await GraphCloudSession.open(native, adapter: server.adapter)
        #expect(try await recovered.nativeJoins().map(\.id) == [join.id])
        try await recovered.stop()
    }
    @Test(arguments: [false, true])
    func nativeJoinWakesForegroundImportWithoutAManualSyncOrPeriodicTick(writable: Bool) async throws {
        let config = config(), server = NativeInvitationServer(permission: writable ? .readWrite : .readOnly), entered = NativeInviteGate(), proceed = NativeInviteGate()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        await server.available()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        _ = try await manager.startCloudSession(config, adapter: server.adapter)
        let clock = GraphAutomaticClock(now: { 0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 1 })
        try await manager.setAutomaticCloudSynchronizationActive(true, configuration: config, clock: clock)
        let session = try await manager.cloud(config)
        let join = try await session.nativeBeginJoin(server.url)
        try await session.nativeAdvanceJoin(join.id)
        let id = await server.graphID
        let remote = try GraphRecord(id: GraphNodeID(graphID: id, rawValue: UUID()), type: "Native.Shared.Note",
            properties: ["title": .string("Independent owner note"), "bytes": .data(Data([0, 128, 255]))])
        await server.seedRemote(remote)
        await server.setInspectHook { await entered.release(); await proceed.wait() }
        let opening = Task { try await manager.openNativeReplica(join.id, at: config.directory.appendingPathComponent("Automatic.sqlite"), configuration: config) }
        await entered.wait()
        // Drain the pre-binding creation hint: it must not accidentally supply the missing wake.
        await #expect(throws: GraphStoreError.self) { try await manager.automaticCloudSynchronizationStatus(for: id, configuration: config) }
        await proceed.release()
        let graph = try await opening.value
        for _ in 0..<100 {
            if try await graph.read({ try $0.record(for: remote.id) }) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.sharedFetches > 0)
        let imported = try await graph.read { try $0.record(for: remote.id) }
        #expect(imported?.id == remote.id)
        #expect(imported?.properties == remote.properties)
        for _ in 0..<100 {
            if try await manager.automaticCloudSynchronizationStatus(for: id, configuration: config).phase == .idle { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await manager.setAutomaticCloudSynchronizationActive(false, configuration: config, clock: clock)
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try await manager.stopCloudSession(config)
    }
}
