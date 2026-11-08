import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

/// The synchronous native-driver factory and async account provider share only locked test state.
private final class AccountDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GraphCloudAccountAvailability = .available("account-A")
    private var callbacks: [GraphCloudScope: @Sendable (GraphCloudEvent) async -> Void] = [:]
    private var serializations: [Data?] = []
    private let notificationName: Notification.Name?
    private var availabilityHook: (@Sendable () async -> GraphCloudAccountAvailability)?
    init(notificationName: Notification.Name? = nil) { self.notificationName = notificationName }
    func set(_ value: GraphCloudAccountAvailability) { lock.withLock { self.value = value } }
    var availability: GraphCloudAccountAvailability { lock.withLock { value } }
    var restored: [Data?] { lock.withLock { serializations } }
    func hook(_ body: (@Sendable () async -> GraphCloudAccountAvailability)?) { lock.withLock { availabilityHook = body } }
    func readAvailability() async -> GraphCloudAccountAvailability {
        let hook = lock.withLock { availabilityHook }
        if let hook { return await hook() }; return availability
    }
    func emit(_ event: GraphCloudEvent) async { await lock.withLock { callbacks[.private] }?(event) }
    var adapter: GraphCloudAdapter {
        var adapter = GraphCloudAdapter(account: { [self] _ in
            guard case .available(let account) = availability else { throw GraphCloudError.accountUnavailable }
            return account
        }, make: { [self] _, scope, state, callback in
            lock.withLock { callbacks[scope] = callback; serializations.append(state) }
            return GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        adapter.accountAvailability = { [self] _ in await readAvailability() }
        if let notificationName {
            adapter.observeAccount = { GraphCloudAccountObservation(name: notificationName, changed: $0) }
        }
        return adapter
    }
}

private actor AccountQueryGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        arrived = true; let values = arrivals; arrivals.removeAll(); for value in values { value.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; let values = releases; releases.removeAll(); for value in values { value.resume() } }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudAccountTests {
    private struct Fixture {
        let root: URL
        let manager: GraphContextManager
        let graph: GraphStore
        let driver: AccountDriver
        let configuration: GraphCloudConfiguration
        let node: GraphNodeID
    }
    private func manager() -> GraphContextManager {
        GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
    }
    private func fixture(driver: AccountDriver = AccountDriver()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountIsolation-" + UUID().uuidString)
        let manager = manager()
        let configuration = GraphCloudConfiguration(containerIdentifier: "iCloud.account." + UUID().uuidString,
            environment: .development, directory: root.appendingPathComponent("Cloud-A"))
        _ = try await manager.startCloudSession(configuration, adapter: driver.adapter)
        let graph = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let node = graph.makeNodeID()
        let record = try GraphRecord(id: node, type: ObservedItem.graphType, properties: ["value": .integer(1)])
        try await graph.transaction { try $0.insert(record) }
        try await manager.bindCloudZone(.init(scope: .private, owner: "owner", name: "A"), to: graph.id, configuration: configuration)
        return Fixture(root: root, manager: manager, graph: graph, driver: driver, configuration: configuration, node: node)
    }
    private func close(_ f: Fixture) async throws {
        try await f.graph.close(); try await f.manager.stopCloudSession(f.configuration)
        try FileManager.default.removeItem(at: f.root)
    }
    private func isAccountIsolation(_ error: any Error) -> Bool {
        if case GraphStoreError.accountIsolated = error { return true }; return false
    }

    @Test func logoutBlocksEveryLeaseButNotLocalGraphsAndSameAccountReturns() async throws {
        let f = try await fixture()
        let sibling = try await f.manager.openGraph(id: f.graph.id, at: f.root.appendingPathComponent("A.sqlite"))
        let local = try await f.manager.createGraph(id: GraphID(), at: f.root.appendingPathComponent("Local.sqlite"))
        #expect(try await f.graph.cloudAccountState == .available)
        let query = try observationQuery(), observed = try await sibling.observe(observationQuery())
        _ = try await waitForObservation(observed) { $0.items.count == 1 }
        let state = try await f.graph.observeCloudAccountState()
        var states = state.makeAsyncIterator()
        #expect(await states.next() == .available)
        f.driver.set(.signedOut)
        await f.driver.emit(.account(nil))
        #expect(await states.next() == .isolated(.signedOut))
        for graph in [f.graph, sibling] {
            await #expect { try await graph.read { try $0.record(for: f.node) } } throws: { isAccountIsolation($0) }
            await #expect { try await graph.transaction { _ in () } } throws: { isAccountIsolation($0) }
        }
        #expect(try await local.cloudAccountState == .localOnly)
        #expect(try await local.read { _ in true })
        var iterator = observed.makeAsyncIterator()
        guard case .failure(let error)? = await iterator.next() else { Issue.record("Missing account observation termination"); return }
        #expect(error is GraphObservationError)
        if let _ = await iterator.next() { Issue.record("Old query observation did not terminate") }
        f.driver.set(.available("account-A"))
        try await f.manager.refreshCloudAccount(f.configuration)
        #expect(try await f.graph.cloudAccountState == .available)
        #expect(try await sibling.read { try $0.record(for: f.node)?.properties["value"] } == .integer(1))
        let next = try await sibling.observe(query)
        _ = try await waitForObservation(next) { $0.items.count == 1 }
        next.cancel(); observed.cancel(); state.cancel()
        try await sibling.close(); try await local.close(); try await close(f)
    }

    @Test func temporaryUnavailabilityPreservesLocalWritesAndFrozenAttempt() async throws {
        let f = try await fixture()
        let route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "A"), graphID: f.graph.id)
        let binding = GraphCloudTransportBinding(identity: .init(container: f.configuration.containerIdentifier,
            environment: .development, account: "account-A"), route: route)
        let original = try await f.graph.prepareTransport(binding)
        await f.driver.emit(.state(Data([7])))
        f.driver.set(.temporarilyUnavailable)
        await #expect(throws: GraphCloudError.accountUnavailable) { try await f.manager.refreshCloudAccount(f.configuration) }
        #expect(try await f.graph.cloudAccountState == .temporarilyUnavailable)
        let id = f.graph.makeNodeID(), record = try GraphRecord(id: id, type: "Offline")
        try await f.graph.transaction { try $0.insert(record) }
        #expect(try await f.graph.read { try $0.record(for: id) } != nil)
        f.driver.set(.available("account-A"))
        try await f.manager.refreshCloudAccount(f.configuration)
        #expect(try await f.graph.prepareTransport(binding) == original)
        #expect(f.driver.restored.last! == Data([7]))
        #expect(try await f.graph.collectSyncChanges() == 2)
        try await close(f)
    }

    @Test func explicitStartupRetriesAvailabilityAfterTemporaryFailure() async throws {
        let f = try await fixture()
        f.driver.set(.temporarilyUnavailable)
        await #expect(throws: GraphCloudError.accountUnavailable) {
            try await f.manager.startCloudSession(f.configuration, adapter: f.driver.adapter)
        }
        #expect(try await f.graph.cloudAccountState == .temporarilyUnavailable)
        f.driver.set(.available("account-A"))
        _ = try await f.manager.startCloudSession(f.configuration, adapter: f.driver.adapter)
        #expect(try await f.graph.cloudAccountState == .available)
        try await close(f)
    }

    @Test func accountsUseDistinctStoresAndNeverRelabelOriginalData() async throws {
        let f = try await fixture()
        await f.driver.emit(.state(Data([1])))
        f.driver.set(.available("account-B"))
        await f.driver.emit(.account("account-B"))
        #expect(try await f.graph.cloudAccountState == .isolated(.differentAccount))
        await #expect(throws: GraphCloudError.accountChanged) { try await f.manager.refreshCloudAccount(f.configuration) }
        await #expect { try await f.graph.read { try $0.record(for: f.node) } } throws: { isAccountIsolation($0) }
        try await f.manager.stopCloudSession(f.configuration)
        let b = GraphCloudConfiguration(containerIdentifier: f.configuration.containerIdentifier,
            environment: .development, directory: f.root.appendingPathComponent("Cloud-B"))
        _ = try await f.manager.startCloudSession(b, adapter: f.driver.adapter)
        let graphB = try await f.manager.createGraph(id: GraphID(), at: f.root.appendingPathComponent("B.sqlite"))
        try await f.manager.bindCloudZone(.init(scope: .private, owner: "owner", name: "B"), to: graphB.id, configuration: b)
        #expect(try await graphB.cloudAccountState == .available)
        #expect(try await f.graph.cloudAccountState == .isolated(.differentAccount))
        try await f.manager.stopCloudSession(b)
        f.driver.set(.available("account-A"))
        _ = try await f.manager.startCloudSession(f.configuration, adapter: f.driver.adapter)
        #expect(try await f.graph.cloudAccountState == .available)
        #expect(try await graphB.cloudAccountState == .isolated(.differentAccount))
        #expect(try await f.graph.read { try $0.record(for: f.node) } != nil)
        #expect(f.driver.restored.last! == nil)
        try await graphB.close(); try await close(f)
    }

    @Test func coldBoundStoreRequiresIdentityVerificationAndRetainsPendingWork() async throws {
        let f = try await fixture(), id = f.graph.id
        try await f.graph.close(); try await f.manager.stopCloudSession(f.configuration)
        let next = manager()
        let reopened = try await next.openGraph(id: id, at: f.root.appendingPathComponent("A.sqlite"))
        #expect(try await reopened.cloudAccountState == .isolated(.verificationRequired))
        await #expect { try await reopened.read { try $0.record(for: f.node) } } throws: { isAccountIsolation($0) }
        f.driver.set(.temporarilyUnavailable)
        await #expect(throws: GraphCloudError.accountUnavailable) { try await next.startCloudSession(f.configuration, adapter: f.driver.adapter) }
        #expect(try await reopened.cloudAccountState == .isolated(.verificationRequired))
        f.driver.set(.available("account-A"))
        try await next.refreshCloudAccount(f.configuration)
        #expect(try await reopened.read { try $0.record(for: f.node) } != nil)
        #expect(try await reopened.collectSyncChanges() == 1)
        try await reopened.close(); try await next.stopCloudSession(f.configuration)
        try FileManager.default.removeItem(at: f.root)
    }

    @Test func notificationsProtectLocalHandlesAfterExplicitCloudStopWithoutRestartingEngines() async throws {
        let name = Notification.Name("GraphEvo.AccountTest." + UUID().uuidString)
        let f = try await fixture(driver: AccountDriver(notificationName: name))
        let observation = try await f.graph.observeCloudAccountState()
        var iterator = observation.makeAsyncIterator()
        #expect(await iterator.next() == .available)
        try await f.manager.stopCloudSession(f.configuration)
        let creations = f.driver.restored.count
        f.driver.set(.signedOut); NotificationCenter.default.post(name: name, object: nil)
        #expect(await iterator.next() == .isolated(.signedOut))
        await #expect { try await f.graph.read { try $0.record(for: f.node) } } throws: { isAccountIsolation($0) }
        f.driver.set(.available("account-A")); NotificationCenter.default.post(name: name, object: nil)
        #expect(await iterator.next() == .available)
        #expect(f.driver.restored.count == creations)
        #expect(try await f.graph.read { try $0.record(for: f.node) } != nil)
        observation.cancel(); try await close(f)
    }

    @Test func notificationDuringVerificationInvalidatesItsResultAndChecksAgain() async throws {
        let name = Notification.Name("GraphEvo.AccountOverlap." + UUID().uuidString)
        let driver = AccountDriver(notificationName: name), f = try await fixture(driver: driver)
        try await f.manager.stopCloudSession(f.configuration)
        let gate = AccountQueryGate()
        driver.hook { await gate.enter(); return .available("account-A") }
        await f.manager.scheduleAccountRefresh(f.configuration.namespace)
        await gate.wait()
        driver.hook(nil); driver.set(.signedOut)
        // Delivery while the original query is pending must enqueue another verification.
        await f.manager.scheduleAccountRefresh(f.configuration.namespace)
        await gate.release()
        while await f.manager.accountRefreshTasks[f.configuration.namespace] != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await f.graph.cloudAccountState == .isolated(.signedOut))
        await #expect { try await f.graph.read { _ in () } } throws: { isAccountIsolation($0) }
        driver.set(.available("account-A"))
        try await f.manager.refreshCloudAccount(f.configuration)
        #expect(try await f.graph.cloudAccountState == .available)
        try await close(f)
    }

    @Test func temporaryStatusCannotUndoRestrictionsOrLogoutAndStaleExportsAreRefused() async throws {
        let f = try await fixture(), check = try await f.graph.accountCheck()
        f.driver.set(.restricted)
        await #expect(throws: GraphCloudError.accountUnavailable) { try await f.manager.refreshCloudAccount(f.configuration) }
        #expect(try await f.graph.cloudAccountState == .isolated(.restricted))
        f.driver.set(.temporarilyUnavailable)
        await #expect(throws: GraphCloudError.accountUnavailable) { try await f.manager.refreshCloudAccount(f.configuration) }
        #expect(try await f.graph.cloudAccountState == .isolated(.restricted))
        f.driver.set(.signedOut); await f.driver.emit(.account(nil))
        #expect(try await f.manager.cloudStatus(f.configuration).failure == .accountChanged)
        f.driver.set(.temporarilyUnavailable)
        await #expect(throws: GraphCloudError.accountUnavailable) { try await f.manager.refreshCloudAccount(f.configuration) }
        #expect(try await f.graph.cloudAccountState == .isolated(.signedOut))
        f.driver.set(.available("account-A")); try await f.manager.refreshCloudAccount(f.configuration)
        let destination = f.root.appendingPathComponent("Export.bin")
        await #expect { try await GraphAttachmentIO.export(Data([1, 2]), to: destination, check: check) } throws: { isAccountIsolation($0) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await close(f)
    }

    @Test func logoutPreservesOwnedAssetFilesInboxAndImmutableAttemptForOriginalAccount() async throws {
        let f = try await fixture()
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "A")
        let route = GraphCloudBinding(zone: zone, graphID: f.graph.id)
        let identity = GraphCloudSessionIdentity(container: f.configuration.containerIdentifier, environment: .development, account: "account-A")
        let file = try GraphAttachmentPayload(id: f.graph.makeNodeID(), ownerID: f.node, fileName: "pending.bin", contentType: "public.data", data: Data(repeating: 4, count: 4096))
        _ = try await f.graph.transaction { try $0.insert(file) }
        let binding = GraphCloudTransportBinding(identity: identity, route: route)
        let frozen = try await f.graph.prepareTransport(binding)
        #expect(frozen.items.compactMap(\.assetReference).count == 1)
        let remote = try GraphAttachmentPayload(id: f.graph.makeNodeID(), ownerID: f.node, fileName: "incoming.bin", contentType: "public.data", data: Data(repeating: 5, count: 512))
        let event = try GraphCloudRecordCodec.archive(GraphCloudNodeCodec.encode(remote.graphRecord(), binding: route), scope: .private, portableAsset: true)
        await f.driver.emit(.incoming([event])); await f.driver.emit(.state(Data([9])))
        let inbox = try await f.manager.cloudInbox(f.configuration)
        #expect(inbox.count == 1 && inbox[0].change.assetReference != nil)
        f.driver.set(.signedOut); await f.driver.emit(.account(nil))
        let document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: f.configuration.directory.appendingPathComponent("session.json")))
        #expect(document.account == "account-A" && document.inbox == inbox && document.states.isEmpty && document.accountResetRequired == true)
        f.driver.set(.available("account-A")); try await f.manager.refreshCloudAccount(f.configuration)
        #expect(try await f.graph.prepareTransport(binding) == frozen)
        #expect(try await f.manager.cloudInbox(f.configuration) == inbox)
        #expect(f.driver.restored.last! == nil)
        let session = try await f.manager.cloud(f.configuration)
        #expect(try await session.assetData(for: inbox[0].change, binding: route) == remote.content.data)
        let reference = try #require(frozen.items.compactMap(\.assetReference).first)
        let spool = try GraphCloudAssetSpool(root: #require(frozen.assetRoot))
        #expect(try await spool.read(reference, role: .outgoing, identity: identity, binding: route,
                                    recordName: reference.recordName, storeID: reference.storeID, epoch: reference.epoch) == file.content.data)
        try await close(f)
    }

    @Test func lateSuccessfulQueryCannotUndoAConfirmedLogout() async throws {
        let f = try await fixture(), gate = AccountQueryGate()
        f.driver.hook { await gate.enter(); return .available("account-A") }
        let checking = Task { try await f.manager.refreshCloudAccount(f.configuration) }
        await gate.wait()
        f.driver.set(.signedOut); await f.driver.emit(.account(nil))
        await gate.release()
        await #expect(throws: GraphCloudError.accountChanged) { try await checking.value }
        #expect(try await f.graph.cloudAccountState == .isolated(.signedOut))
        f.driver.hook(nil); try await close(f)
    }

    @Test func workingCopyInheritsSourceAccountWithoutReleasingMigrationHolds() async throws {
        let f = try await fixture()
        let workspace = try await f.manager.prepareMigrationWorkspace(for: f.graph.id, at: f.root.appendingPathComponent("Working"))
        #expect(try await workspace.graph.cloudAccountState == .available)
        f.driver.set(.signedOut); await f.driver.emit(.account(nil))
        #expect(try await workspace.graph.cloudAccountState == .isolated(.signedOut))
        await #expect { try await workspace.graph.read { try $0.record(for: f.node) } } throws: { isAccountIsolation($0) }
        await #expect { try await workspace.graph.transaction { _ in () } } throws: { isAccountIsolation($0) }
        f.driver.set(.available("account-A")); try await f.manager.refreshCloudAccount(f.configuration)
        #expect(try await workspace.graph.read { try $0.record(for: f.node) } != nil)
        await #expect { try await f.graph.transaction { _ in () } } throws: { if case GraphStoreError.writesSuspended = $0 { return true }; return false }
        try await workspace.close()
        try await f.graph.transaction { _ in () }
        try await close(f)
    }

    @available(iOS 17, macOS 14, *)
    @Test func oldNativeDriverCannotOfferRecordsAfterAccountInvalidation() async throws {
        let graphID = GraphID(), zone = GraphCloudZone(scope: .private, owner: "owner", name: "A")
        let id = GraphNodeID(graphID: graphID, rawValue: UUID())
        let binding = GraphCloudBinding(zone: zone, graphID: graphID)
        let record = try GraphCloudNodeCodec.encode(GraphRecord(id: id, type: "Private"), binding: binding)
        let archive = try GraphCloudRecordCodec.archive(record, scope: .private)
        let item = GraphCloudOutgoingNode(change: .init(id: id, nativeKind: "ManagedEntity", operation: .save, generation: 1),
            recordName: record.recordID.recordName, recordArchive: archive.recordArchive)
        let batch = GraphCloudOutgoingBatch(id: UUID(), graphID: graphID, zone: zone, items: [item])
        let outbox = GraphCloudNativeOutbox()
        try await outbox.begin(batch)
        outbox.accountFence.invalidate()
        await #expect(throws: GraphCloudError.accountChanged) { try await outbox.next(.init()) }
        try await outbox.finish()
        await #expect(throws: GraphCloudError.accountChanged) { try await outbox.begin(batch) }
    }
}
