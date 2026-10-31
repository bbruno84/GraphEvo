import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class CloudFake: @unchecked Sendable {
    let lock = NSLock()
    private var callbacks: [GraphCloudScope: @Sendable (GraphCloudEvent) async -> Void] = [:]
    private var creations: [GraphCloudScope: Int] = [:]
    private var restored: [GraphCloudScope: Data] = [:]
    private var cancelCount = 0
    private var cancelledWithFailure = false
    private var fetchHook: (@Sendable () async throws -> Void)?
    private var cancelHook: (@Sendable () async throws -> Void)?
    func hooks(fetch: (@Sendable () async throws -> Void)? = nil, cancel: (@Sendable () async throws -> Void)? = nil) {
        lock.withLock { fetchHook = fetch; cancelHook = cancel }
    }
    private var events: [GraphCloudScope: [GraphCloudEvent]] = [:]
    private var fetchZones: [GraphCloudScope: [GraphCloudZone]] = [:]
    var failCancel: Bool {
        get { lock.withLock { cancelledWithFailure } }
        set { lock.withLock { cancelledWithFailure = newValue } }
    }
    var cancellations: Int { lock.withLock { cancelCount } }
    func count(_ scope: GraphCloudScope) -> Int { lock.withLock { creations[scope, default: 0] } }
    func restoration(_ scope: GraphCloudScope) -> Data? { lock.withLock { restored[scope] } }
    func zones(_ scope: GraphCloudScope) -> [GraphCloudZone] { lock.withLock { fetchZones[scope] ?? [] } }
    func queue(_ events: [GraphCloudEvent], scope: GraphCloudScope) { lock.withLock { self.events[scope] = events } }
    func emit(_ event: GraphCloudEvent, scope: GraphCloudScope) async {
        let callback = lock.withLock { callbacks[scope] }
        await callback?(event)
    }
    var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "account-test" }, make: { [self] _, scope, state, callback in
            lock.withLock {
                creations[scope, default: 0] += 1; restored[scope] = state; callbacks[scope] = callback
            }
            return GraphCloudDriver(fetch: { [self] zones in
                let work = lock.withLock { fetchZones[scope] = zones; return events[scope] ?? [] }
                let hook = lock.withLock { fetchHook }; try await hook?()
                for event in work { await callback(event) }
            }, cancel: { [self] in
                let fail = lock.withLock { cancelCount += 1; return cancelledWithFailure }
                if fail { throw GraphCloudError.persistence }
                let hook = lock.withLock { cancelHook }; try await hook?()
            })
        })
    }
}

private actor CloudSignal {
    private var signalled = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !signalled { await withCheckedContinuation { waiting.append($0) } } }
    func signal() { signalled = true; let values = waiting; waiting.removeAll(); for value in values { value.resume() } }
}

@Suite(.timeLimit(.minutes(2))) struct GraphCloudSessionTests {
    private func config(maximumEvents: Int = 4096, maximumBytes: Int = 32 * 1024 * 1024) -> GraphCloudConfiguration {
        GraphCloudConfiguration(containerIdentifier: "iCloud.test.\(UUID())", environment: .development,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("CloudSession-\(UUID())"),
            maximumEvents: maximumEvents, maximumBytes: maximumBytes)
    }
    private func zone(_ scope: GraphCloudScope = .private, _ name: String = "A") -> GraphCloudZone {
        GraphCloudZone(scope: scope, owner: "owner", name: name)
    }
    private func manager() -> GraphContextManager {
        GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func create(_ manager: GraphContextManager, _ config: GraphCloudConfiguration, _ name: String = "A") async throws -> GraphStore {
        try await manager.createGraph(id: GraphID(), at: config.directory.appendingPathComponent("\(name).sqlite"))
    }
    private func document(_ config: GraphCloudConfiguration) throws -> GraphCloudDocument {
        try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: config.directory.appendingPathComponent("session.json")))
    }

    @Test func concurrentStartsShareEnginesAndOtherManagersCannotDuplicate() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await m.startCloudSession(config, adapter: fake.adapter) } }
            try await group.waitForAll()
        }
        #expect(fake.count(.private) == 1 && fake.count(.shared) == 0)
        let other = manager()
        await #expect(throws: GraphCloudError.ownershipConflict) { try await other.startCloudSession(config, adapter: CloudFake().adapter) }
        try await m.stopCloudSession(config)
        _ = try await other.startCloudSession(config, adapter: CloudFake().adapter)
        try await other.stopCloudSession(config)
    }

    @Test func exactRoutingSharedLazinessAndGraphCloseDoNotStopSession() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let a = try await create(m, config), b = try await create(m, config, "B")
        try await m.bindCloudZone(zone(), to: a.id, configuration: config)
        try await m.bindCloudZone(zone(.shared), to: b.id, configuration: config)
        #expect(fake.count(.private) == 1 && fake.count(.shared) == 1)
        #expect(try await m.cloudBinding(for: zone(), configuration: config)?.graphID == a.id)
        #expect(try await m.cloudBinding(for: zone(.shared), configuration: config)?.graphID == b.id)
        await #expect(throws: GraphCloudError.ownershipConflict) { try await m.bindCloudZone(zone(.private, "other"), to: a.id, configuration: config) }
        await #expect(throws: GraphCloudError.ownershipConflict) { try await m.bindCloudZone(zone(), to: b.id, configuration: config) }
        try await a.close(); try await b.close()
        try await m.fetchCloudChanges(.private, configuration: config)
        try await m.fetchCloudChanges(.shared, configuration: config)
        #expect(fake.zones(.private) == [zone()] && fake.zones(.shared) == [zone(.shared)])
        #expect(try await m.cloudStatus(config).scopes.count == 2)
        try await m.stopCloudSession(config)
    }

    @Test func inboxAndBothEngineStatesSurviveReopenWithoutGraphEdits() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let a = try await create(m, config), b = try await create(m, config, "B")
        try await m.bindCloudZone(zone(), to: a.id, configuration: config)
        try await m.bindCloudZone(zone(.shared), to: b.id, configuration: config)
        let incoming = GraphCloudIncoming(kind: .recordDeleted, zone: zone(), recordName: "deleted", recordType: "Fixture")
        await fake.emit(.incoming([incoming]), scope: .private)
        await fake.emit(.state(Data([1])), scope: .private)
        await fake.emit(.state(Data([2])), scope: .shared)
        #expect(try await a.collectSyncChanges() == 0)
        #expect(try await b.collectSyncChanges() == 0)
        let before = try await m.cloudInbox(config)
        try await a.close(); try await b.close(); try await m.stopCloudSession(config)
        let second = CloudFake()
        _ = try await m.startCloudSession(config, adapter: second.adapter)
        #expect(second.restoration(.private) == Data([1]) && second.restoration(.shared) == Data([2]))
        #expect(second.count(.shared) == 1)
        #expect(try await m.cloudInbox(config) == before)
        try await m.stopCloudSession(config)
    }

    @Test func receivedEventsPrecedeCheckpointAndReplayIsRetained() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let event = GraphCloudIncoming(kind: .zoneDeleted, zone: zone(.private, "unknown"), deletionReason: "purged")
        await fake.emit(.incoming([event]), scope: .private)
        #expect(try document(config).states.isEmpty)
        try await m.stopCloudSession(config)
        let second = CloudFake(); _ = try await m.startCloudSession(config, adapter: second.adapter)
        await second.emit(.incoming([event]), scope: .private)
        await second.emit(.state(Data([3])), scope: .private)
        let inbox = try await m.cloudInbox(config)
        #expect(inbox.map(\.change) == [event, event] && Set(inbox.map(\.id)).count == 2)
        #expect(try await m.cloudBinding(for: event.zone, configuration: config) == nil)
        #expect(try document(config).states["private"] == Data([3]))
        try await m.stopCloudSession(config)
    }

    @Test func failedWriteBlocksLaterCheckpointsAndRetainsPreviousDocument() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, data in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: data)
            if !doc.inbox.isEmpty { throw GraphCloudError.persistence }
            try GraphCloudDisk.live.write(url, data)
        })
        _ = try await m.startCloudSession(config, adapter: fake.adapter, disk: disk)
        await fake.emit(.state(Data([1])), scope: .private)
        await fake.emit(.incoming([GraphCloudIncoming(kind: .zoneChanged, zone: zone())]), scope: .private)
        await fake.emit(.state(Data([2])), scope: .private)
        #expect(try await m.cloudStatus(config).failure == .persistence)
        #expect(try document(config).states["private"] == Data([1]) && document(config).inbox.isEmpty)
        await #expect(throws: GraphCloudError.persistence) { try await m.fetchCloudChanges(.private, configuration: config) }
        try await m.stopCloudSession(config)
    }

    @Test(arguments: [true, false]) func limitsStopWithoutAdvancing(_ countLimit: Bool) async throws {
        let config = config(maximumEvents: countLimit ? 1 : 4096, maximumBytes: countLimit ? 32 * 1024 * 1024 : 1024)
        let fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let change = GraphCloudIncoming(kind: .zoneChanged, zone: zone(.private, countLimit ? "A" : String(repeating: "a", count: 2000)))
        await fake.emit(.incoming(countLimit ? [change, change] : [change]), scope: .private)
        await fake.emit(.state(Data([2])), scope: .private)
        #expect(try await m.cloudStatus(config).failure == .inboxLimit)
        #expect(try document(config).states.isEmpty && document(config).inbox.isEmpty)
        try await m.stopCloudSession(config)
    }

    @Test func accountChangeBlocksBothScopesWithoutErasingState() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let a = try await create(m, config)
        try await m.bindCloudZone(zone(.shared), to: a.id, configuration: config)
        await fake.emit(.state(Data([1])), scope: .private)
        await fake.emit(.account(nil), scope: .shared)
        await fake.emit(.state(Data([2])), scope: .private)
        #expect(try await m.cloudStatus(config).failure == .accountChanged)
        #expect(try document(config).states["private"] == Data([1]))
        try await a.close(); try await m.stopCloudSession(config)
        let wrong = GraphCloudAdapter(account: { _ in "other-account" }, make: fake.adapter.make)
        await #expect(throws: GraphCloudError.invalidState) { try await m.startCloudSession(config, adapter: wrong) }
        #expect(try document(config).account == "account-test")
    }

    @Test func corruptedDocumentAndForeignNamespacesNeverReset() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter); try await m.stopCloudSession(config)
        let foreign = GraphCloudConfiguration(containerIdentifier: "other-\(UUID())", environment: .development, directory: config.directory)
        await #expect(throws: GraphCloudError.invalidState) { try await m.startCloudSession(foreign, adapter: fake.adapter) }
        let file = config.directory.appendingPathComponent("session.json"), bad = Data([0, 1])
        try bad.write(to: file)
        await #expect(throws: GraphCloudError.invalidState) { try await m.startCloudSession(config, adapter: fake.adapter) }
        #expect(try Data(contentsOf: file) == bad)
    }

    @Test func directoryLockPreventsDifferentNamespacesSharingOneDirectory() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let foreign = GraphCloudConfiguration(containerIdentifier: "other-\(UUID())", environment: .development, directory: config.directory)
        await #expect(throws: GraphCloudError.ownershipConflict) { try await manager().startCloudSession(foreign, adapter: fake.adapter) }
        try await m.stopCloudSession(config)
    }

    @Test func failedShutdownRetainsClaimsAndRejectsReplacement() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let graph = try await create(m, config)
        try await m.bindCloudZone(zone(.shared), to: graph.id, configuration: config)
        fake.failCancel = true
        await #expect(throws: GraphCloudError.persistence) { try await m.stopCloudSession(config) }
        #expect(fake.cancellations == 2)
        await #expect(throws: GraphCloudError.ownershipConflict) { try await manager().startCloudSession(config, adapter: CloudFake().adapter) }
        try await graph.close()
        // Failed shutdown is intentionally sticky; isolate the retained owner in this fixture namespace.
    }

    @Test func shutdownDrainsAdmittedCallbacksAndIgnoresLateEvents() async throws {
        let config = config(), fake = CloudFake(), m = manager(), entered = CloudSignal(), proceed = CloudSignal()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        fake.queue([.state(Data([7]))], scope: .private)
        let cancelling = CloudSignal()
        fake.hooks(fetch: { await entered.signal(); await proceed.wait() }, cancel: { await cancelling.signal(); await proceed.wait() })
        let fetching = Task { try await m.fetchCloudChanges(.private, configuration: config) }
        await entered.wait()
        let stopping = Task { try await m.stopCloudSession(config) }
        await cancelling.wait()
        await #expect(throws: GraphCloudError.stopping) { try await m.startCloudSession(config, adapter: fake.adapter) }
        await proceed.signal(); try await stopping.value; try await fetching.value
        #expect(try document(config).states["private"] == Data([7]))
        await fake.emit(.state(Data([8])), scope: .private)
        #expect(try document(config).states["private"] == Data([7]))
        await #expect(throws: GraphCloudError.stopped) { try await m.fetchCloudChanges(.private, configuration: config) }
    }

    @Test func conflictingEnvironmentCannotAllocateAnotherNativeDatabaseOwner() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let other = GraphCloudConfiguration(containerIdentifier: config.containerIdentifier, environment: .production,
                                            directory: config.directory.appendingPathComponent("different"))
        await #expect(throws: GraphCloudError.ownershipConflict) { try await manager().startCloudSession(other, adapter: fake.adapter) }
        try await m.stopCloudSession(config)
    }

    @Test func unsupportedAssetsAndUploadsBlockCheckpointProgress() async throws {
        for failure in [GraphCloudError.unsupportedAsset, .unexpectedUpload] {
            let config = config(), fake = CloudFake(), m = manager()
            defer { try? FileManager.default.removeItem(at: config.directory) }
            _ = try await m.startCloudSession(config, adapter: fake.adapter)
            await fake.emit(.failure(failure), scope: .private)
            await fake.emit(.state(Data([9])), scope: .private)
            #expect(try await m.cloudStatus(config).failure == failure)
            #expect(try document(config).states.isEmpty)
            try await m.stopCloudSession(config)
        }
    }

    @Test func restartAfterCheckpointFailureRetainsReceivedInbox() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let disk = GraphCloudDisk(read: GraphCloudDisk.live.read, write: { url, bytes in
            let doc = try JSONDecoder().decode(GraphCloudDocument.self, from: bytes)
            if !doc.states.isEmpty { throw GraphCloudError.persistence }
            try GraphCloudDisk.live.write(url, bytes)
        })
        _ = try await m.startCloudSession(config, adapter: fake.adapter, disk: disk)
        let event = GraphCloudIncoming(kind: .zoneChanged, zone: zone())
        await fake.emit(.incoming([event]), scope: .private)
        await fake.emit(.state(Data([9])), scope: .private)
        #expect(try await m.cloudStatus(config).failure == .persistence)
        try await m.stopCloudSession(config)
        _ = try await m.startCloudSession(config, adapter: CloudFake().adapter)
        #expect(try await m.cloudInbox(config).map(\.change) == [event])
        #expect(try document(config).states.isEmpty)
        try await m.stopCloudSession(config)
    }

    #if os(macOS)
    @Test func nativeDirectoryLockExcludesAnIndependentProcess() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys,fcntl; f=open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)", config.directory.appendingPathComponent("session.lock").path]
        process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        try await m.stopCloudSession(config)
        let released = Process()
        released.executableURL = process.executableURL; released.arguments = process.arguments
        try released.run(); released.waitUntilExit()
        #expect(released.terminationStatus == 0)
    }
    #endif

    @Test func blockedSessionsAreNotDiscardedByAnotherStart() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        await fake.emit(.failure(.unsupportedAsset), scope: .private)
        await #expect(throws: GraphCloudError.unsupportedAsset) { try await m.startCloudSession(config, adapter: fake.adapter) }
        #expect(try await m.cloudStatus(config).failure == .unsupportedAsset)
        await #expect(throws: GraphCloudError.ownershipConflict) { try await manager().startCloudSession(config, adapter: fake.adapter) }
        try await m.stopCloudSession(config)
    }

    @Test func startupCleanupFailureRetainsOwnerAndDirectory() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let graph = try await create(m, config)
        try await m.bindCloudZone(zone(.shared), to: graph.id, configuration: config)
        try await graph.close(); try await m.stopCloudSession(config)
        fake.failCancel = true
        let adapter = GraphCloudAdapter(account: fake.adapter.account, make: { config, scope, state, callback in
            if scope == .shared { throw GraphCloudError.invalidState }
            return try fake.adapter.make(config, scope, state, callback)
        })
        await #expect(throws: GraphCloudQuarantine.self) { try await m.startCloudSession(config, adapter: adapter) }
        await #expect(throws: GraphCloudError.ownershipConflict) { try await manager().startCloudSession(config, adapter: fake.adapter) }
        await #expect(throws: GraphCloudError.persistence) { try await m.stopCloudSession(config) }
    }

    @Test func duplicateFetchIsBusyWhileOtherScopeProgresses() async throws {
        let config = config(), fake = CloudFake(), m = manager(), entered = CloudSignal(), proceed = CloudSignal()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let graph = try await create(m, config)
        try await m.bindCloudZone(zone(.shared), to: graph.id, configuration: config)
        fake.hooks(fetch: { await entered.signal(); await proceed.wait() })
        let first = Task { try await m.fetchCloudChanges(.private, configuration: config) }
        await entered.wait()
        await #expect(throws: GraphCloudError.busy) { try await m.fetchCloudChanges(.private, configuration: config) }
        // Direct shared delegate events still progress while the private fetch is suspended.
        await fake.emit(.state(Data([4])), scope: .shared)
        #expect(try document(config).states["shared"] == Data([4]))
        await proceed.signal(); try await first.value
        try await graph.close(); try await m.stopCloudSession(config)
    }

    @Test func admittedStartupSurvivesOneCancelledWaiter() async throws {
        let config = config(), fake = CloudFake(), m = manager(), entered = CloudSignal(), proceed = CloudSignal()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let adapter = GraphCloudAdapter(account: { _ in await entered.signal(); await proceed.wait(); return "account-test" }, make: fake.adapter.make)
        let first = Task { try await m.startCloudSession(config, adapter: adapter) }
        await entered.wait(); first.cancel()
        let second = Task { try await m.startCloudSession(config, adapter: adapter) }
        await proceed.signal()
        #expect(try await first.value.failure == nil)
        #expect(try await second.value.failure == nil)
        #expect(fake.count(.private) == 1)
        try await m.stopCloudSession(config)
    }

    @available(iOS 17, macOS 14, *)
    @Test func secureArchiveIdentityIsValidatedOnReceptionAndReopen() async throws {
        let config = config(), fake = CloudFake(), m = manager()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        let record = CKRecord(recordType: "Fixture", recordID: CKRecord.ID(recordName: "one", zoneID: CKRecordZone.ID(zoneName: "A", ownerName: "owner")))
        let incoming = try GraphCloudRecordCodec.archive(record, scope: .private)
        await fake.emit(.incoming([incoming]), scope: .private)
        try await m.stopCloudSession(config)
        _ = try await m.startCloudSession(config, adapter: fake.adapter)
        #expect(try await m.cloudInbox(config).first?.change == incoming)
        let wrong = GraphCloudIncoming(kind: .recordChanged, zone: zone(), recordName: "other", recordType: "Fixture", recordArchive: incoming.recordArchive)
        await fake.emit(.incoming([wrong]), scope: .private)
        #expect(try await m.cloudStatus(config).failure == .invalidState)
        try await m.stopCloudSession(config)
        var doc = try document(config)
        doc.inbox.append(GraphCloudInboxEntry(id: UUID(), change: wrong))
        let bytes = try JSONEncoder().encode(doc), file = config.directory.appendingPathComponent("session.json")
        try bytes.write(to: file)
        await #expect(throws: GraphCloudError.invalidState) { try await m.startCloudSession(config, adapter: fake.adapter) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @available(iOS 17, macOS 14, *)
    @Test func nativeArchiveIsSecureAndAssetsAreRefused() throws {
        let record = CKRecord(recordType: "Fixture", recordID: CKRecord.ID(recordName: "one", zoneID: CKRecordZone.ID(zoneName: "A")))
        record["name"] = "value" as CKRecordValue
        let incoming = try GraphCloudRecordCodec.archive(record, scope: .private)
        let bytes = try #require(incoming.recordArchive)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes))
        #expect(decoded.recordID == record.recordID && decoded["name"] as? String == "value")
        record["file"] = CKAsset(fileURL: URL(fileURLWithPath: "/tmp/not-a-real-fixture"))
        #expect(throws: GraphCloudError.unsupportedAsset) { try GraphCloudRecordCodec.archive(record, scope: .private) }
    }
    @Test(arguments: [false, true]) func sendAdviceIsCapturedBeforeAnotherOperationReusesTheScope(_ fails: Bool) async throws {
        let config = config(), graph = GraphID(), route = GraphCloudBinding(zone: zone(), graphID: graph)
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let adapter = GraphCloudAdapter(account: { _ in "advice-test" }, make: { _, _, _, receive in
            GraphCloudDriver(fetch: { _ in await receive(.retryAdvice(1)) }, cancel: {}, send: { _ in
                await receive(.retryAdvice(600))
                if fails { throw NSError(domain: CKErrorDomain, code: CKError.Code.requestRateLimited.rawValue) }
            })
        })
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        try await session.bind(route)
        let batch = GraphCloudOutgoingBatch(id: UUID(), graphID: graph, zone: route.zone, items: [])
        let outcome = try await session.sendWithAdvice(batch)
        // Another fetch replaces the scope's transient advice; it cannot change the completed send's snapshot.
        try await session.fetch(.private)
        #expect(outcome.retryAfter == 600)
        #expect((outcome.transportError != nil) == fails)
        if let error = outcome.transportError {
            #expect((error as NSError).domain == CKErrorDomain)
            #expect((error as NSError).code == CKError.Code.requestRateLimited.rawValue)
        }
        if fails {
            do { try await session.send(batch); Issue.record("The compatibility send did not propagate the native error") }
            catch { #expect((error as NSError).code == CKError.Code.requestRateLimited.rawValue) }
        }
        let data = try Data(contentsOf: config.directory.appendingPathComponent("session.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["retryAdvice"] == nil)
        #expect(object["retryAfter"] == nil)
        try await session.stop()
    }

}
