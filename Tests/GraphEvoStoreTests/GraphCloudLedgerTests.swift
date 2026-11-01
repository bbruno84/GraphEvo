import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor LedgerSaveGate {
    var entered = false
    var released = false
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var waits: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true; let values = arrivals; arrivals.removeAll(); for value in values { value.resume() }
        if !released { await withCheckedContinuation { waits.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; let values = waits; waits.removeAll(); for value in values { value.resume() } }
}
private actor LedgerServer {
    var stored: GraphLedger?
    var tag = UUID()
    var fetches = 0, saves = 0
    var offline = false, failAfterCommit = false
    var collisions = 0
    var gate: LedgerSaveGate?
    func configure(offline: Bool = false, ambiguous: Bool = false, collisions: Int = 0, gate: LedgerSaveGate? = nil) {
        self.offline = offline; failAfterCommit = ambiguous; self.collisions = collisions; self.gate = gate
    }
    func remote() -> GraphLedgerRemote? { stored.map { .init(value: $0, recordArchive: Data(tag.uuidString.utf8)) } }
    func inject(_ value: GraphLedger) { stored = value; tag = UUID() }
    func fetch() throws -> GraphLedgerRemote? {
        fetches += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return remote()
    }
    func save(_ value: GraphLedger, base: GraphLedgerRemote?) async throws -> GraphLedgerRemote {
        saves += 1
        let held = gate; gate = nil; if let held { await held.enter() }
        if offline { throw URLError(.notConnectedToInternet) }
        if collisions > 0 { collisions -= 1; tag = UUID(); throw CKError(.serverRecordChanged) }
        guard base?.value.revision == stored?.revision, base?.recordArchive == remote()?.recordArchive else { throw CKError(.serverRecordChanged) }
        stored = value; tag = UUID()
        if failAfterCommit { failAfterCommit = false; throw URLError(.timedOut) }
        return remote()!
    }
    nonisolated var service: GraphLedgerService {
        .init(fetch: { _, _ in try await self.fetch() }, save: { _, _, value, base in try await self.save(value, base: base) })
    }
    nonisolated var adapter: GraphCloudAdapter {
        .init(ledger: service, account: { _ in "ledger-test-account" }, make: { _, _, _, _ in GraphCloudDriver(fetch: { _ in }, cancel: {}) })
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudLedgerTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Ledger-" + UUID().uuidString) }
    private func configuration(_ root: URL, events: Int = 4096) -> GraphCloudConfiguration {
        .init(containerIdentifier: "iCloud.ledger." + UUID().uuidString, environment: .development, directory: root, maximumEvents: events)
    }
    private func binding(_ id: GraphID, scope: GraphCloudScope = .private) -> GraphCloudBinding {
        .init(zone: .init(scope: scope, owner: "owner", name: "ledger-zone"), graphID: id)
    }
    private func wait(_ condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            do { if try await condition() { return } } catch GraphCloudError.busy {}
            guard ContinuousClock.now < deadline else { throw GraphCloudError.invalidState }
            await Task.yield()
        }
    }
    private func begin(_ session: GraphCloudSession, _ id: GraphID, phase: String = "prepare") async throws -> GraphLedgerStatus {
        try await session.updateLedger(id, mutation: .begin(kind: "migration", phase: phase, information: Data("{\"consumer\":1}".utf8)), expectedRevision: nil)
    }
    private func member(_ session: GraphCloudSession, route: GraphCloudBinding, permission: GraphCloudSharePermission) async throws -> GraphCloudMembership {
        .init(binding: route, identity: try await session.identity(control: true), generation: UUID(), role: .participant,
              phase: .active, permission: permission, storeID: "fixture-store", hadAccess: true, shareIdentity: "fixture-share")
    }

    @Test func restartRetainsBoundedPendingStateAndRequiresExplicitRecovery() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration(root), server = LedgerServer(), id = GraphID()
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        try await session.bind(binding(id)); let initial = try await begin(session, id)
        let operation = try #require(initial.ledger?.current?.id)
        for _ in 0..<20 { _ = try await session.updateLedger(id, mutation: .retry(operation: operation, failure: "Consumer retry"), expectedRevision: nil) }
        #expect(try await session.ledgerStatus(id).ledger?.history.count == 1)
        #expect(await server.saves == 0)
        try await session.stop()
        let reopened = try await GraphCloudSession.open(config, adapter: server.adapter)
        let recovered = try await reopened.ledgerStatus(id)
        #expect(recovered.state == .recoveryRequired && recovered.ledger?.current?.attempts == 21)
        await #expect(throws: GraphLedgerError.recoveryRequired) { try await reopened.updateLedger(id, mutation: .progress(operation: operation, phase: "convert"), expectedRevision: nil) }
        _ = try await reopened.updateLedger(id, mutation: .resume(operation: operation), expectedRevision: recovered.ledger?.revision)
        let sent = try await reopened.synchronizeLedger(id)
        #expect(sent.state == .idle && sent.confirmedRevision == sent.ledger?.revision)
        #expect(sent.ledger?.current?.id == operation && sent.ledger?.current?.attempts == 22)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("session.json"))) as? [String: Any])
        #expect((raw["ledgers"] as? [Any])?.count == 1)
        try await reopened.stop()
    }

    @Test func conflictsPreserveLocalWorkAndContinueRefreshingTheRemoteView() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), a = try await GraphCloudSession.open(configuration(root.appendingPathComponent("A")), adapter: server.adapter)
        let b = try await GraphCloudSession.open(configuration(root.appendingPathComponent("B")), adapter: server.adapter)
        try await a.bind(binding(id)); try await b.bind(binding(id))
        let initial = try await begin(a, id)
        _ = try await a.updateLedger(id, mutation: .finish(operation: #require(initial.ledger?.current?.id), outcome: .succeeded, summary: "Completed"), expectedRevision: nil)
        _ = try await a.synchronizeLedger(id); _ = try await b.synchronizeLedger(id)
        let left = try await begin(a, id, phase: "left"), right = try await begin(b, id, phase: "right")
        _ = try await a.synchronizeLedger(id)
        let conflict = try await b.synchronizeLedger(id)
        #expect(conflict.state == .conflict && conflict.ledger?.revision == right.ledger?.revision)
        #expect(conflict.remote?.revision == left.ledger?.revision)
        _ = try await a.updateLedger(id, mutation: .progress(operation: #require(left.ledger?.current?.id), phase: "left-new"), expectedRevision: nil)
        _ = try await a.synchronizeLedger(id)
        #expect(try await b.synchronizeLedger(id).remote?.current?.phase == "left-new")
        await #expect(throws: GraphLedgerError.conflict) { try await b.updateLedger(id, mutation: .information(Data("{}".utf8)), expectedRevision: nil) }
        let accepted = try await b.synchronizeLedger(id, discardPending: true)
        #expect(accepted.state == .idle && accepted.ledger?.current?.phase == "left-new")
        #expect(await server.saves == 3)
        try await a.stop(); try await b.stop()
    }

    @Test(arguments: [false, true]) func inFlightSuccessOrAmbiguityAcknowledgesOnlyTheSentRevision(ambiguous: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        try await session.bind(binding(id)); let three = try await begin(session, id, phase: "3")
        let gate = LedgerSaveGate(); await server.configure(ambiguous: ambiguous, gate: gate)
        let sending = Task { try await session.synchronizeLedger(id) }
        await gate.wait()
        let four = try await session.updateLedger(id, mutation: .progress(operation: #require(three.ledger?.current?.id), phase: "4"), expectedRevision: three.ledger?.revision)
        await gate.release()
        if ambiguous { await #expect(throws: URLError.self) { try await sending.value } }
        else {
            let oldSuccess = try await sending.value
            #expect(oldSuccess.ledger?.revision == four.ledger?.revision && oldSuccess.state == .pending)
            #expect(oldSuccess.confirmedRevision == three.ledger?.revision)
        }
        let latest = try await session.synchronizeLedger(id)
        #expect(latest.state == .idle && latest.ledger?.current?.phase == "4" && latest.confirmedRevision == four.ledger?.revision)
        #expect(latest.ledger?.history.count == 2 && latest.ledger?.current?.attempts == 1)
        #expect(await server.saves == 2)
        try await session.stop()
    }

    @Test func tagCollisionRetriesOnceWithoutReplayingTheConsumerMutation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        try await session.bind(binding(id)); _ = try await begin(session, id); _ = try await session.synchronizeLedger(id)
        let desired = try await session.updateLedger(id, mutation: .information(Data("{\"key\":1}".utf8)), expectedRevision: nil)
        await server.configure(collisions: 1)
        let saved = try await session.synchronizeLedger(id)
        #expect(saved.state == .idle && saved.ledger == desired.ledger)
        #expect(await server.saves == 3)
        try await session.stop()
    }

    @Test func repeatedNativeCollisionsRemainPendingAfterOneRetry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        try await session.bind(binding(id)); let desired = try await begin(session, id)
        await server.configure(collisions: 3)
        await #expect(throws: CKError.self) { try await session.synchronizeLedger(id) }
        #expect(await server.saves == 2)
        #expect(try await session.ledgerStatus(id).ledger == desired.ledger)
        #expect(try await session.ledgerStatus(id).state == .pending)
        try await session.stop()
    }

    @Test func stopDrainsAdmittedControlAndRestartRecoversAmbiguousSave() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration(root), server = LedgerServer(), id = GraphID()
        let session = try await GraphCloudSession.open(config, adapter: server.adapter)
        try await session.bind(binding(id)); let desired = try await begin(session, id)
        let gate = LedgerSaveGate(); await server.configure(gate: gate)
        let sending = Task { try await session.synchronizeLedger(id) }
        await gate.wait()
        let stopping = Task { try await session.stop() }
        try await wait { do { _ = try await session.identity(control: true); return false } catch GraphCloudError.stopping { return true } }
        await gate.release()
        await #expect(throws: GraphCloudError.stopping) { try await sending.value }
        try await stopping.value
        let reopened = try await GraphCloudSession.open(config, adapter: server.adapter)
        let recovered = try await reopened.synchronizeLedger(id)
        #expect(recovered.ledger == desired.ledger && recovered.confirmedRevision == desired.ledger?.revision)
        #expect(recovered.state == .recoveryRequired)
        #expect(await server.saves == 1)
        try await reopened.stop()
    }

    @Test func removedParticipationEndsObserversAndLateSaveCannotReinsertLedger() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        let route = binding(id, scope: .shared)
        var membership = try await member(session, route: route, permission: .readWrite)
        try await session.updateMembership(membership); try await session.bind(route)
        _ = try await begin(session, id)
        let stream = try await session.observeLedger(id)
        var observer = stream.makeAsyncIterator(); _ = await observer.next()
        let gate = LedgerSaveGate(); await server.configure(gate: gate)
        let sending = Task { try await session.synchronizeLedger(id) }
        await gate.wait()
        membership.phase = .purging
        try await session.updateMembership(membership)
        let ended = await observer.next()
        #expect(ended?.state == .unavailable && ended?.ledger == nil)
        #expect(await observer.next() == nil)
        await gate.release()
        await #expect(throws: (any Error).self) { try await sending.value }
        try await session.completePurge(id, generation: membership.generation)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("session.json"))) as? [String: Any])
        #expect((raw["ledgers"] as? [Any])?.isEmpty == true)
        await #expect(throws: (any Error).self) { try await session.ledgerStatus(id) }
        try await session.stop()
    }

    @Test func lateFailureCannotAnnotateReplacementParticipationLedger() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        let route = binding(id, scope: .shared)
        var membership = try await member(session, route: route, permission: .readWrite)
        try await session.updateMembership(membership); try await session.bind(route)
        _ = try await begin(session, id)
        let old = try await session.ensureLedger(id, writing: false)
        membership.phase = .purging; try await session.updateMembership(membership)
        try await session.completePurge(id, generation: membership.generation)
        var replacement = try await session.beginMembership(route, storeID: "replacement-store", shareIdentity: "replacement-share")
        replacement.phase = .active; replacement.hadAccess = true; replacement.permission = .readWrite
        try await session.updateMembership(replacement); try await session.bind(route)
        let fresh = try await begin(session, id, phase: "new-participation")
        await #expect(throws: GraphLedgerError.unavailable) {
            try await session.recordLedgerFailure(id, generation: old.generation, error: CKError(.quotaExceeded))
        }
        #expect(try await session.ledgerStatus(id) == fresh)
        #expect(try await session.ensureLedger(id, writing: false).generation != old.generation)
        try await session.stop()
    }

    @Test func accountChangeTerminatesLedgerObservationWithoutExposingCachedData() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        try await session.bind(binding(id)); _ = try await begin(session, id)
        let stream = try await session.observeLedger(id)
        var observer = stream.makeAsyncIterator(); _ = await observer.next()
        await session.receive(.account("different-account"), scope: .private)
        let ended = await observer.next()
        #expect(ended?.state == .unavailable && ended?.ledger == nil)
        #expect(await observer.next() == nil)
        await #expect(throws: GraphCloudError.accountChanged) { try await session.ledgerStatus(id) }
        await #expect(throws: GraphCloudError.accountChanged) { try await session.synchronizeLedger(id) }
        #expect(await server.saves == 0)
        try await session.stop()
    }

    @Test func failedLocalLedgerWriteRetainsPreviousDurableAndVisibleState() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID()
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, data in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: data)
            if doc.ledgers.contains(where: { $0.value.current != nil }) { throw GraphCloudError.persistence }
            try GraphCloudDisk.live.write(url, data)
        })
        let session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter, disk: disk)
        try await session.bind(binding(id)); let before = try await session.ledgerStatus(id)
        let bytes = try Data(contentsOf: root.appendingPathComponent("session.json"))
        await #expect(throws: GraphCloudError.persistence) { try await begin(session, id) }
        #expect(try await session.ledgerStatus(id) == before)
        #expect(try Data(contentsOf: root.appendingPathComponent("session.json")) == bytes)
        #expect(await server.saves == 0)
        try await session.stop()
    }

    @Test func readOnlyPendingControlKeepsIncomingRefreshAndCannotWrite() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root), adapter: server.adapter)
        let route = binding(id, scope: .shared)
        var membership = try await member(session, route: route, permission: .readWrite)
        try await session.updateMembership(membership); try await session.bind(route)
        _ = try await begin(session, id)
        membership.permission = .readOnly; try await session.updateMembership(membership)
        let pending = try await session.synchronizeLedger(id)
        #expect(pending.state == .pending && pending.failure != nil)
        let remote = try GraphLedger.empty(id).applying(.begin(kind: "owner", phase: "convert", information: Data("{}".utf8)), origin: UUID(), date: Date())
        await server.inject(remote)
        let updated = try await session.synchronizeLedger(id)
        #expect(updated.state == .conflict && updated.remote == remote && updated.ledger == pending.ledger)
        await #expect(throws: GraphLedgerError.readOnly) { try await session.updateLedger(id, mutation: .information(Data("{}".utf8)), expectedRevision: nil) }
        #expect(await server.saves == 0)
        try await session.stop()
    }

    @Test func controlHintsBypassApplicationInboxLimitsWithoutEnteringTheInbox() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), id = GraphID(), session = try await GraphCloudSession.open(configuration(root, events: 2), adapter: server.adapter)
        let route = binding(id); try await session.bind(route)
        let local = try await begin(session, id)
        let record = try GraphLedgerCodec.encode(#require(local.ledger), binding: route, base: nil)
        let incoming = try GraphCloudRecordCodec.archive(record, scope: .private)
        await session.receive(.incoming(Array(repeating: incoming, count: 100)), scope: .private)
        #expect(await session.status().inboxCount == 0)
        await session.receive(.incoming(Array(repeating: .init(kind: .zoneChanged, zone: route.zone), count: 2)), scope: .private)
        #expect(await session.status().failure == .inboxLimit)
        #expect(try await session.synchronizeLedger(id).state == .idle)
        #expect(await session.status().inboxCount == 0)
        #expect(await server.saves == 1)
        try await session.stop()
    }

    @Test func oldAlphaDocumentIsRefusedWithoutModification() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), config = configuration(root), session = try await GraphCloudSession.open(config, adapter: server.adapter)
        try await session.stop()
        let url = root.appendingPathComponent("session.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]); raw["format"] = 5
        let old = try JSONSerialization.data(withJSONObject: raw); try old.write(to: url)
        await #expect(throws: GraphCloudError.invalidState) { try await GraphCloudSession.open(config, adapter: server.adapter) }
        #expect(try Data(contentsOf: url) == old)
    }

    @Test(arguments: [GraphCloudScope.private, .shared]) func nativeCodecRoundTripsAndPreservesUnrelatedControlFields(scope: GraphCloudScope) throws {
        let id = GraphID(), route = binding(id, scope: scope)
        let initial = GraphLedger.empty(id)
        let record = try GraphLedgerCodec.encode(initial, binding: route, base: nil)
        record["future"] = "keep" as CKRecordValue
        let initialBytes = try #require(record["payload"] as? Data)
        var envelope = try #require(JSONSerialization.jsonObject(with: initialBytes) as? [String: Any])
        envelope["futureSection"] = ["keep": true]
        record["payload"] = try JSONSerialization.data(withJSONObject: envelope) as CKRecordValue
        let remote = try GraphLedgerCodec.decode(record, binding: route)
        let next = try initial.applying(.information(Data("{\"app\":true}".utf8)), origin: UUID(), date: Date())
        let updated = try GraphLedgerCodec.encode(next, binding: route, base: remote)
        #expect(updated["future"] as? String == "keep")
        let updatedBytes = try #require(updated["payload"] as? Data)
        let preserved = try #require(JSONSerialization.jsonObject(with: updatedBytes) as? [String: Any])
        #expect((preserved["futureSection"] as? [String: Bool])?["keep"] == true)
        #expect(try GraphLedgerCodec.decode(updated, binding: route).value == next)
        let foreign = binding(GraphID(), scope: scope)
        #expect(throws: (any Error).self) { try GraphLedgerCodec.decode(updated, binding: foreign) }
        #expect(GraphLedgerCodec.isControl(try GraphCloudRecordCodec.archive(updated, scope: scope)))
    }

    @Test func dataPauseDoesNotPauseLedgerOrAddPHWorkAndBackupEvidenceIsScoped() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), m = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let id = GraphID(), graph = try await m.createGraph(id: id, at: root.appendingPathComponent("Graph.sqlite"))
        let config = configuration(root.appendingPathComponent("Engine")); _ = try await m.startCloudSession(config, adapter: server.adapter)
        try await m.bindCloudZone(binding(id).zone, to: id, configuration: config)
        try await m.pauseCloudSynchronization(for: id)
        _ = try await m.updateGraphLedger(for: id, configuration: config, mutation: .begin(kind: "migration", phase: "prepare", information: Data("{}".utf8)))
        #expect(try await m.reconcileGraphLedger(for: id, configuration: config).state == .idle)
        #expect(try await m.cloudSynchronizationState(for: id) == .paused)
        #expect(try await graph.collectSyncChanges() == 0)
        _ = try await m.updateGraphLedger(for: id, configuration: config, mutation: .information(Data("{\"marker\":1}".utf8)))
        let backup = try await m.createBackup(for: id, in: root.appendingPathComponent("Backups"))
        let restored = try await m.backups.restore(at: backup.url, to: root.appendingPathComponent("Restored"))
        let evidence = try #require(backup.manifest.files.first { $0.path.hasSuffix("__graphevo_cloud_0.json") })
        let snapshot = try JSONDecoder().decode(GraphCloudBackupSnapshot.self, from: Data(contentsOf: restored.directory.appendingPathComponent(evidence.path)))
        #expect(snapshot.ledger?.pending == true && snapshot.ledger?.value.graphID == id)
        try await graph.close()
        #expect(try await m.graphLedger(for: id, configuration: config).ledger?.current?.kind == "migration")
        try await m.stopCloudSession(config)
    }

    @Test func automaticEditDuringSendPublishesNewRevisionWithoutPeriodicDelay() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), clock = AutomaticTestClock(), gate = LedgerSaveGate()
        let m = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let id = GraphID(), graph = try await m.createGraph(id: id, at: root.appendingPathComponent("Graph.sqlite"))
        let config = configuration(root.appendingPathComponent("Engine")); _ = try await m.startCloudSession(config, adapter: server.adapter)
        try await m.bindCloudZone(binding(id).zone, to: id, configuration: config)
        try await m.pauseCloudSynchronization(for: id)
        let initial = try await m.updateGraphLedger(for: id, configuration: config, mutation: .begin(kind: "migration", phase: "3", information: Data("{}".utf8)))
        await server.configure(gate: gate)
        try await m.setAutomaticCloudSynchronizationActive(true, configuration: config, clock: clock.value)
        await gate.wait()
        let latest = try await m.updateGraphLedger(for: id, configuration: config,
            mutation: .progress(operation: #require(initial.ledger?.current?.id), phase: "4"))
        await gate.release()
        try await wait { try await m.graphLedger(for: id, configuration: config).confirmedRevision == latest.ledger?.revision }
        #expect(clock.now == 0)
        #expect(await server.stored?.current?.phase == "4")
        #expect(await server.saves == 2)
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try await m.stopCloudSession(config)
    }

    @Test func automaticControlContinuesDuringPauseAndRespectsInactivityAndBackoff() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LedgerServer(), clock = AutomaticTestClock()
        let m = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let id = GraphID(), graph = try await m.createGraph(id: id, at: root.appendingPathComponent("Graph.sqlite"))
        let config = configuration(root.appendingPathComponent("Engine")); _ = try await m.startCloudSession(config, adapter: server.adapter)
        try await m.bindCloudZone(binding(id).zone, to: id, configuration: config); try await m.pauseCloudSynchronization(for: id)
        _ = try await m.updateGraphLedger(for: id, configuration: config, mutation: .begin(kind: "migration", phase: "prepare", information: Data("{}".utf8)))
        await server.configure(offline: true)
        try await m.setAutomaticCloudSynchronizationActive(true, configuration: config, clock: clock.value)
        let key = config.namespace + ":private"
        try await wait { await m.ledgerWorkers[key]?.retryDeadline(id) == 5 }
        let before = await server.fetches
        _ = try await m.updateGraphLedger(for: id, configuration: config, mutation: .information(Data("{\"retry\":1}".utf8)))
        clock.advance(4)
        #expect(await server.fetches == before)
        await server.configure(); clock.advance(1)
        try await wait { try await m.graphLedger(for: id, configuration: config).state == .idle }
        try await m.setAutomaticCloudSynchronizationActive(false, configuration: config, clock: clock.value)
        let saves = await server.saves
        _ = try await m.updateGraphLedger(for: id, configuration: config, mutation: .information(Data("{\"retry\":2}".utf8)))
        clock.advance(120)
        #expect(await server.saves == saves)
        try await m.setAutomaticCloudSynchronizationActive(true, configuration: config, clock: clock.value)
        try await wait { try await m.graphLedger(for: id, configuration: config).state == .idle }
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try await m.stopCloudSession(config)
    }
}
