import CoreData
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private let nativeV1StagesAvailable: Bool = { if #available(iOS 17, macOS 14, *) { return true }; return false }()

private struct NativeV1InjectedFailure: Error {}
private final class NativeV1FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    func fail() throws {
        if lock.withLock({ let value = armed; armed = false; return value }) { throw NativeV1InjectedFailure() }
    }
}

private final class NativeV1CompletionGate: @unchecked Sendable {
    let arrivals = AsyncStream<Void>.makeStream()
    private let signal = DispatchSemaphore(value: 0)
    func enter() throws {
        arrivals.continuation.yield(())
        guard signal.wait(timeout: .now() + 10) == .success else { throw NativeV1InjectedFailure() }
    }
    func release() { signal.signal() }
}

// Bound independent fixture I/O; the explicit task-group case still migrates
// four stores concurrently and checks that their allocated identities stay apart.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GraphNativeV1MigrationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeV1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func request(_ root: URL, graph: GraphID = GraphID(), operation: UUID = UUID()) -> GraphStoreMigrationRequest {
        .init(sourceURL: root.appendingPathComponent("Legacy.sqlite"), destinationURL: root.appendingPathComponent("V2.sqlite"),
              graphID: graph, operationID: operation, backupRoot: root.appendingPathComponent("Backups"), reason: "Native v1 conversion fixture")
    }
    private func manager(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties, adapter: adapter)
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func nativeStagesPreserveCompleteGraphAndRecoverReceiptAfterLaterEdits() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root), old = try await seedConversionSource(r.sourceURL)
        let before = Data(SHA256.hash(data: try Data(contentsOf: r.sourceURL)))
        let m = manager(), result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        #expect(!result.conversion.cleanupPending && result.conversion.receipt.nodeIDs.count == 5)
        let a = try #require(result.conversion.receipt.nodeIDs[old[0]])
        let b = try #require(result.conversion.receipt.nodeIDs[old[1]])
        let invoice = try #require(try await graph.read { try $0.record(for: a) })
        #expect(invoice.properties["binary"] == .data(Data(repeating: 91, count: 2 * 1024 * 1024)))
        #expect(invoice.properties["amount"] == .decimal(Decimal(string: "12.34")!))
        #expect(invoice.tags == ["retained"] && invoice.groups == ["invoices"])
        #expect(try await graph.read { try $0.record(for: b)?.createdDate } == nil)
        #expect(try await graph.validateIntegrity() == 5)
        #expect(try await graph.collectSyncChanges() == 5)
        _ = try await graph.transaction { try $0.patch(.init(id: a, properties: ["name": .set(.string("Later"))])) }
        try await graph.close()
        let restarted = manager(), resumed = try await restarted.openGraph(migratingNativeV1: r), opened = try resumed.opening.get()
        #expect(resumed.conversion.receipt == result.conversion.receipt)
        #expect(try await opened.read { try $0.record(for: a)?.properties["name"] } == .string("Later"))
        #expect(Data(SHA256.hash(data: try Data(contentsOf: r.sourceURL))) == before)
        #expect(try await restarted.backups.list(in: r.backupRoot).count == 1)
        try await opened.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func nativeDefaultAcceptsPayloadAboveTheRetainedAtomicAllowance() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root)
        try await MainActor.run {
            let graph = Graph(storeURL: r.sourceURL, migrationEnabled: false)
            guard graph.isReady else { throw GraphV1ConversionError.unsupportedSource }
            for index in 0..<257 {
                let node = Entity("Large", graph: graph)
                node[dynamicMember: "index"] = index
                if index < 18 { node[dynamicMember: "bytes"] = Data(repeating: UInt8(index), count: 2 * 1024 * 1024) }
            }
            var failure: Error?; graph.sync { if !$0 { failure = $1 } }; if let failure { throw failure }
            let container = try #require(graph.persistentContainer); graph.managedObjectContext.reset()
            for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
            try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        }
        let m = manager(), result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        let ids = Array(result.conversion.receipt.nodeIDs.values)
        let count = try await graph.read { scope in try scope.withContext { context, _ in
            let session = try GraphTypedStoreAdapter.Session(context, r.graphID, database: true)
            for id in ids {
                let row = try #require(try session.record(id))
                guard case .integer(let index) = row.properties["index"] else { throw GraphV1ConversionError.invalidReceipt }
                if index < 18 { #expect(row.properties["bytes"] == .data(Data(repeating: UInt8(index), count: 2 * 1024 * 1024))) }
                else { #expect(row.properties["bytes"] == nil) }
            }
            return ids.count
        } }
        #expect(count == 257 && result.conversion.receipt.nodeIDs.count == 257)
        let backup = try await m.backups.verify(at: result.conversion.backupURL)
        #expect(backup.manifest.schemaIdentifier == GraphRuntimeSchema.current.identifier)
        try await graph.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable), arguments: [false, true])
    func interruptedNativeCompletionRetainsAdmissionAndRecoversAllocatedIDs(afterTypedBatch: Bool) async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        if afterTypedBatch {
            try await MainActor.run {
                let graph = Graph(storeURL: r.sourceURL, migrationEnabled: false)
                let node = try #require(Search<Entity>(graph: graph).where(.type("Legacy.Invoice")).sync().first)
                for index in 0..<260 { node[dynamicMember: "batch." + String(index)] = index }
                var failure: Error?; graph.sync { if !$0 { failure = $1 } }; if let failure { throw failure }
                let container = try #require(graph.persistentContainer); graph.managedObjectContext.reset()
                for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
                try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
            }
        }
        let fault = NativeV1FailOnce()
        var adapted = GraphCoordinatorFactory.adapter
        let native = try #require(adapted.nativeV1Migration)
        adapted.nativeV1Migration = GraphNativeV1MigrationAdapter(inspect: native.inspect) { seed, intent, source in
            let plan = try native.plan(seed, intent, source)
            return StoreNativeMigration(sourceSchema: plan.sourceSchema, seedURL: plan.seedURL, document: plan.document, prepare: plan.prepare,
                configure: { description, model in
                    try plan.configure(description, model)
                    if afterTypedBatch {
                        let stages = try #require(description.options[NSPersistentStoreStagedMigrationManagerOptionKey] as? NSStagedMigrationManager)
                        let stage = try #require(stages.stages.first as? NSCustomMigrationStage)
                        // Exercise the guaranteed post-load continuation as if
                        // the physical hop completed before its did handler.
                        stage.didMigrateHandler = nil
                    }
                }, finish: { container in
                    if afterTypedBatch {
                        let document = try GraphV1StagedMigration.document(container, intent: intent)
                        try GraphV1StagedMigration.transform(container, document: document, afterBatch: { try fault.fail() })
                    } else { try fault.fail() }
                    try plan.finish(container)
                })
        }
        let first = manager(adapter: adapted)
        await #expect(throws: (any Error).self) { try await first.openGraph(convertingLocalV1: r) }
        #expect(try !GraphStoreMetadata.isCompatible(at: r.destinationURL))
        let ordinary = manager()
        await #expect(throws: (any Error).self) { try await ordinary.openGraph(id: r.graphID, at: r.destinationURL) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: r.destinationURL)
        let encoded = try #require(metadata[StoreNativeMigration.documentKey] as? Data)
        let retained = try JSONDecoder().decode(GraphV1StagedMigration.Document.self, from: encoded)
        #expect(try await first.backups.retentionOwners(at: r.backupRoot.appendingPathComponent(r.operationID.uuidString).appendingPathExtension("geb")) == [r.operationID])
        let restarted = manager(), result = try await restarted.openGraph(convertingLocalV1: r), graph = try result.opening.get()
        #expect(result.conversion.receipt.nodeIDs == retained.nodeIDs)
        #expect(try await graph.validateIntegrity() == 5)
        #expect(try await graph.collectSyncChanges() == 5)
        #expect(try await restarted.backups.list(in: r.backupRoot).count == 1)
        try await graph.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func nativeEmptyGraphHasAValidNewHistoryBaseline() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL, empty: true)
        let result = try await manager().openGraph(convertingLocalV1: r), graph = try result.opening.get()
        #expect(result.conversion.receipt.nodeIDs.isEmpty)
        #expect(try await graph.validateIntegrity() == 0)
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func failedSourcePreparationDetachmentRetainsTheWorkspaceOwner() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        // The failed detach intentionally quarantines its attached store until process exit.
        let root = try directory(), r = request(root)
        _ = try await seedConversionSource(r.sourceURL)
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeNativePreparationDetach: { throw NativeV1InjectedFailure() }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.typedProperties,
                                    adapter: GraphCoordinatorFactory.adapter)
        await #expect(throws: (any Error).self) { try await m.openGraph(convertingLocalV1: r) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: r.destinationURL)
        #expect(metadata[StoreNativeContext.workspaceKey] as? String == r.operationID.uuidString)
        // A new manager must not acquire the source-model workspace left attached by preparation.
        let independent = StoreRegistry()
        let workspace = StoreConfiguration(location: .sqlite(r.destinationURL), exclusiveGraphID: r.graphID.rawValue,
            workspaceID: r.operationID, workspaceSessionID: m.migrationIdentity)
        await #expect(throws: StoreRuntimeError.self) { try await independent.open(workspace, schema: GraphRuntimeSchema.current) }
        #expect(try !GraphStoreMetadata.isCompatible(at: r.destinationURL))
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func callerCancellationDrainsAdmittedNativeWorkAndReportsItsCommit() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let gate = NativeV1CompletionGate()
        var adapted = GraphCoordinatorFactory.adapter
        let native = try #require(adapted.nativeV1Migration)
        adapted.nativeV1Migration = GraphNativeV1MigrationAdapter(inspect: native.inspect) { seed, intent, source in
            let plan = try native.plan(seed, intent, source)
            return StoreNativeMigration(sourceSchema: plan.sourceSchema, seedURL: plan.seedURL, document: plan.document, prepare: plan.prepare,
                configure: plan.configure, finish: { container in try gate.enter(); try plan.finish(container) })
        }
        let m = manager(adapter: adapted)
        let operation = Task {
            defer { gate.arrivals.continuation.finish() }
            return try await m.openGraph(convertingLocalV1: r)
        }
        var arrivals = gate.arrivals.stream.makeAsyncIterator(); _ = await arrivals.next()
        operation.cancel(); gate.release()
        let committed = try await operation.value
        #expect(committed.conversion.receipt.nodeIDs.count == 5)
        if case .failure(let error) = committed.opening { #expect(error is CancellationError) }
        else { Issue.record("Cancelled caller unexpectedly received an open graph.") }
        let recovered = try await manager().openGraph(convertingLocalV1: r), graph = try recovered.opening.get()
        #expect(recovered.conversion.receipt == committed.conversion.receipt)
        #expect(try await graph.collectSyncChanges() == 5)
        try await graph.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func catalogCommitWithoutReceiptResumesBeforeConsumerAvailability() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let r = request(root); _ = try await seedConversionSource(r.sourceURL)
        let failure = NativeV1FailOnce()
        var adapted = GraphCoordinatorFactory.adapter
        let native = try #require(adapted.nativeV1Migration)
        adapted.nativeV1Migration = GraphNativeV1MigrationAdapter(inspect: native.inspect) { seed, intent, source in
            let plan = try native.plan(seed, intent, source)
            return StoreNativeMigration(sourceSchema: plan.sourceSchema, seedURL: plan.seedURL, document: plan.document,
                prepare: plan.prepare, configure: plan.configure, finish: { container in
                    try GraphV1StagedMigration.complete(container, intent: intent, afterCatalogSave: { try failure.fail() })
                })
        }
        await #expect(throws: (any Error).self) { try await self.manager(adapter: adapted).openGraph(convertingLocalV1: r) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: r.destinationURL)
        #expect(metadata[StoreNativeContext.workspaceKey] as? String == r.operationID.uuidString)
        let doc = try JSONDecoder().decode(GraphV1StagedMigration.Document.self, from: try #require(metadata[StoreNativeMigration.documentKey] as? Data))
        let result = try await manager().openGraph(convertingLocalV1: r), graph = try result.opening.get()
        #expect(result.conversion.receipt.nodeIDs == doc.nodeIDs)
        #expect(try await graph.validateIntegrity() == 5)
        #expect(try await graph.collectSyncChanges() == 5)
        try await graph.close()
    }

    @Test(.enabled(if: nativeV1StagesAvailable)) func concurrentNativeOperationsKeepIndependentIdentityMaps() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var requests = [GraphStoreMigrationRequest]()
        for index in 0..<4 {
            let location = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            let r = request(location); _ = try await seedConversionSource(r.sourceURL); requests.append(r)
        }
        let m = manager()
        let maps = try await withThrowingTaskGroup(of: Set<GraphNodeID>.self) { group in
            for r in requests {
                group.addTask {
                    let result = try await m.openGraph(convertingLocalV1: r), graph = try result.opening.get()
                    #expect(try await graph.validateIntegrity() == 5)
                    #expect(try await graph.collectSyncChanges() == 5)
                    try await graph.close()
                    return Set(result.conversion.receipt.nodeIDs.values)
                }
            }
            var all = [Set<GraphNodeID>](); for try await ids in group { all.append(ids) }; return all
        }
        #expect(maps.count == 4 && Set(maps.flatMap { $0 }).count == 20)
    }
}
