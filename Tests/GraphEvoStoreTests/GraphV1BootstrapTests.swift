import CoreData
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class BootstrapControl: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = true
    private var calls = 0
    private var action: (@Sendable () -> Void)?
    func once(_ action: () throws -> Void) rethrows {
        if lock.withLock({ let value = remaining; remaining = false; return value }) { try action() }
    }
    func recordCall() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
    func install(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func run() { lock.withLock { action }?() }
}
private final class BootstrapGate: @unchecked Sendable {
    let arrivals = AsyncStream<Void>.makeStream()
    private let once = BootstrapControl()
    private let semaphore = DispatchSemaphore(value: 0)
    func block() {
        once.once { arrivals.continuation.yield(()); _ = semaphore.wait(timeout: .now() + 20) }
    }
    func release() { semaphore.signal() }
}
private struct BootstrapFault: Error {}

@Suite(.timeLimit(.minutes(2))) struct GraphV1BootstrapTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V1Bootstrap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func request(_ root: URL, id: GraphID = GraphID(), operation: UUID = UUID()) -> GraphStoreMigrationRequest {
        .init(sourceURL: root.appendingPathComponent("Legacy.sqlite"), destinationURL: root.appendingPathComponent("V2.sqlite"),
              graphID: id, operationID: operation, backupRoot: root.appendingPathComponent("Backups"), reason: "Explicit bootstrap fixture")
    }
    private func manager(registry: StoreRegistry = StoreRegistry(), adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: registry, schema: GraphRuntimeSchema.typedProperties, adapter: adapter)
    }
    private func adapter(snapshot: (@Sendable () throws -> Void)? = nil, apply: (@Sendable () throws -> Void)? = nil,
                         opening: (@Sendable () throws -> Void)? = nil) -> GraphCoordinatorAdapter {
        let base = GraphCoordinatorFactory.adapter, conversion = base.v1Conversion!
        let replacement = GraphV1ConversionAdapter(sourceSchema: conversion.sourceSchema, targetSchemaIdentifier: conversion.targetSchemaIdentifier,
            snapshot: { context, id, limits in try snapshot?(); return try conversion.snapshot(context, id, limits) },
            receipt: conversion.receipt, apply: { context, intent, source in
                let receipt = try conversion.apply(context, intent, source); try apply?(); return receipt
            })
        return .init(graph: base.graph, sync: base.sync, v1Conversion: replacement, migrationSource: replacement.migrationSource,
            initializePolicy: base.initializePolicy, publication: base.publication, workspace: base.workspace,
            prepareWorkspace: base.prepareWorkspace, validateBackup: base.validateBackup, initialize: { context, id, creating in
                if !creating { try opening?() }; try base.initialize(context, id, creating)
            })
    }
    private func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    @Test func opensOnlyAfterConversionWithVerifiedBackupAndS04Data() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root), old = try await seedConversionSource(r.sourceURL), before = try digest(r.sourceURL), m = manager()
        let result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        #expect(!result.conversion.cleanupPending && graph.id == r.graphID)
        let a = try #require(result.conversion.receipt.nodeIDs[old[0]]), b = try #require(result.conversion.receipt.nodeIDs[old[1]])
        let record = try #require(try await graph.read { try $0.record(for: a) })
        #expect(record.properties["amount"] == .decimal(Decimal(string: "12.34")!))
        #expect(record.properties["binary"] == .data(Data(repeating: 91, count: 2 * 1024 * 1024)))
        #expect(record.tags == ["retained"] && record.groups == ["invoices"])
        #expect(try await graph.read { try $0.record(for: b)?.createdDate } == nil)
        let integrity = try await graph.validateIntegrity(), pending = try await graph.collectSyncChanges()
        #expect(integrity == 5 && pending == 5)
        let schema = try await graph.read { scope in try scope.withContext { context, _ in
            context.persistentStoreCoordinator?.managedObjectModel.versionIdentifiers == [AnyHashable(GraphRuntimeSchema.typedProperties.identifier)]
        } }
        let after = try digest(r.sourceURL)
        #expect(schema && after == before)
        let backup = try await m.backups.verify(at: result.conversion.backupURL)
        #expect(backup.manifest.schemaIdentifier == GraphRuntimeSchema.current.identifier)
        #expect(try await m.backups.retentionOwners(at: backup.url).isEmpty)
        try await graph.close()
    }

    @Test func restartRelocationAndLaterEditsRecoverTheSameReceiptAndMapping() async throws {
        let root = try directory(), moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let r = request(root), old = try await seedConversionSource(r.sourceURL), firstManager = manager()
        let first = try await firstManager.openGraph(convertingLocalV1: r), graph = try first.opening.get()
        let node = try #require(first.conversion.receipt.nodeIDs[old[0]])
        _ = try await graph.transaction { try $0.patch(.init(id: node, properties: ["name": .set(.string("Later v2 edit"))])) }
        try await graph.close()
        try FileManager.default.moveItem(at: root, to: moved)
        let current = request(moved, id: r.graphID, operation: r.operationID), next = manager()
        let result = try await next.openGraph(convertingLocalV1: current), opened = try result.opening.get()
        #expect(result.conversion.receipt == first.conversion.receipt)
        #expect(result.conversion.backupURL.deletingLastPathComponent() == current.backupRoot.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try await opened.read { try $0.record(for: node)?.properties["name"] } == .string("Later v2 edit"))
        #expect(try await next.backups.list(in: current.backupRoot).count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(result.conversion.receipt), as: UTF8.self)
        #expect(!encoded.contains(root.path) && !encoded.contains(moved.path) && !encoded.contains("file://"))
        try await opened.close()
    }

    @Test func failureAfterCommitReturnsReceiptAndRetryDoesNotReapply() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let firstOpening = BootstrapControl(), application = BootstrapControl()
        let m = manager(adapter: adapter(apply: { application.recordCall() }, opening: { try firstOpening.once { throw BootstrapFault() } }))
        let first = try await m.openGraph(convertingLocalV1: r)
        if case .failure(let error) = first.opening { #expect(error is BootstrapFault) } else { Issue.record("Opening failure was hidden.") }
        #expect(first.conversion.receipt.intent.operationID == r.operationID)
        let opened = try await m.openGraph(convertingLocalV1: r), graph = try opened.opening.get()
        #expect(opened.conversion.receipt == first.conversion.receipt && application.count == 1)
        #expect(try await m.backups.list(in: r.backupRoot).count == 1)
        try await graph.close()
    }

    @Test func concurrentOpenCreateAndConversionAreRejectedBeforeDestinationExists() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let gate = BootstrapGate(), m = manager(adapter: adapter(snapshot: { gate.block() }))
        let operation = Task { try await m.openGraph(convertingLocalV1: r) }
        var arrivals = gate.arrivals.stream.makeAsyncIterator(); _ = await arrivals.next()
        defer { gate.release() }
        #expect(!FileManager.default.fileExists(atPath: r.destinationURL.path))
        await #expect(throws: GraphV1ConversionError.busy) { try await m.openGraph(id: r.graphID, at: r.destinationURL) }
        await #expect(throws: GraphV1ConversionError.busy) { try await m.createGraph(id: GraphID(), at: r.destinationURL) }
        await #expect(throws: GraphV1ConversionError.busy) { try await m.openGraph(convertingLocalV1: r) }
        await #expect(throws: GraphV1ConversionError.busy) {
            try await m.convertLocalV1Store(at: r.sourceURL, to: r.destinationURL, graphID: r.graphID, operationID: r.operationID, backupsIn: r.backupRoot)
        }
        let unrelated = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Unrelated.sqlite"))
        try await unrelated.close()
        gate.release()
        let result = try await operation.value; try await result.opening.get().close()
    }

    @Test func cancellationBeforeSaveRollsBackAndAfterCommitReturnsCommittedOutcome() async throws {
        for afterCommit in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let r = request(root); _ = try await seedConversionSource(r.sourceURL)
            let cancellation = BootstrapControl()
            var hooks = StoreLifecycleHooks()
            if afterCommit { hooks.afterCommit = { cancellation.run() } }
            let registry = StoreRegistry(hooks: hooks)
            let m = manager(registry: registry, adapter: afterCommit ? GraphCoordinatorFactory.adapter : adapter(apply: { cancellation.run() }))
            let operation = Task { try await m.openGraph(convertingLocalV1: r) }
            cancellation.install { operation.cancel() }
            if afterCommit {
                let result = try await operation.value
                #expect(result.conversion.receipt.intent.operationID == r.operationID)
                if case .failure(let error) = result.opening { #expect(error is CancellationError) } else { Issue.record("Cancelled opening was admitted.") }
            } else {
                await #expect(throws: CancellationError.self) { try await operation.value }
                let backup = try #require(try await m.backups.list(in: r.backupRoot).first)
                #expect(try await m.backups.retentionOwners(at: backup.url).contains(r.operationID))
                await #expect(throws: (any Error).self) { try await m.openGraph(id: r.graphID, at: r.destinationURL) }
            }
            let retry = try await m.openGraph(convertingLocalV1: r), graph = try retry.opening.get()
            #expect(retry.conversion.receipt.nodeIDs.count == 5); try await graph.close()
        }
    }

    @Test func activeOrDifferentlyRegisteredGraphCannotBeReboundByBootstrap() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let m = manager(), existing = try await m.createGraph(id: r.graphID, at: root.appendingPathComponent("Other.sqlite"))
        await #expect(throws: GraphV1ConversionError.busy) { try await m.openGraph(convertingLocalV1: r) }
        try await existing.close()
        await #expect(throws: GraphStoreError.self) { try await m.openGraph(convertingLocalV1: r) }
        #expect(!FileManager.default.fileExists(atPath: r.destinationURL.path) && !FileManager.default.fileExists(atPath: r.backupRoot.path))
        let retained = try await m.openGraph(id: r.graphID, at: root.appendingPathComponent("Other.sqlite")); try await retained.close()
    }

    @Test func invalidSourceFailsBeforeDestinationOrBackup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL, reserved: true)
        let m = manager()
        await #expect(throws: (any Error).self) { try await m.openGraph(convertingLocalV1: r) }
        #expect(!FileManager.default.fileExists(atPath: r.destinationURL.path) && !FileManager.default.fileExists(atPath: r.backupRoot.path))
    }

    @Test func boundGraphIsRefusedButOtherCloudGraphsKeepTheirAdmission() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let m = manager(), other = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Other.sqlite"))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.bootstrap." + UUID().uuidString, environment: .development, directory: root.appendingPathComponent("Session"))
        let fake = GraphCloudAdapter(account: { _ in "bootstrap-account" }, make: { _, _, _, _ in .init(fetch: { _ in }, cancel: {}) })
        _ = try await m.startCloudSession(config, adapter: fake)
        try await m.bindCloudZone(.init(scope: .private, owner: "owner", name: "other"), to: other.id, configuration: config)
        let result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        try await m.bindCloudZone(.init(scope: .private, owner: "owner", name: "converted"), to: r.graphID, configuration: config)
        try await graph.close()
        await #expect(throws: GraphV1ConversionError.invalidRequest) { try await m.openGraph(convertingLocalV1: r) }
        #expect(try await other.validateIntegrity() == 0)
        try await other.close(); try await m.stopCloudSession(config)
    }
    @Test func replacedSourceCannotRecoverOrOverwriteTheConvertedGraph() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let m = manager(), first = try await m.openGraph(convertingLocalV1: r), graph = try first.opening.get()
        try await graph.close()
        let replacement = root.appendingPathComponent("Replacement.sqlite")
        _ = try await seedConversionSource(replacement, empty: true)
        try FileManager.default.removeItem(at: r.sourceURL)
        try FileManager.default.moveItem(at: replacement, to: r.sourceURL)
        await #expect(throws: (any Error).self) { try await m.openGraph(convertingLocalV1: r) }
        let preserved = try await m.openGraph(id: r.graphID, at: r.destinationURL)
        #expect(try await preserved.validateIntegrity() == 5)
        #expect(try await m.backups.list(in: r.backupRoot).count == 1)
        try await preserved.close()
    }

    @Test func detachFailureRetainsCommitAndNativeExclusion() async throws {
        // Intentionally quarantined resources remain owned and on disk until process exit.
        let root = try directory(), r = request(root)
        _ = try await seedConversionSource(r.sourceURL)
        let firstDetach = BootstrapControl()
        let registry = StoreRegistry(hooks: .init(beforeDetach: { try firstDetach.once { throw BootstrapFault() } }))
        let m = manager(registry: registry), result = try await m.openGraph(convertingLocalV1: r)
        #expect(result.conversion.cleanupPending && result.conversion.receipt.nodeIDs.count == 5)
        if case .success = result.opening { Issue.record("A failed native detachment allowed reopening.") }
        await #expect(throws: (any Error).self) { try await manager().openGraph(id: r.graphID, at: r.destinationURL) }
        let other = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Other.sqlite"))
        try await other.close()
    }

    @Test @MainActor func anOpenLegacyOwnerPreventsBootstrap() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try seedConversionSource(r.sourceURL)
        let legacy = Graph(storeURL: r.sourceURL, migrationEnabled: false)
        #expect(legacy.isReady)
        let m = manager()
        await #expect(throws: (any Error).self) { try await m.openGraph(convertingLocalV1: r) }
        #expect(!FileManager.default.fileExists(atPath: r.destinationURL.path) && !FileManager.default.fileExists(atPath: r.backupRoot.path))
        let container = try #require(legacy.persistentContainer)
        legacy.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        let result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        try await graph.close()
    }

    @Test func finalOpeningStillExcludesAliasesAndCloudBinding() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let gate = BootstrapGate(), m = manager(adapter: adapter(opening: { gate.block() }))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.bootstrap." + UUID().uuidString, environment: .development,
            directory: root.appendingPathComponent("Session"))
        let fake = GraphCloudAdapter(account: { _ in "bootstrap-account" }, make: { _, _, _, _ in .init(fetch: { _ in }, cancel: {}) })
        _ = try await m.startCloudSession(config, adapter: fake)
        let operation = Task { try await m.openGraph(convertingLocalV1: r) }
        var arrivals = gate.arrivals.stream.makeAsyncIterator(); _ = await arrivals.next()
        defer { gate.release() }
        await #expect(throws: GraphV1ConversionError.busy) { try await m.openGraph(id: r.graphID, at: r.destinationURL) }
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "converted")
        await #expect(throws: GraphV1ConversionError.busy) { try await m.bindCloudZone(zone, to: r.graphID, configuration: config) }
        gate.release()
        let result = try await operation.value, graph = try result.opening.get()
        try await m.bindCloudZone(zone, to: r.graphID, configuration: config)
        try await graph.close(); try await m.stopCloudSession(config)
    }

    @Test func aRestoredCloudBindingDuringConversionCannotActivateTheResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.bootstrap." + UUID().uuidString, environment: .development,
            directory: root.appendingPathComponent("Session"))
        let fake = GraphCloudAdapter(account: { _ in "bootstrap-account" }, make: { _, _, _, _ in .init(fetch: { _ in }, cancel: {}) })
        let prior = manager(), original = try await prior.openGraph(convertingLocalV1: r), opened = try original.opening.get()
        _ = try await prior.startCloudSession(config, adapter: fake)
        try await prior.bindCloudZone(.init(scope: .private, owner: "owner", name: "existing"), to: r.graphID, configuration: config)
        try await opened.close(); try await prior.stopCloudSession(config)
        let gate = BootstrapGate(), next = manager(adapter: adapter(snapshot: { gate.block() }))
        let operation = Task { try await next.openGraph(convertingLocalV1: r) }
        var arrivals = gate.arrivals.stream.makeAsyncIterator(); _ = await arrivals.next()
        defer { gate.release() }
        await #expect(throws: GraphV1ConversionError.busy) { try await next.startCloudSession(config, adapter: fake) }
        gate.release()
        let result = try await operation.value
        #expect(result.conversion.receipt == original.conversion.receipt)
        if case .success = result.opening { Issue.record("Restored cloud binding activated a local bootstrap.") }
        #expect(await next.registeredGraphCount == 0)
        try await next.stopCloudSession(config)
    }

    @Test func persistedParticipationGateCannotMasqueradeAsLocalReadiness() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL, empty: true)
        let m = manager(), initial = try await m.openGraph(convertingLocalV1: r), graph = try initial.opening.get()
        let binding = GraphCloudBinding(zone: .init(scope: .shared, owner: "owner", name: "stored-participation"), graphID: r.graphID)
        _ = try await graph.participantAccess(.init(binding: binding, account: "bootstrap-account", permission: .readOnly, accepted: true,
            identity: .init(container: "iCloud.fixture", environment: .development, account: "bootstrap-account"), generation: UUID()))
        try await graph.close()
        let result = try await m.openGraph(convertingLocalV1: r)
        #expect(result.conversion.receipt == initial.conversion.receipt)
        if case .success = result.opening { Issue.record("A retained participation data gate reported local readiness.") }
        #expect(await m.registeredGraphCount == 0)
    }

    @Test func aPendingAccountStartupRefusesPromptlyWithoutStartingConversion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let arrived = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream(), m = manager()
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.bootstrap." + UUID().uuidString, environment: .development,
            directory: root.appendingPathComponent("Session"))
        let fake = GraphCloudAdapter(account: { _ in
            arrived.continuation.yield(())
            var permit = release.stream.makeAsyncIterator(); _ = await permit.next()
            return "bootstrap-account"
        }, make: { _, _, _, _ in .init(fetch: { _ in }, cancel: {}) })
        let starting = Task { try await m.startCloudSession(config, adapter: fake) }
        var arrivals = arrived.stream.makeAsyncIterator(); _ = await arrivals.next()
        defer { release.continuation.yield(()) }
        await #expect(throws: GraphV1ConversionError.busy) { try await m.openGraph(convertingLocalV1: r) }
        #expect(!FileManager.default.fileExists(atPath: r.destinationURL.path) && !FileManager.default.fileExists(atPath: r.backupRoot.path))
        release.continuation.yield(()); _ = try await starting.value
        let result = try await m.openGraph(convertingLocalV1: r); try await result.opening.get().close()
        try await m.stopCloudSession(config)
    }

}
