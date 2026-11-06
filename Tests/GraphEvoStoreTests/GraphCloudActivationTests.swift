import CloudKit
import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

/// Deterministic CAS and transport faults; native first-create behavior is proven separately on device.
actor ActivationServer {
    var authorities: [String: GraphCloudAuthorityRemote] = [:]
    var records: [String: GraphCloudIncoming] = [:]
    var sends = 0
    var offline = false
    var ambiguousClaim = false
    var ambiguousPublication = false
    var failRecordOnce = false
    private var sizeRejectedRecord: String?
    func rejectSize(of record: GraphNodeID) { sizeRejectedRecord = "node." + record.rawValue.uuidString.lowercased() }
    func configure(offline: Bool = false, claim: Bool = false, publication: Bool = false, record: Bool = false) {
        self.offline = offline; ambiguousClaim = claim; ambiguousPublication = publication; failRecordOnce = record
    }
    func check() throws { if offline { throw URLError(.notConnectedToInternet) } }
    func key(_ route: GraphCloudBinding) -> String { route.zone.name }
    func fetch(_ route: GraphCloudBinding) throws -> GraphCloudAuthorityRemote? { try check(); return authorities[key(route)] }
    func save(_ value: GraphCloudAuthority, route: GraphCloudBinding, base: GraphCloudAuthorityRemote?) throws -> GraphCloudAuthorityRemote {
        try check()
        let name = key(route)
        guard authorities[name]?.value == base?.value else { throw CKError(.serverRecordChanged) }
        let native = try GraphCloudAuthorityCodec.encode(value, binding: route, base: base)
        let saved = try GraphCloudAuthorityCodec.decode(native, binding: route)
        authorities[name] = saved
        if !value.published && ambiguousClaim { ambiguousClaim = false; throw URLError(.timedOut) }
        if value.published && ambiguousPublication { ambiguousPublication = false; throw URLError(.timedOut) }
        return saved
    }
    func inventory(_ route: GraphCloudBinding) throws -> [GraphCloudIncoming] {
        try check()
        var result = records.values.filter { $0.zone == route.zone && $0.kind == .recordChanged }
        if let authority = authorities[key(route)] {
            result.append(try GraphCloudRecordCodec.archive(GraphCloudRecordCodec.restore(authority.archive), scope: .private))
        }
        return result
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        try check(); sends += 1
        var saved: [GraphCloudIncoming] = [], deleted: [String] = [], failed: [GraphCloudRecordFailure] = []
        for item in batch.items {
            if item.recordName == sizeRejectedRecord {
                failed.append(.init(recordName: item.recordName, code: CKError.Code.limitExceeded.rawValue))
                continue
            }
            if failRecordOnce { failRecordOnce = false; failed.append(.init(recordName: item.recordName, code: CKError.networkFailure.rawValue)); continue }
            if let archive = item.recordArchive {
                let record = try GraphCloudRecordCodec.restore(archive)
                if let reference = item.assetReference {
                    guard let root = batch.assetRoot else { throw GraphCloudError.invalidState }
                    let spool = try GraphCloudAssetSpool(root: root)
                    record["asset"] = try await spool.read(reference, role: .outgoing, identity: reference.identity,
                        binding: reference.binding, recordName: item.recordName,
                        storeID: reference.storeID, epoch: reference.epoch) as CKRecordValue
                }
                let value = try GraphCloudRecordCodec.archive(record, scope: .private, portableAsset: true)
                records[batch.zone.name + item.recordName] = value; saved.append(value)
            } else {
                records.removeValue(forKey: batch.zone.name + item.recordName); deleted.append(item.recordName)
            }
        }
        return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: failed)
    }
    func removeRecord(_ id: GraphNodeID, route: GraphCloudBinding) { records.removeValue(forKey: route.zone.name + "node." + id.rawValue.uuidString.lowercased()) }
    func removeAuthority(_ route: GraphCloudBinding) { authorities.removeValue(forKey: key(route)) }
    func injectAuthority(_ value: GraphCloudAuthority, route: GraphCloudBinding) throws {
        authorities[key(route)] = try GraphCloudAuthorityCodec.decode(GraphCloudAuthorityCodec.encode(value, binding: route, base: nil), binding: route)
    }
    func injectRecord(_ record: CKRecord, route: GraphCloudBinding) throws {
        records[route.zone.name + record.recordID.recordName] = try GraphCloudRecordCodec.archive(record, scope: .private, portableAsset: true)
    }
    nonisolated var service: GraphCloudActivationService {
        .init(ensureZone: { _, _ in try await self.check() }, fetch: { _, route in try await self.fetch(route) },
              save: { _, route, value, base in try await self.save(value, route: route, base: base) },
              inventory: { _, _, route, _ in
                  var inventory = try GraphCloudActivationInventory()
                  for record in try await self.inventory(route) { try inventory.store(record) }
                  return inventory
              })
    }
    nonisolated var adapter: GraphCloudAdapter {
        .init(activation: service, account: { _ in "synthetic-activation-account" }, make: { _, _, _, callback in
            GraphCloudDriver(fetch: { _ in }, cancel: {}, send: { batch in
                await callback(.sent(try await self.send(batch)))
            })
        })
    }
}

// Every fixture performs a backed-up native conversion. Serialize independent
// cases rather than saturating the full suite with simultaneous migrations.
@Suite(.serialized, .timeLimit(.minutes(2))) struct GraphCloudActivationTests {
    private struct Fixture {
        let root: URL
        let manager: GraphContextManager
        let graph: GraphStore
        let config: GraphCloudConfiguration
        let zone: GraphCloudZone
        let invoice: GraphNodeID
        let operation: UUID
        let nodeIDs: Set<GraphNodeID>
        var route: GraphCloudBinding { .init(zone: zone, graphID: graph.id) }
    }
    private var declaration: GraphCloudCutoverDeclaration {
        .init(sourceSelection: "Synthetic selected source", completeness: "Exact fixture inventory",
              stoppedWriters: "Fixture writer detached", returningClients: "No legacy writers in this fixture")
    }
    private func manager(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties, adapter: adapter)
    }
    private func fixture(_ server: ActivationServer, oversized: Bool = false, attachments: Bool = false, id: GraphID = GraphID(), container: String? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Activation-" + UUID().uuidString)
        let m = manager()
        let source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("Target.sqlite")
        let legacyIDs = try await seedConversionSource(source)
        let bootstrap = try await m.openGraph(convertingLocalV1: .init(sourceURL: source, destinationURL: target,
            graphID: id, operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Synthetic activation"))
        let graph = try bootstrap.opening.get()
        let invoice = try #require(bootstrap.conversion.receipt.nodeIDs[legacyIDs[0]])
        if !oversized {
            // An explicit consumer edit prepares the fixture; MF10 itself never changes binary representation.
            _ = try await graph.transaction { try $0.patch(.init(id: invoice, properties: ["binary": .set(.data(Data([1,2,3])))])) }
        }
        var nodeIDs = Set(bootstrap.conversion.receipt.nodeIDs.values)
        if attachments {
            let file = try GraphAttachmentPayload(id: graph.makeNodeID(), ownerID: invoice, fileName: "fixture.bin", contentType: "public.data", data: Data(repeating: 7, count: 2 * 1024 * 1024))
            let fileID = try await graph.transaction { try $0.insert(file) }
            nodeIDs.insert(fileID)
        }
        let config = GraphCloudConfiguration(containerIdentifier: container ?? "iCloud.activation." + UUID().uuidString,
            environment: .development, directory: root.appendingPathComponent("Cloud"))
        _ = try await m.startCloudSession(config, adapter: server.adapter)
        return .init(root: root, manager: m, graph: graph, config: config,
                     zone: .init(scope: .private, owner: "owner", name: "activation"), invoice: invoice, operation: UUID(),
                     nodeIDs: nodeIDs)
    }
    private func prepare(_ f: Fixture) async throws -> GraphCloudActivationStatus {
        try await f.manager.prepareCloudActivation(for: f.graph.id, activationID: f.operation, zone: f.zone,
            configuration: f.config, declaration: declaration)
    }
    private func publish(_ f: Fixture) async throws {
        _ = try await prepare(f)
        for _ in 0..<5 {
            let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
            if let error = result.operationError { throw error }
            if result.status.phase == .published { return }
        }
        throw GraphCloudActivationError.recoveryRequired
    }
    private func close(_ f: Fixture) async throws {
        try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    private func patch(_ graph: GraphStore, id: GraphNodeID) async throws {
        _ = try await graph.transaction { try $0.patch(.init(id: id, properties: ["name": .set(.string("Later"))])) }
    }

    @Test func seedRecordSizeRejectionIsReportedWithoutPublishing() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await server.rejectSize(of: f.invoice)
        _ = try await prepare(f)
        let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect((result.operationError as? CKError)?.code == .limitExceeded)
        #expect(result.status.phase != .published)
        #expect(try await server.fetch(f.route)?.value.published == false)
        try await close(f)
    }

    @Test func preparesImmutableSeedBlocksAliasesAndPublishesBeforeUnlocking() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: GraphCloudActivationError.recoveryRequired) {
            try await f.manager.bindCloudZone(f.zone, to: f.graph.id, configuration: f.config)
        }
        let invitation = GraphCloudInvitation(container: f.config.containerIdentifier, environment: .development,
            graphID: f.graph.id, owner: "foreign-owner", zoneName: "shared", recipient: "synthetic-activation-account", url: URL(string: "https://example.test/invitation")!)
        await #expect(throws: GraphCloudActivationError.invalidRequest) { try await f.manager.acceptCloudInvitation(invitation, configuration: f.config) }
        let status = try await prepare(f)
        #expect(status.phase == .prepared && status.recordCount == 5)
        let alias = try await f.manager.openGraph(id: f.graph.id, at: f.root.appendingPathComponent("Target.sqlite"))
        await #expect(throws: GraphStoreError.self) { try await patch(alias, id: f.invoice) }
        #expect(try await alias.read { try $0.record(for: f.invoice)?.properties["name"] } == .string("Retained"))
        await #expect(throws: GraphCloudActivationError.recoveryRequired) {
            try await f.manager.bindCloudZone(f.zone, to: f.graph.id, configuration: f.config)
        }
        let sent = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(sent.status.phase == .seeding && sent.operationError == nil)
        await #expect(throws: GraphStoreError.self) { try await patch(f.graph, id: f.invoice) }
        let ready = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(ready.status.phase == .published && ready.operationError == nil)
        try await patch(alias, id: f.invoice)
        #expect(await server.sends == 1)
        try await alias.close(); try await close(f)
    }

    @Test func explicitPayloadBudgetRefusesBeforeClaimingOrLockingGraph() async throws {
        let server = ActivationServer(), f = try await fixture(server, oversized: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: GraphCloudActivationError.limitExceeded) {
            _ = try await f.manager.prepareCloudActivation(for: f.graph.id, activationID: f.operation, zone: f.zone,
                configuration: f.config, declaration: declaration, limits: .init(maximumPayloadBytes: 1))
        }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id) == nil)
        #expect(try await server.fetch(f.route) == nil)
        try await patch(f.graph, id: f.invoice)
        try await close(f)
    }

    @Test func ambiguousClaimAndPublicationRecoverTheSameAuthority() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        await server.configure(claim: true)
        let claim = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(claim.status.phase == .claiming && claim.operationError != nil)
        #expect(await server.sends == 0)
        let seed = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(seed.operationError == nil && seed.status.activationID == f.operation)
        await server.configure(publication: true)
        let publication = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(publication.status.phase == .publishing && publication.operationError != nil)
        await #expect(throws: GraphStoreError.self) { try await patch(f.graph, id: f.invoice) }
        let ready = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(ready.status.phase == .published && ready.operationError == nil)
        #expect(await server.sends == 1)
        try await close(f)
    }

    @Test func restartRestoresWriteGateWithoutStartingCloud() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        try await close(f)
        let next = manager(), graph = try await next.openGraph(id: f.graph.id, at: f.root.appendingPathComponent("Target.sqlite"))
        await #expect(throws: GraphStoreError.self) { try await patch(graph, id: f.invoice) }
        #expect(try await next.cloudActivationStatus(for: graph.id)?.activationID == f.operation)
        _ = try await next.startCloudSession(f.config, adapter: server.adapter)
        for _ in 0..<3 { _ = try await next.advanceCloudActivation(for: graph.id, configuration: f.config) }
        try await patch(graph, id: f.invoice)
        try await graph.close(); try await next.stopCloudSession(f.config)
    }

    @Test func foreignAuthorityPreservesLocalConversionAndReleasesOnlyItsGate() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        let foreign = GraphCloudAuthority(graphID: f.graph.id, activationID: UUID(), seedDigest: String(repeating: "a", count: 64),
            recordCount: 5, conversionCommitment: String(repeating: "b", count: 64))
        try await server.injectAuthority(foreign, route: f.route)
        let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(result.status.phase == .conflict && result.operationError as? GraphCloudActivationError == .authorityConflict)
        try await patch(f.graph, id: f.invoice)
        #expect(await server.sends == 0)
        await #expect(throws: GraphCloudActivationError.recoveryRequired) { _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config) }
        try await close(f)
    }

    @Test func partialSendResumesFrozenWorkAndNeverPublishesEarly() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f); await server.configure(record: true)
        let partial = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(partial.status.phase == .seeding && partial.operationError != nil)
        #expect(try await server.fetch(f.route)?.value.published == false)
        for _ in 0..<3 { _ = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config) }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id)?.phase == .published)
        #expect(await server.sends == 2)
        try await close(f)
    }

    @Test func publishesAndRecoversSeedAboveTheFormerAggregatePayloadLimit() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let ids = (0..<36).map { _ in f.graph.makeNodeID() }
        let value = String(repeating: "x", count: 720_000)
        try await f.graph.transaction { scope in
            for id in ids {
                try scope.insert(GraphRecord(id: id, type: "Seed.Large", properties: ["value": .string(value)]))
            }
        }
        let prepared = try await prepare(f)
        var phase = prepared.phase
        for _ in 0..<ids.count + 4 where phase != .published {
            let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
            if let error = result.operationError { throw error }
            phase = result.status.phase
        }
        #expect(phase == .published)
        let sends = await server.sends
        try await close(f)

        let peer = manager()
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development,
            directory: f.root.appendingPathComponent("LargePeerCloud"))
        _ = try await peer.startCloudSession(config, adapter: server.adapter)
        let opened = try await peer.openCloudReplica(id: f.graph.id, at: f.root.appendingPathComponent("LargePeer.sqlite"),
            zone: f.zone, configuration: config)
        let replica = try opened.opening.get()
        #expect(try await replica.read { scope in
            try ids.allSatisfy { try scope.record(for: $0)?.properties["value"] == .string(value) }
        })
        #expect(try await replica.collectSyncChanges() == 0)
        #expect(await server.sends == sends)
        try await replica.close()
        try await peer.stopCloudSession(config)
    }

    @Test func emptyPeerRecoversExactIDsAndValuesWithoutUploadFeedback() async throws {
        let server = ActivationServer(), f = try await fixture(server, attachments: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f)
        try await patch(f.graph, id: f.invoice)
        let later = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config)
        #expect(later.transportError == nil && later.failures.isEmpty)
        let expected = try await f.graph.read { scope in try f.nodeIDs.compactMap { try scope.record(for: $0) } }
        let sends = await server.sends
        try await close(f)
        let next = manager()
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development,
            directory: f.root.appendingPathComponent("PeerCloud"))
        _ = try await next.startCloudSession(config, adapter: server.adapter)
        let result = try await next.openCloudReplica(id: f.graph.id, at: f.root.appendingPathComponent("Peer.sqlite"), zone: f.zone, configuration: config)
        let graph = try result.opening.get()
        let actual = try await graph.read { scope in try f.nodeIDs.compactMap { try scope.record(for: $0) } }
        #expect(Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) }))
        #expect(try await graph.collectSyncChanges() == 0)
        #expect(await server.sends == sends)
        try await graph.close(); try await next.stopCloudSession(config)
    }

    @Test func privateRecoveryOfASharedGraphSeparatesDescriptorAndNativeShareFromApplicationRows() async throws {
        let server = ActivationServer(), f = try await fixture(server, attachments: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f)
        let expected = try await f.graph.read { scope in try f.nodeIDs.compactMap { try scope.record(for: $0) } }
        try await server.injectRecord(GraphCloudGraphDescriptor.encode(f.route), route: f.route)
        let share = CKShare(recordZoneID: GraphCloudGraphDescriptor.id(in: f.zone).zoneID)
        share.publicPermission = .none
        try await server.injectRecord(share, route: f.route)
        let sends = await server.sends
        try await close(f)
        let next = manager(), config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier,
            environment: .development, directory: f.root.appendingPathComponent("SharedOwnerPeerCloud"))
        _ = try await next.startCloudSession(config, adapter: server.adapter)
        let result = try await next.openCloudReplica(id: f.graph.id, at: f.root.appendingPathComponent("SharedOwnerPeer.sqlite"), zone: f.zone, configuration: config)
        let graph = try result.opening.get()
        let actual = try await graph.read { scope in try f.nodeIDs.compactMap { try scope.record(for: $0) } }
        #expect(Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) }))
        #expect(try await graph.validateIntegrity() == f.nodeIDs.count)
        #expect(try await graph.collectSyncChanges() == 0)
        #expect(await server.sends == sends)
        try await graph.close(); try await next.stopCloudSession(config)
    }

    @Test func activationAndEmptyPeerAcceptAssetBytesBeyondInlinePayloadAllowance() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var attachments: [GraphAttachmentMetadata] = []
        for index in 0..<4 {
            let payload = try GraphAttachmentPayload(id: f.graph.makeNodeID(), ownerID: f.invoice,
                fileName: "part-\(index).bin", contentType: "public.data", data: Data(repeating: UInt8(index + 1), count: 9 * 1024 * 1024))
            _ = try await f.graph.transaction { try $0.insert(payload) }
            attachments.append(payload.content.metadata)
        }
        try await publish(f)
        #expect(await server.sends >= 2)
        try await close(f)
        let next = manager()
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development,
            directory: f.root.appendingPathComponent("LargePeerCloud"))
        _ = try await next.startCloudSession(config, adapter: server.adapter)
        let result = try await next.openCloudReplica(id: f.graph.id,
            at: f.root.appendingPathComponent("LargePeer.sqlite"), zone: f.zone, configuration: config)
        let graph = try result.opening.get()
        for metadata in attachments {
            #expect(try await graph.attachment(metadata.id)?.metadata == metadata)
        }
        try await graph.close(); try await next.stopCloudSession(config)
    }

    @Test func missingAuthorityAfterClaimNeverRecreatesOrUnlocks() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        _ = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        await server.removeAuthority(f.route)
        let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(result.operationError as? GraphCloudActivationError == .recoveryRequired)
        #expect(try await server.fetch(f.route) == nil)
        await #expect(throws: GraphStoreError.self) { try await patch(f.graph, id: f.invoice) }
        try await close(f)
    }

    @Test func separatelyConvertedStoreCannotPublishCompetingUUIDs() async throws {
        let server = ActivationServer(), winner = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: winner.root) }
        try await publish(winner)
        let authority = try #require(try await server.fetch(winner.route))
        try await close(winner)
        let loser = try await fixture(server, id: winner.graph.id, container: winner.config.containerIdentifier)
        defer { try? FileManager.default.removeItem(at: loser.root) }
        #expect(winner.nodeIDs.isDisjoint(with: loser.nodeIDs))
        _ = try await prepare(loser)
        let result = try await loser.manager.advanceCloudActivation(for: loser.graph.id, configuration: loser.config)
        #expect(result.operationError as? GraphCloudActivationError == .authorityConflict)
        #expect(try await server.fetch(loser.route)?.value == authority.value)
        #expect(await server.sends == 1)
        try await close(loser)
    }

    @Test func unrelatedGraphProgressAndManualPauseSurvivePreparation() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.manager.pauseCloudSynchronization(for: f.graph.id)
        _ = try await prepare(f)
        #expect(try await f.manager.cloudSynchronizationState(for: f.graph.id) == .paused)
        let other = try await f.manager.createGraph(id: .init(), at: f.root.appendingPathComponent("Other.sqlite"))
        let nodeID = other.makeNodeID()
        _ = try await other.transaction { try $0.insert(GraphRecord(id: nodeID, type: "Other")) }
        #expect(try await other.read { try $0.record(for: nodeID) } != nil)
        let stalled = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(stalled.operationError as? GraphCloudError == .graphPaused)
        #expect(await server.sends == 0)
        try await f.manager.resumeCloudSynchronization(for: f.graph.id)
        for _ in 0..<3 { _ = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config) }
        try await other.close(); try await close(f)
    }

    @Test func preexistingZoneBodiesAndChangedRequestsAreRefused() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        await #expect(throws: GraphCloudActivationError.authorityConflict) {
            _ = try await f.manager.prepareCloudActivation(for: f.graph.id, activationID: UUID(), zone: f.zone, configuration: f.config, declaration: declaration)
        }
        let foreign = try GraphCloudNodeCodec.encode(GraphRecord(id: .init(graphID: f.graph.id), type: "Foreign"), binding: f.route)
        try await server.injectRecord(foreign, route: f.route)
        let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(result.operationError as? GraphCloudActivationError == .zoneNotEmpty)
        #expect(try await server.fetch(f.route) == nil)
        #expect(await server.sends == 0)
        try await close(f)
    }

    @Test func cancelledPreparationHasNoMarkerAndOfflineClaimRemainsRecoverable() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await prepare(f)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id) == nil)
        _ = try await prepare(f)
        await server.configure(offline: true)
        let result = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(result.status.phase == .claiming && result.operationError != nil)
        #expect(await server.sends == 0)
        await server.configure()
        for _ in 0..<3 { _ = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config) }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id)?.phase == .published)
        try await close(f)
    }

    @Test func nativeAuthorityCodecAndManifestAreDeterministicAndRejectCorruption() throws {
        let id = GraphID(), route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: id)
        let a = try GraphRecord(id: .init(graphID: id), type: "Item", properties: ["null": .null, "value": .integer(3)])
        let b = try GraphRecord(id: .init(graphID: id), type: "Other", createdDate: nil)
        let records = try [a,b].map { try GraphCloudNodeCodec.encode($0, binding: route) }
        let manifest = try GraphCloudSeedManifest.make(records, binding: route, limits: .init())
        #expect(try manifest == GraphCloudSeedManifest.make(records.reversed(), binding: route, limits: .init()))
        let authority = GraphCloudAuthority(graphID: id, activationID: UUID(), seedDigest: try manifest.digest,
            recordCount: 2, conversionCommitment: String(repeating: "a", count: 64))
        let record = try GraphCloudAuthorityCodec.encode(authority, binding: route, base: nil)
        #expect(try GraphCloudAuthorityCodec.decode(record, binding: route).value == authority)
        record["unexpected"] = "refuse" as CKRecordValue
        #expect(throws: GraphCloudActivationError.invalidState) { _ = try GraphCloudAuthorityCodec.decode(record, binding: route) }
    }

    @Test(arguments: ["records", "payload", "declaration", "shared"])
    func preflightRefusalsDoNotPublishOrRetainAdmission(_ mode: String) async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let zone = mode == "shared" ? GraphCloudZone(scope: .shared, owner: f.zone.owner, name: f.zone.name) : f.zone
        let declared = mode == "declaration" ? GraphCloudCutoverDeclaration(sourceSelection: "", completeness: "", stoppedWriters: "", returningClients: "") : declaration
        let limits = GraphCloudActivationLimits(maximumRecords: mode == "records" ? 1 : 10_000, maximumPayloadBytes: mode == "payload" ? 1 : 32 * 1024 * 1024)
        await #expect(throws: GraphCloudActivationError.self) {
            _ = try await f.manager.prepareCloudActivation(for: f.graph.id, activationID: f.operation, zone: zone,
                configuration: f.config, declaration: declared, limits: limits)
        }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id) == nil)
        #expect(await server.sends == 0)
        try await patch(f.graph, id: f.invoice)
        try await close(f)
    }

    @Test func convertedOwnerCannotBeReusedAsAnEmptyPeer() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f); try await close(f)
        let next = manager()
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development, directory: f.root.appendingPathComponent("PeerCloud"))
        _ = try await next.startCloudSession(config, adapter: server.adapter)
        await #expect(throws: GraphCloudActivationError.authorityConflict) {
            _ = try await next.openCloudReplica(id: f.graph.id, at: f.root.appendingPathComponent("Target.sqlite"), zone: f.zone, configuration: config)
        }
        let original = try await next.openGraph(id: f.graph.id, at: f.root.appendingPathComponent("Target.sqlite"))
        #expect(try await original.validateIntegrity() == 5)
        try await original.close(); try await next.stopCloudSession(config)
    }

    @Test func changedNativeConversionReceiptIsRefusedBeforeExposingRecoveredHandles() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f); try await close(f)
        let registry = StoreRegistry()
        let raw = try await registry.open(.init(location: .sqlite(f.root.appendingPathComponent("Target.sqlite")), exclusiveGraphID: f.graph.id.rawValue), schema: GraphRuntimeSchema.typedProperties)
        let id = f.graph.id
        try await raw.controlTransaction { context in
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            root[dynamicMember: GraphV1NativeConversion.receiptKey] = Data([0])
            context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
        }
        try await raw.close()
        let next = manager()
        await #expect(throws: GraphCloudActivationError.invalidState) { _ = try await next.openGraph(id: id, at: f.root.appendingPathComponent("Target.sqlite")) }
        #expect(await server.sends == 0)
        #expect(await next.registeredGraphCount == 0)
    }

    @Test func sameVolumeRelocationRetainsAuthorityButCopiedNativeStoreCannotTakeOver() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        let moved = f.root.deletingLastPathComponent().appendingPathComponent("Moved-" + UUID().uuidString)
        let clone = f.root.deletingLastPathComponent().appendingPathComponent("RejectedClone-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: f.root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: clone)
        }
        _ = try await prepare(f); try await close(f)
        try FileManager.default.moveItem(at: f.root, to: moved)
        let next = manager(), graph = try await next.openGraph(id: f.graph.id, at: moved.appendingPathComponent("Target.sqlite"))
        #expect(try await next.cloudActivationStatus(for: f.graph.id)?.activationID == f.operation)
        await #expect(throws: GraphStoreError.self) { try await patch(graph, id: f.invoice) }
        try await graph.close()
        // Deliberate rejected clone, never a fresh-replica fixture. A native copy can retain UUID/PH metadata.
        try FileManager.default.copyItem(at: moved, to: clone)
        let other = manager()
        await #expect(throws: GraphCloudActivationError.invalidState) { _ = try await other.openGraph(id: f.graph.id, at: clone.appendingPathComponent("Target.sqlite")) }
        #expect(await server.sends == 0)
    }

    @Test func foregroundWorkerWaitsForPublicationAndResumesWithoutClearingAStickyFailure() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await prepare(f)
        _ = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        let clock = AutomaticTestClock()
        try await f.manager.setAutomaticCloudSynchronizationActive(true, configuration: f.config, clock: clock.value)
        let deadline = ContinuousClock.now + .seconds(10)
        while try await f.manager.automaticCloudSynchronizationStatus(for: f.graph.id, configuration: f.config).phase != .suspended {
            guard ContinuousClock.now < deadline else { throw GraphCloudActivationError.busy }
            await Task.yield()
        }
        #expect(await server.sends == 1)
        let published = try await f.manager.advanceCloudActivation(for: f.graph.id, configuration: f.config)
        #expect(published.status.phase == .published && published.operationError == nil)
        try await patch(f.graph, id: f.invoice)
        while await server.sends < 2 {
            guard ContinuousClock.now < deadline else { throw GraphCloudActivationError.busy }
            clock.advance(1)
            await Task.yield()
        }
        #expect(try await f.manager.automaticCloudSynchronizationStatus(for: f.graph.id, configuration: f.config).phase != .blocked)
        try await f.manager.setAutomaticCloudSynchronizationActive(false, configuration: f.config)
        try await close(f)
    }

    @Test func ordinarySharedBindingDoesNotReadPrivateActivationControl() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ActivationScope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), server = ActivationServer()
        let graph = try await m.createGraph(id: .init(), at: root.appendingPathComponent("Shared.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.activation." + UUID().uuidString, environment: .development, directory: root.appendingPathComponent("Cloud"))
        var adapter = server.adapter
        let original = server.service
        adapter.activation = .init(ensureZone: original.ensureZone, fetch: { _, _ in throw GraphCloudActivationError.unavailable }, save: original.save, inventory: original.inventory)
        _ = try await m.startCloudSession(config, adapter: adapter)
        let zone = GraphCloudZone(scope: .shared, owner: "foreign-owner", name: "shared-zone")
        try await m.bindCloudZone(zone, to: graph.id, configuration: config)
        #expect(try await m.cloudBinding(for: zone, configuration: config)?.graphID == graph.id)
        try await graph.close(); try await m.stopCloudSession(config)
    }

    @Test func unmarkedOrdinaryGraphCannotBindAnAuthoritativePrivateZone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ActivationBinding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), server = ActivationServer()
        let graph = try await m.createGraph(id: .init(), at: root.appendingPathComponent("Plain.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.activation." + UUID().uuidString, environment: .development, directory: root.appendingPathComponent("Cloud"))
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "authoritative")
        let route = GraphCloudBinding(zone: zone, graphID: graph.id)
        try await server.injectAuthority(.init(graphID: graph.id, activationID: UUID(), seedDigest: String(repeating: "a", count: 64), recordCount: 1,
            conversionCommitment: String(repeating: "b", count: 64), published: true), route: route)
        _ = try await m.startCloudSession(config, adapter: server.adapter)
        await #expect(throws: GraphCloudActivationError.recoveryRequired) { try await m.bindCloudZone(zone, to: graph.id, configuration: config) }
        #expect(try await m.cloudBinding(for: zone, configuration: config) == nil)
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "Local")) }
        try await graph.close(); try await m.stopCloudSession(config)
    }

    @Test func missingPublishedAuthorityBlocksOrdinarySendsWithoutRecreatingIt() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f)
        await server.removeAuthority(f.route)
        try await patch(f.graph, id: f.invoice)
        await #expect(throws: GraphCloudActivationError.recoveryRequired) { _ = try await f.manager.sendCloudChanges(for: f.graph.id, configuration: f.config) }
        #expect(await server.sends == 1)
        #expect(try await server.fetch(f.route) == nil)
        #expect(try await f.graph.collectSyncChanges() > 0)
        try await close(f)
    }

    @Test func observedControlDeletionDurablyBlocksTheSessionSendBoundary() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f)
        let session = try await f.manager.cloud(f.config)
        let deletion = GraphCloudIncoming(kind: .recordDeleted, zone: f.zone, recordName: GraphCloudAuthorityCodec.recordName, recordType: GraphCloudAuthorityCodec.recordType)
        await session.receive(.incoming([deletion]), scope: .private)
        #expect(await session.pendingActivationIDs.contains(f.graph.id))
        #expect(try await session.incoming(for: f.zone, limit: 100).isEmpty)
        try await patch(f.graph, id: f.invoice)
        let binding = GraphCloudTransportBinding(identity: try await session.identity(), route: f.route)
        let batch = try await f.graph.prepareTransport(binding)
        await #expect(throws: GraphCloudActivationError.recoveryRequired) { try await session.send(batch) }
        try await close(f)
        let next = manager()
        _ = try await next.startCloudSession(f.config, adapter: server.adapter)
        #expect(await (try next.cloud(f.config)).pendingActivationIDs.contains(f.graph.id))
        try await next.stopCloudSession(f.config)
        #expect(await server.sends == 1)
    }

    @Test func nativeInventoryBudgetIncludesPropertyAndControlRows() async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.nodeIDs.count == 5)
        try await f.graph.read { scope in
            try scope.withContext { context, _ in
                #expect(throws: GraphCloudActivationError.limitExceeded) { try GraphCloudActivationNative.validateInventory(context, maximum: 10) }
                try GraphCloudActivationNative.validateInventory(context)
            }
        }
        #expect(try await f.manager.cloudActivationStatus(for: f.graph.id) == nil)
        try await close(f)
    }
    @Test(arguments: [false, true])
    func interruptedPeerDropsRowsAbsentFromTheNewCompleteServerCut(empty: Bool) async throws {
        let server = ActivationServer(), f = try await fixture(server)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await publish(f)
        let optional = try #require(try await f.graph.read { scope in
            try f.nodeIDs.compactMap { try scope.record(for: $0) }.first { $0.type == "optional" }?.id
        })
        try await close(f)
        var adapter = GraphCoordinatorFactory.adapter
        let original = try #require(adapter.activation)
        adapter.activation = .init(requiresActivation: original.requiresActivation, read: original.read, prepare: original.prepare,
            write: { context, id, value in
                if value.peer && value.phase == .published { throw GraphCloudActivationError.recoveryRequired }
                try original.write(context, id, value)
            }, peer: original.peer, replicaIDs: original.replicaIDs)
        let first = manager(adapter: adapter)
        let config = GraphCloudConfiguration(containerIdentifier: f.config.containerIdentifier, environment: .development, directory: f.root.appendingPathComponent("InterruptedPeerCloud"))
        _ = try await first.startCloudSession(config, adapter: server.adapter)
        let target = f.root.appendingPathComponent("InterruptedPeer.sqlite")
        let interrupted = try await first.openCloudReplica(id: f.graph.id, at: target, zone: f.zone, configuration: config)
        #expect(interrupted.status.phase == .recovering)
        #expect(throws: GraphCloudActivationError.recoveryRequired) { _ = try interrupted.opening.get() }
        try await first.stopCloudSession(config)
        for id in empty ? f.nodeIDs : [optional] { await server.removeRecord(id, route: f.route) }
        let next = manager()
        _ = try await next.startCloudSession(config, adapter: server.adapter)
        let recovered = try await next.openCloudReplica(id: f.graph.id, at: target, zone: f.zone, configuration: config)
        let graph = try recovered.opening.get()
        #expect(try await graph.read { try $0.record(for: optional) } == nil)
        #expect(try await graph.validateIntegrity() == (empty ? 0 : 4))
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try await next.stopCloudSession(config)
    }

}
