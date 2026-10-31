import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

/// Review reproducers for first-invitation recovery and bounded permission processing.
@Suite(.timeLimit(.minutes(1))) struct GraphCloudSharingReviewTests {
    private func configuration() -> GraphCloudConfiguration {
        .init(containerIdentifier: "iCloud.review.\(UUID())", environment: .development,
              directory: FileManager.default.temporaryDirectory.appendingPathComponent("SharingReview-\(UUID())"))
    }
    private func manager() -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }

    @Test func boundedInboxDoesNotHidePermissionReductionBehindMalformedData() async throws {
        let config = configuration(), manager = manager(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let invitation = GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
            graphID: id, owner: "owner", zoneName: "A", recipient: "participant", url: URL(string: "https://www.icloud.com/share/review")!)
        let malformed = CKRecord(recordType: GraphCloudNodeCodec.recordType,
            recordID: .init(recordName: "node." + UUID().uuidString.lowercased(),
                            zoneID: .init(zoneName: "A", ownerName: "owner")))
        let payload = try GraphCloudRecordCodec.archive(malformed, scope: .shared)
        let reduction = GraphCloudIncoming(kind: .recordDeleted, zone: invitation.zone,
            recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        let adapter = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, _, _ in throw GraphCloudSharingError.unavailable },
            accept: { _, _, _ in .readWrite }), account: { _ in "participant" }, make: { _, _, _, receive in
                GraphCloudDriver(fetch: { _ in await receive(.incoming([payload, reduction])) }, cancel: {})
            })
        let graph = try await manager.createGraph(id: id, at: config.directory.appendingPathComponent("A.sqlite"))
        _ = try await manager.startCloudSession(config, adapter: adapter)
        try await manager.acceptCloudInvitation(invitation, configuration: config)
        try await manager.fetchCloudChanges(.shared, configuration: config)
        // A bounded call must still apply a retained access reduction before unrelated decoding.
        do { _ = try await manager.applyCloudInbox(for: id, configuration: config, maximumEvents: 1) } catch {}
        #expect(try await graph.participantAccess()?.writable == false)
        let remaining = try await manager.cloudInbox(config)
        #expect(remaining.count == 1 && remaining.first?.change == payload)
        await #expect(throws: (any Error).self) { try await graph.transaction { _ in () } }
        try await graph.close(); try await manager.stopCloudSession(config)
    }

    private actor PreflightFailure {
        var invocations = 0
        func invoke(_ mayCreate: Bool) throws {
            invocations += 1
            if invocations == 1 {
                // The initial server lookup fails before any save/create has been attempted.
                throw CKError(.networkUnavailable)
            }
            if !mayCreate { throw GraphCloudSharingError.metadataPending }
        }
    }

    @Test func failedInitialReadDoesNotPermanentlyDisableFirstInvitation() async throws {
        let config = configuration(), failure = PreflightFailure(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "A"), graphID: id)
        let adapter = GraphCloudAdapter(sharing: .init(invite: { config, binding, owner, recipient, _, mayCreate, beforeCreate in
            try await failure.invoke(mayCreate)
            try await beforeCreate()
            return GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
                graphID: binding.graphID, owner: owner, zoneName: binding.zone.name,
                recipient: recipient, url: URL(string: "https://www.icloud.com/share/review")!)
        }, accept: { _, _, _ in .readWrite }), account: { _ in "owner" }, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        try await session.bind(binding)
        await #expect(throws: CKError.self) { try await session.invite(binding, recipient: "participant", permission: .readWrite) }
        let path = config.directory.appendingPathComponent("session.json")
        let before = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: path))
        #expect(before.shareAttempts.isEmpty)
        try await session.stop()
        let reopened = try await GraphCloudSession.open(config, adapter: adapter)
        // Network restored after restart. No server write took place, so creation remains possible.
        var recovered = false
        do { _ = try await reopened.invite(binding, recipient: "participant", permission: .readWrite); recovered = true } catch {}
        #expect(recovered)
        try await reopened.stop()
    }
    private actor CreationBoundary {
        var callback: (@Sendable () async throws -> Void)?
        var saves = 0
        func capture(_ body: @escaping @Sendable () async throws -> Void) { callback = body }
        func saved() { saves += 1 }
        func late() async throws { try await callback?() }
    }

    @Test func ambiguousCreationRetainsMarkerAcrossRestart() async throws {
        let config = configuration(), id = GraphID()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "A"), graphID: id)
        let adapter = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, mayCreate, beforeCreate in
            guard mayCreate else { throw GraphCloudSharingError.metadataPending }
            try await beforeCreate()
            // A save was submitted but its outcome is unknown. Never re-create on an absent-server retry.
            throw CKError(.networkFailure)
        }, accept: { _, _, _ in .readWrite }), account: { _ in "owner" }, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        try await session.bind(binding)
        await #expect(throws: CKError.self) { try await session.invite(binding, recipient: "participant", permission: .readWrite) }
        try await session.stop()
        let reopened = try await GraphCloudSession.open(config, adapter: adapter)
        await #expect(throws: GraphCloudSharingError.metadataPending) {
            try await reopened.invite(binding, recipient: "participant", permission: .readWrite)
        }
        try await reopened.stop()
    }

    @Test func durableReservationFailurePreventsServerWrite() async throws {
        let config = configuration(), boundary = CreationBoundary()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "A"), graphID: GraphID())
        let adapter = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, _, beforeCreate in
            try await beforeCreate()
            await boundary.saved()
            throw GraphCloudSharingError.metadataPending
        }, accept: { _, _, _ in .readWrite }), account: { _ in "owner" }, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, bytes in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: bytes)
            if !doc.shareAttempts.isEmpty { throw GraphCloudError.persistence }
            try GraphCloudDisk.live.write(url, bytes)
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter, disk: disk)
        try await session.bind(binding)
        await #expect(throws: GraphCloudError.persistence) { try await session.invite(binding, recipient: "participant", permission: .readWrite) }
        #expect(await boundary.saves == 0)
        try await session.stop()
    }

    @Test func completedControlCannotReserveCreationFromLateCallback() async throws {
        let config = configuration(), boundary = CreationBoundary()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let binding = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "A"), graphID: GraphID())
        let adapter = GraphCloudAdapter(sharing: .init(invite: { _, _, _, _, _, _, beforeCreate in
            await boundary.capture(beforeCreate)
            throw CKError(.networkUnavailable)
        }, accept: { _, _, _ in .readWrite }), account: { _ in "owner" }, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        try await session.bind(binding)
        await #expect(throws: CKError.self) { try await session.invite(binding, recipient: "participant", permission: .readWrite) }
        await #expect(throws: GraphCloudError.invalidState) { try await boundary.late() }
        let doc = try JSONDecoder().decode(GraphCloudDocument.self,
            from: Data(contentsOf: config.directory.appendingPathComponent("session.json")))
        #expect(doc.shareAttempts.isEmpty)
        try await session.stop()
    }

    @Test func controlsRespectLimitZoneIsolationAndApplicationOrdering() async throws {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let zone = GraphCloudZone(scope: .shared, owner: "owner", name: "A")
        let other = GraphCloudZone(scope: .shared, owner: "owner", name: "B")
        let adapter = GraphCloudAdapter(account: { _ in "participant" }, make: { _, _, _, _ in
            GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        try await session.bind(.init(zone: zone, graphID: GraphID()))
        try await session.bind(.init(zone: other, graphID: GraphID()))
        let first = GraphCloudIncoming(kind: .recordDeleted, zone: zone, recordName: "node." + UUID().uuidString.lowercased(), recordType: GraphCloudNodeCodec.recordType)
        let second = GraphCloudIncoming(kind: .recordDeleted, zone: zone, recordName: "node." + UUID().uuidString.lowercased(), recordType: GraphCloudNodeCodec.recordType)
        let control = GraphCloudIncoming(kind: .recordDeleted, zone: zone, recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        let foreign = GraphCloudIncoming(kind: .recordDeleted, zone: other, recordName: CKRecordNameZoneWideShare, recordType: CKRecord.SystemType.share)
        await session.receive(.incoming([first, foreign, control, second]), scope: .shared)
        let selected = try await session.incoming(for: zone, limit: 2)
        #expect(selected.map(\.change) == [control, first])
        try await session.consume(Set(selected.map(\.id)))
        #expect(try await session.incoming(for: zone, limit: 2).map(\.change) == [second])
        #expect(try await session.incoming(for: other, limit: 1).map(\.change) == [foreign])
        let deletion = GraphCloudIncoming(kind: .zoneDeleted, zone: zone)
        await session.receive(.incoming([control, deletion]), scope: .shared)
        #expect(try await session.incoming(for: zone, limit: 1).map(\.change) == [deletion])
        try await session.stop()
    }

}
