import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor SharingLatch {
    var ready = false
    var waits: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !ready { await withCheckedContinuation { waits.append($0) } } }
    func release() { ready = true; let values = waits; waits.removeAll(); for value in values { value.resume() } }
}
private actor SharingCalls {
    var creates: [Bool] = []
    func append(_ create: Bool) { creates.append(create) }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudSharingTests {
    private func config() -> GraphCloudConfiguration {
        .init(containerIdentifier: "iCloud.sharing.\(UUID())", environment: .development,
              directory: FileManager.default.temporaryDirectory.appendingPathComponent("Sharing-\(UUID())"))
    }
    private func manager() -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func invitation(_ config: GraphCloudConfiguration, _ id: GraphID) -> GraphCloudInvitation {
        .init(container: config.containerIdentifier, environment: .development, graphID: id,
              owner: "owner", zoneName: "zone-A", recipient: "participant", url: URL(string: "https://www.icloud.com/share/test")!)
    }
    private func fake(_ account: String, permission: GraphCloudSharePermission = .readWrite,
                      accept: (@Sendable () async throws -> Void)? = nil,
                      calls: SharingCalls = SharingCalls(), events: [GraphCloudIncoming] = []) -> GraphCloudAdapter {
        GraphCloudAdapter(sharing: GraphCloudSharingService(invite: { config, binding, owner, recipient, _, create in
            await calls.append(create)
            return GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
                graphID: binding.graphID, owner: owner, zoneName: binding.zone.name, recipient: recipient,
                url: URL(string: "https://www.icloud.com/share/test")!)
        }, accept: { _, _, _ in try await accept?(); return permission }), account: { _ in account }, make: { _, _, _, receive in
            GraphCloudDriver(fetch: { _ in if !events.isEmpty { await receive(.incoming(events)) } }, cancel: {})
        })
    }

    @Test func ownerKeepsPrivateBindingAndCreationIntentSurvivesRestart() async throws {
        let config = config(), manager = manager(), calls = SharingCalls(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "zone-A")
        _ = try await manager.startCloudSession(config, adapter: fake("owner", calls: calls))
        try await manager.bindCloudZone(zone, to: id, configuration: config)
        let first = try await manager.inviteCloudParticipant("participant", to: id, configuration: config)
        #expect(first.zone.scope == .shared && first.owner == "owner")
        #expect(try await manager.cloudBinding(for: zone, configuration: config)?.graphID == id)
        try await manager.stopCloudSession(config)
        _ = try await manager.startCloudSession(config, adapter: fake("owner", calls: calls))
        _ = try await manager.inviteCloudParticipant("participant", to: id, configuration: config)
        #expect(await calls.creates == [true, false])
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    @Test(arguments: [GraphCloudSharePermission.readOnly, .readWrite])
    func acceptanceProtectsAllHandlesAndPersistsPermission(_ permission: GraphCloudSharePermission) async throws {
        let config = config(), manager = manager(), id = GraphID(), entered = SharingLatch(), finish = SharingLatch()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let path = config.directory.appendingPathComponent("A.sqlite")
        let graph = try await manager.createGraph(id: id, at: path)
        let alias = try await manager.openGraph(id: id, at: path)
        _ = try await manager.startCloudSession(config, adapter: fake("participant", permission: permission, accept: {
            await entered.release(); await finish.wait()
        }))
        let invitation = invitation(config, id)
        let operation = Task { try await manager.acceptCloudInvitation(invitation, configuration: config) }
        await entered.wait()
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        #expect(try await alias.participantAccess()?.accepted == false)
        await finish.release(); try await operation.value
        #expect(try await graph.participantAccess()?.permission == permission)
        #expect(try await manager.cloudBinding(for: invitation.zone, configuration: config)?.graphID == id)
        #expect(try await graph.collectSyncChanges() == 0)
        if permission == .readOnly { await #expect(throws: (any Error).self) { try await graph.transaction { _ in () } } }
        else { try await graph.transaction { _ in () } }
        try await graph.close(); try await alias.close()
        let reopened = try await manager.openGraph(id: id, at: path)
        #expect(try await reopened.participantAccess()?.permission == permission)
        try await reopened.close(); try await manager.stopCloudSession(config)
    }

    @Test func failedAcceptanceIsDurableAndCanBeRetriedWithoutConsumerWrites() async throws {
        let config = config(), manager = manager(), id = GraphID(), path = config.directory.appendingPathComponent("A.sqlite")
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: path), invitation = invitation(config, id)
        _ = try await manager.startCloudSession(config, adapter: fake("participant", accept: { throw GraphCloudError.busy }))
        await #expect(throws: GraphCloudError.busy) { try await manager.acceptCloudInvitation(invitation, configuration: config) }
        #expect(try await graph.participantAccess()?.accepted == false)
        try await graph.close(); try await manager.stopCloudSession(config)
        let reopened = try await manager.openGraph(id: id, at: path)
        await #expect(throws: (any Error).self) { try await reopened.transaction { _ in () } }
        _ = try await manager.startCloudSession(config, adapter: fake("participant"))
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        try await reopened.transaction { _ in () }
        try await reopened.close(); try await manager.stopCloudSession(config)
    }

    @Test func wrongRecipientAndNonemptyReplicaAreRejectedBeforeAcceptance() async throws {
        let config = config(), manager = manager(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: fake("participant"))
        await #expect(throws: GraphCloudSharingError.invalidInvitation) {
            let original = invitation(config, id)
            let wrong = GraphCloudInvitation(container: original.container, environment: original.environment,
                graphID: original.graphID, owner: original.owner, zoneName: original.zoneName,
                recipient: "different-account", url: original.url)
            try await manager.acceptCloudInvitation(wrong, configuration: config)
        }
        #expect(try await graph.participantAccess() == nil)
        try await manager.stopCloudSession(config)
        _ = try await manager.startCloudSession(config, adapter: fake("participant"))
        let nodeID = graph.makeNodeID()
        _ = try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: nodeID, type: "Note", endpoints: .entity))
        }
        await #expect(throws: GraphCloudSharingError.nonemptyReplica) {
            try await manager.acceptCloudInvitation(invitation(config, id), configuration: config)
        }
        #expect(try await graph.participantAccess() == nil)
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    @Test func pauseRejectsInvitationAndAcceptanceWithoutChangingReplica() async throws {
        let config = config(), manager = manager(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: fake("participant"))
        try await manager.pauseCloudSynchronization(for: id)
        await #expect(throws: GraphCloudError.graphPaused) { try await manager.acceptCloudInvitation(invitation(config, id), configuration: config) }
        #expect(try await graph.participantAccess() == nil)
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    @Test func secureShareArchiveRemainsControlMetadata() throws {
        let config = config(), id = GraphID(), binding = GraphCloudBinding(zone: invitation(config, id).zone, graphID: id)
        let share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: binding.zone.name, ownerName: binding.zone.owner))
        share.publicPermission = .none
        let incoming = try GraphCloudRecordCodec.archive(share, scope: .shared)
        #expect(try GraphCloudRecordCodec.restore(#require(incoming.recordArchive)) is CKShare)
        #expect(GraphCloudShareControl.isControl(incoming))
        #expect(throws: (any Error).self) { try GraphCloudNodeCodec.decode(incoming, binding: binding) }
        let deleted = GraphCloudIncoming(kind: .recordDeleted, zone: binding.zone, recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        #expect(try GraphCloudShareControl.permission(deleted, binding: binding) == nil)
    }

    @Test func stopDrainsAcceptedControlAndRetainsPendingReplicaForRestart() async throws {
        let config = config(), manager = manager(), id = GraphID(), entered = SharingLatch(), finish = SharingLatch()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        let invitation = invitation(config, id)
        _ = try await manager.startCloudSession(config, adapter: fake("participant", accept: {
            await entered.release(); await finish.wait()
        }))
        let accept = Task { try await manager.acceptCloudInvitation(invitation, configuration: config) }
        await entered.wait()
        let stop = Task { try await manager.stopCloudSession(config) }
        // Wait for the actor to publish stopping rather than depending on wall-clock timing.
        while true {
            do { _ = try await manager.cloudSharingIdentity(config); await Task.yield() }
            catch GraphCloudError.stopping { break }
        }
        #expect(try await graph.participantAccess()?.accepted == false)
        await finish.release()
        await #expect(throws: GraphCloudError.stopping) { try await accept.value }
        try await stop.value
        _ = try await manager.startCloudSession(config, adapter: fake("participant"))
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        #expect(try await graph.participantAccess()?.writable == true)
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    @Test func busyScopeDoesNotConsumeTheOnlyCreationAttempt() async throws {
        let config = config(), entered = SharingLatch(), finish = SharingLatch(), calls = SharingCalls()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        var adapter = fake("owner", calls: calls)
        adapter = GraphCloudAdapter(sharing: adapter.sharing, account: adapter.account, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in await entered.release(); await finish.wait() }, cancel: {})
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "zone-A"), graphID: GraphID())
        try await session.bind(binding)
        let fetch = Task { try await session.fetch(.private) }
        await entered.wait()
        await #expect(throws: GraphCloudError.busy) { try await session.invite(binding, recipient: "participant", permission: .readWrite) }
        await finish.release(); try await fetch.value
        _ = try await session.invite(binding, recipient: "participant", permission: .readWrite)
        #expect(await calls.creates == [true])
        try await session.stop()
    }

    @Test func accessReductionCommitsBeforeMalformedPayloadAndPreservesPendingWork() async throws {
        let config = config(), manager = manager(), id = GraphID(), invitation = invitation(config, id)
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        let control = GraphCloudIncoming(kind: .recordDeleted, zone: invitation.zone,
            recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        let malformed = CKRecord(recordType: GraphCloudNodeCodec.recordType,
            recordID: CKRecord.ID(recordName: "node." + UUID().uuidString.lowercased(),
                zoneID: CKRecordZone.ID(zoneName: invitation.zone.name, ownerName: invitation.zone.owner)))
        let payload = try GraphCloudRecordCodec.archive(malformed, scope: .shared)
        _ = try await manager.startCloudSession(config, adapter: fake("participant", events: [control, payload]))
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        let nodeID = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: nodeID, type: "Note")) }
        #expect(try await graph.collectSyncChanges() == 1)
        try await manager.fetchCloudChanges(.shared, configuration: config)
        await #expect(throws: (any Error).self) { try await manager.applyCloudInbox(for: id, configuration: config) }
        #expect(try await graph.participantAccess()?.writable == false)
        #expect(try await manager.cloudInbox(config).count == 1)
        #expect(try await graph.collectSyncChanges() == 1)
        await #expect(throws: (any Error).self) { try await graph.transaction { _ in () } }
        await #expect(throws: (any Error).self) { try await manager.sendCloudChanges(for: id, configuration: config) }
        #expect(try await graph.collectSyncChanges() == 1)
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    @Test func corruptReservedAccessCannotGrantConsumerWrites() async throws {
        let config = config(), manager = manager(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        // Trusted fault injection only; the public consumer scope cannot edit reserved metadata.
        try await graph.transaction { scope in
            try scope.withContext { context, _ in
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
                let foreign = GraphCloudParticipantAccess(binding: .init(zone: .init(scope: .private, owner: "owner", name: "A"),
                    graphID: GraphID()), account: "participant", permission: .readWrite, accepted: true)
                root[dynamicMember: GraphCloudAccessMetadata.key] = try JSONEncoder().encode(foreign)
            }
        }
        await #expect(throws: (any Error).self) { try await graph.transaction { _ in () } }
        await #expect(throws: GraphCloudError.invalidState) { try await graph.participantAccess() }
        try await graph.close()
    }

    @Test func oldSessionFormatIsRefusedWithoutRewritingIt() async throws {
        let config = config(), adapter = fake("owner")
        defer { try? FileManager.default.removeItem(at: config.directory) }
        var doc = GraphCloudDocument(container: config.containerIdentifier, environment: config.environment, account: "owner")
        doc.format = 3
        try FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
        let path = config.directory.appendingPathComponent("session.json"), data = try JSONEncoder().encode(doc)
        try data.write(to: path)
        await #expect(throws: GraphCloudError.invalidState) { try await GraphCloudSession.open(config, adapter: adapter) }
        #expect(try Data(contentsOf: path) == data)
    }
}
