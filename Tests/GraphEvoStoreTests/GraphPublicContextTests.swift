import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor PublicAccountGate {
    private var entered = false
    private var released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true; let values = arrival; arrival.removeAll(); for value in values { value.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrival.append($0) } } }
    func release() { released = true; let values = releaseWaiters; releaseWaiters.removeAll(); for value in values { value.resume() } }
}

private final class PublicAccountDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var availability: GraphCloudAccountAvailability = .available("public-account")
    private var hook: (@Sendable () async -> Void)?
    private var received: (@Sendable (GraphCloudEvent) async -> Void)?
    private var reads = 0
    private var states: [Data?] = []
    let notification = Notification.Name("GraphEvo.PublicAccount." + UUID().uuidString)
    func set(_ value: GraphCloudAccountAvailability) { lock.withLock { availability = value } }
    func setHook(_ value: (@Sendable () async -> Void)?) { lock.withLock { hook = value } }
    var queryCount: Int { lock.withLock { reads } }
    var restored: [Data?] { lock.withLock { states } }
    func notify() { NotificationCenter.default.post(name: notification, object: nil) }
    func emit(_ value: GraphCloudEvent) async { await lock.withLock { received }?(value) }
    var adapter: GraphCloudAdapter {
        var result = GraphCloudAdapter(account: { _ in "public-account" }, make: { [self] _, _, data, receive in
            lock.withLock { states.append(data); received = receive }
            return GraphCloudDriver(fetch: { _ in }, cancel: {})
        })
        result.accountAvailability = { [self] _ in
            let callback = lock.withLock { reads += 1; return hook }
            await callback?()
            return lock.withLock { availability }
        }
        result.observeAccount = { [self] callback in GraphCloudAccountObservation(name: notification, changed: callback) }
        return result
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct GraphPublicContextTests {
    @available(iOS 17, macOS 14, *)
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PublicContext-" + UUID().uuidString) }
    @available(iOS 17, macOS 14, *)
    private func context(_ driver: PublicAccountDriver = PublicAccountDriver(), registry: StoreRegistry = .shared) -> GraphContext {
        GraphContext(manager: GraphContextManager(registry: registry, schema: GraphRuntimeSchema.typedProperties,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()), adapter: driver.adapter)
    }
    @available(iOS 17, macOS 14, *)
    private func configuration(_ root: URL, container: String = UUID().uuidString) throws -> GraphCloudConnectionConfiguration {
        try .init(containerIdentifier: "iCloud.public." + container, environment: .development, directory: root.appendingPathComponent("Session"))
    }
    @available(iOS 17, macOS 14, *)
    private func wait(_ body: () async throws -> Bool) async throws {
        for _ in 0..<2000 {
            if try await body() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw GraphCloudError.invalidState
    }
    @available(iOS 17, macOS 14, *)
    private func isolated(_ error: any Error) -> Bool { if case GraphStoreError.accountIsolated = error { return true }; return false }

    @available(iOS 17, macOS 14, *)
    @Test func independentContextsRefuseOverlappingGraphsAndShareOnlyTheirOwnLeases() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = GraphContext(), second = GraphContext(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let a = try await first.createGraph(id: id, at: url)
        let alias = try await first.openGraph(id: id, at: root.appendingPathComponent("./A.sqlite"))
        await #expect(throws: GraphStoreError.self) { try await second.openGraph(id: id, at: url) }
        await #expect(throws: GraphStoreError.self) { try await second.createGraph(id: id, at: root.appendingPathComponent("Wrong.sqlite")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Wrong.sqlite").path))
        let b = try await second.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        let node = a.makeNodeID()
        try await a.transaction { try $0.insert(GraphRecord(id: node, type: "Retained")) }
        try await a.close()
        #expect(try await alias.read { try $0.record(for: node) } != nil)
        try await alias.close()
        let reopened = try await second.openGraph(id: id, at: url)
        #expect(try await reopened.read { try $0.record(for: node) } != nil)
        try await reopened.close(); try await b.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func localGraphsDoNotConsultAccountProvidersAndRetainTheirExplicitContext() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = PublicAccountDriver(); driver.set(.signedOut)
        var owner: GraphContext? = context(driver)
        weak var retained = owner
        let graph = try await owner!.createGraph(id: GraphID(), at: root.appendingPathComponent("Local.sqlite"))
        owner = nil
        #expect(retained != nil)
        try await retained!.refreshCloudAccounts()
        try await retained!.setForegroundActive(true)
        try await graph.transaction { try $0.insert(GraphRecord(id: graph.makeNodeID(), type: "Local")) }
        #expect(driver.queryCount == 0)
        #expect(try await graph.cloudAccountState == .localOnly)
        try await graph.close()
        #expect(retained == nil)
    }

    @available(iOS 17, macOS 14, *)
    @Test func concurrentConnectionsReturnBeforeVerificationAndReserveTheDatabase() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = PublicAccountDriver(), gate = PublicAccountGate(), first = context(driver), second = context()
        driver.setHook { await gate.enter() }
        let config = try configuration(root)
        let leases = try await withThrowingTaskGroup(of: GraphCloudConnection.self) { group in
            for _ in 0..<8 { group.addTask { try await first.connectCloud(using: config) } }
            var values: [GraphCloudConnection] = []
            for try await value in group { values.append(value) }
            return values
        }
        await gate.wait()
        #expect(try await leases[0].state == .verifyingAccount)
        let competing = try GraphCloudConnectionConfiguration(containerIdentifier: config.containerIdentifier, environment: config.environment,
            directory: root.appendingPathComponent("OtherSession"))
        await #expect(throws: GraphCloudConnectionError.self) { try await second.connectCloud(using: competing) }
        try await leases[0].close()
        driver.setHook(nil); await gate.release()
        try await wait { try await leases[1].state == .ready }
        #expect(driver.restored.count == 1)
        for lease in leases.dropFirst() { try await lease.close() }
        let new = try await second.connectCloud(using: competing)
        try await wait { try await new.state == .ready }
        try await new.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func coldSynchronizedOpenVerifiesWithoutTransportAndKeepsIdentityBoundaries() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try configuration(root), url = root.appendingPathComponent("Bound.sqlite"), id = GraphID()
        let seedDriver = PublicAccountDriver(), seed = context(seedDriver)
        let original = try await seed.createGraph(id: id, at: url)
        let connection = try await seed.connectCloud(using: config)
        try await wait { try await connection.state == .ready }
        try await connection.bindPrivateGraph(original, zoneName: "Bound")
        await seedDriver.emit(.state(Data([7])))
        let node = original.makeNodeID()
        try await original.transaction { try $0.insert(GraphRecord(id: node, type: "Retained")) }
        try await connection.close(); try await original.close()

        let driver = PublicAccountDriver(), reader = context(driver)
        driver.set(.temporarilyUnavailable)
        let graph = try await reader.openGraph(id: id, at: url)
        try await wait { driver.queryCount > 0 }
        await #expect { try await graph.read { _ in () } } throws: { isolated($0) }
        #expect(driver.restored.isEmpty)
        driver.set(.available("public-account")); try await reader.refreshCloudAccounts()
        try await wait { try await graph.cloudAccountState == .available }
        #expect(try await graph.read { try $0.record(for: node) } != nil)
        driver.set(.temporarilyUnavailable); driver.notify()
        try await wait { try await graph.cloudAccountState == .temporarilyUnavailable }
        try await graph.transaction { try $0.patch(.init(id: node, properties: ["offline": .set(.boolean(true))])) }
        driver.set(.signedOut); driver.notify()
        try await wait { try await graph.cloudAccountState == .isolated(.signedOut) }
        await #expect { try await graph.read { _ in () } } throws: { isolated($0) }
        driver.set(.available("public-account")); driver.notify()
        try await wait { try await graph.cloudAccountState == .available }
        #expect(driver.restored.isEmpty)
        let restarted = try await reader.connectCloud(using: config)
        try await wait { try await restarted.state == .ready }
        #expect(driver.restored.count == 1 && driver.restored[0] == nil)
        try await restarted.close(); try await graph.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func foregroundBelongsToContextAndClosingOneConnectionDoesNotStopAnother() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = PublicAccountDriver(), owner = context(driver), config = try configuration(root)
        try await owner.setForegroundActive(true)
        let a = try await owner.connectCloud(using: config), b = try await owner.connectCloud(using: config)
        try await wait { try await a.state == .ready }
        #expect(await owner.manager.accountAutomaticActivity[config.native.namespace] == true)
        try await a.close()
        #expect(try await b.state == .ready)
        #expect(await owner.manager.accountAutomaticActivity[config.native.namespace] == true)
        try await owner.setForegroundActive(false)
        #expect(await owner.manager.accountAutomaticActivity[config.native.namespace] == false)
        try await b.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func publicStagedBootstrapPreservesValuesAndRecoversItsCommittedReceipt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("V1.sqlite")
        _ = try await seedConversionSource(source)
        let owner = GraphContext(), request = GraphV1BootstrapRequest(sourceURL: source,
            destinationURL: root.appendingPathComponent("V2.sqlite"), graphID: GraphID(), operationID: UUID(),
            backupRoot: root.appendingPathComponent("Backups"), reason: "Public bootstrap regression")
        let initial = try await owner.openGraph(convertingLocalV1: request), graph = try initial.opening.get()
        #expect(initial.conversion.receipt.operationID == request.operationID)
        #expect(!initial.conversion.receipt.nodeIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: initial.conversion.backupURL.path))
        let later = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: later, type: "Later", properties: ["body": .data(Data([0, 128, 255]))])) }
        try await graph.close()
        let recovered = try await owner.openGraph(convertingLocalV1: request), reopened = try recovered.opening.get()
        #expect(recovered.conversion.receipt == initial.conversion.receipt)
        #expect(try await reopened.read { try $0.record(for: later)?.properties["body"] } == .data(Data([0, 128, 255])))
        try await reopened.close()
    }
    @available(iOS 17, macOS 14, *)
    @Test func closingDuringVerificationRetainsReservationUntilStartupDrains() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = PublicAccountDriver(), gate = PublicAccountGate(), owner = context(driver), competitor = context()
        driver.setHook { await gate.enter() }
        let config = try configuration(root), connection = try await owner.connectCloud(using: config)
        await gate.wait()
        let closing = Task { try await connection.close() }
        await #expect(throws: GraphCloudConnectionError.self) { try await competitor.connectCloud(using: config) }
        #expect(driver.restored.isEmpty)
        driver.setHook(nil); await gate.release(); try await closing.value
        let replacement = try await competitor.connectCloud(using: config)
        try await wait { try await replacement.state == .ready }
        try await replacement.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func failedNativeCloseRetainsContextExclusion() async throws {
        struct DetachFailure: Error {}
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { throw DetachFailure() }))
        let owner = context(registry: registry), other = context(registry: registry), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let graph = try await owner.createGraph(id: id, at: url)
        await #expect(throws: GraphStoreError.self) { try await graph.close() }
        await #expect(throws: GraphStoreError.self) { try await other.openGraph(id: id, at: url) }
    }

    @available(iOS 17, macOS 14, *)
    @Test func pendingBootstrapReservesIdentityBeforeDestinationExists() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("V1.sqlite"); _ = try await seedConversionSource(source, empty: true)
        let gate = PublicAccountGate(), registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await gate.enter() }))
        let owner = context(registry: registry), other = context(registry: registry)
        let request = GraphV1BootstrapRequest(sourceURL: source, destinationURL: root.appendingPathComponent("V2.sqlite"), graphID: GraphID(),
            operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Pending public bootstrap")
        let conversion = Task { try await owner.openGraph(convertingLocalV1: request) }
        await gate.wait()
        await #expect(throws: GraphStoreError.self) { try await other.createGraph(id: request.graphID, at: request.destinationURL) }
        #expect(!FileManager.default.fileExists(atPath: request.destinationURL.path))
        await gate.release()
        let result = try await conversion.value
        try await result.opening.get().close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func publicAuthoritativeConversionRecoversAnEmptyPeerWithTheSameValues() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("V1.sqlite"); let oldIDs = try await seedConversionSource(source)
        let server = ActivationServer(), config = try configuration(root)
        func instance() -> GraphContext {
            GraphContext(manager: GraphContextManager(schema: GraphRuntimeSchema.typedProperties,
                adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID()), adapter: server.adapter)
        }
        let owner = instance(), request = GraphV1BootstrapRequest(sourceURL: source, destinationURL: root.appendingPathComponent("Owner.sqlite"),
            graphID: GraphID(), operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Public authority regression")
        let converted = try await owner.openGraph(convertingLocalV1: request), graph = try converted.opening.get()
        let invoice = try #require(converted.conversion.receipt.nodeIDs[oldIDs[0]])
        let data = try await graph.read { try $0.record(for: invoice)?.properties["binary"] }
        guard case .data(let originalBytes) = data else { throw GraphModelError.invalidValue }
        #expect(originalBytes.count == 2 * 1024 * 1024)
        // Explicit consumer optimization; neither schema conversion nor activation infers attachments.
        let input = root.appendingPathComponent("consumer.bin"); try originalBytes.write(to: input)
        let attachment = try await graph.importAttachment(from: input, ownedBy: invoice)
        try await graph.transaction { try $0.patch(.init(id: invoice, properties: ["binary": .remove])) }
        let connection = try await owner.connectCloud(using: config)
        try await wait { try await connection.state == .ready }
        let declaration = GraphCloudCutoverDeclaration(sourceSelection: "Fixture source", completeness: "Exact seeded graph",
            stoppedWriters: "Source detached", returningClients: "No other source writers")
        _ = try await connection.prepareActivation(for: graph.id, activationID: UUID(), zoneName: "PublicAuthority", declaration: declaration)
        var published = false
        for _ in 0..<12 {
            let result = try await connection.advanceActivation(for: graph.id)
            if let error = result.operationError { throw error }
            if result.status.phase == .published { published = true; break }
        }
        #expect(published)
        #expect(try await connection.activationStatus(for: graph.id)?.phase == .published)
        try await graph.close(); try await connection.close()
        let peer = instance(), peerConfig = try GraphCloudConnectionConfiguration(containerIdentifier: config.containerIdentifier,
            environment: config.environment, directory: root.appendingPathComponent("PeerSession"))
        let peerConnection = try await peer.connectCloud(using: peerConfig)
        try await wait { try await peerConnection.state == .ready }
        let recovered = try await peerConnection.openReplica(id: request.graphID, at: root.appendingPathComponent("Peer.sqlite"), zoneName: "PublicAuthority")
        let replica = try recovered.opening.get()
        let ids = Set(converted.conversion.receipt.nodeIDs.values).union([attachment.id])
        #expect(try await replica.read { scope in try Set(ids.filter { try scope.record(for: $0) != nil }) } == ids)
        #expect(try await replica.attachment(attachment.id)?.data == originalBytes)
        try await replica.close(); try await peerConnection.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func notificationDuringInitialConnectionCannotLoseTheNewAccountCheck() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = PublicAccountDriver(), gate = PublicAccountGate(), owner = context(driver), config = try configuration(root)
        driver.setHook { await gate.enter() }
        let connection = try await owner.connectCloud(using: config)
        await gate.wait()
        // Invalidate an explicit startup query while its provider is still in flight.
        let query = await owner.manager.accountAuthorities[config.native.namespace]?.query
        await owner.manager.scheduleAccountRefresh(config.native.namespace)
        try await wait { await owner.manager.accountAuthorities[config.native.namespace]?.query != query }
        driver.setHook(nil); await gate.release()
        try await wait { try await connection.state == .ready }
        #expect(driver.queryCount >= 2)
        #expect(driver.restored.count == 1)
        try await connection.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func invalidZoneCannotClaimAnUnboundLocalGraph() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = context(), config = try configuration(root), id = GraphID(), url = root.appendingPathComponent("Local.sqlite")
        let graph = try await owner.createGraph(id: id, at: url)
        let connection = try await owner.connectCloud(using: config)
        try await wait { try await connection.state == .ready }
        await #expect(throws: GraphCloudConnectionError.self) { try await connection.bindPrivateGraph(graph, zoneName: "") }
        #expect(try await graph.cloudAccountState == .localOnly)
        let occupied = try await owner.createGraph(id: GraphID(), at: root.appendingPathComponent("Occupied.sqlite"))
        try await connection.bindPrivateGraph(occupied, zoneName: "Occupied")
        await #expect(throws: GraphCloudConnectionError.self) { try await connection.bindPrivateGraph(graph, zoneName: "Occupied") }
        #expect(try await graph.cloudAccountState == .localOnly)
        try await connection.close(); try await graph.close(); try await occupied.close()
        let unavailable = PublicAccountDriver(); unavailable.set(.signedOut)
        let reader = context(unavailable), reopened = try await reader.openGraph(id: id, at: url)
        #expect(try await reopened.cloudAccountState == .localOnly)
        #expect(unavailable.queryCount == 0)
        try await reopened.close()
    }

}
