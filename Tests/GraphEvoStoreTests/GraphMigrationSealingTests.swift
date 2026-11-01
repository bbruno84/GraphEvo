import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class WorkspaceSealGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    let arrival = AsyncStream<Void>.makeStream()
    let restriction = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)
    func enable() { lock.withLock { enabled = true } }
    func signalRestriction() { if lock.withLock({ enabled }) { restriction.continuation.yield(()) } }
    func blockOnce() throws {
        guard lock.withLock({ let value = enabled; enabled = false; return value }) else { return }
        arrival.continuation.yield(())
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
    }
    func release() { semaphore.signal() }
}

@Suite(.timeLimit(.minutes(2))) struct GraphMigrationSealingTests {
    private struct Abort: Error {}
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceSeal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func manager() -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func create(_ m: GraphContextManager, _ root: URL) async throws -> GraphStore {
        try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
    }
    private func mutateNative(_ graph: GraphStore, author: String, _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Void) async throws {
        try await graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.transactionAuthor = author
                try body(context)
                try context.save()
            }
        }
    }

    @Test func noOpAndRepeatedSealFreezeWritesKeepReadsAndRecoverFromNativeSeal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let result = try await w.seal()
        #expect(result.changes.isEmpty)
        #expect(result.baseline == result.end)
        #expect(try await w.seal(limits: .init(maximumTransactions: 1)) == result)
        await #expect(throws: (any Error).self) { try await w.graph.removeAll() }
        #expect(try await w.graph.read { _ in true })
        try await w.close()
        try await source.close()
        let restarted = manager(), original = try await restarted.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await restarted.openMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        #expect(try await recovered.seal() == result)
        try await recovered.discard(); try await original.close()
    }

    @Test func repeatedPatchesAndTransientInsertDeleteReduceWithoutSnapshotDiff() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)], tags: ["first"])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let transient = source.makeNodeID()
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(1))])) }
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: transient, type: "Transient")) }
        try await w.graph.transaction { try $0.delete(transient) }
        let seal = try await w.seal()
        #expect(seal.changes == [.init(id: id, kind: .entity, operation: .save)])
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        try await w.discard(); try await source.close()
    }

    @Test func emptyAndRepopulateIncludesBaselineDeletesAndFinalNewPrimitivesAndFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let a = source.makeNodeID(), b = source.makeNodeID(), edge = source.makeNodeID(), action = source.makeNodeID(), file = source.makeNodeID()
        let bytes = Data(repeating: 11, count: 2 * 1024 * 1024)
        try await source.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "A")); try scope.insert(GraphRecord(id: b, type: "B"))
            try scope.insert(GraphRecord(id: edge, type: "Edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "Action", endpoints: .action(subjects: [a], objects: [b])))
            _ = try scope.insert(GraphAttachmentPayload(id: file, ownerID: edge, fileName: "file.bin", contentType: "public.data", data: bytes))
        }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        #expect(try await w.graph.removeAll() == 5)
        let fresh = w.graph.makeNodeID(), newFile = w.graph.makeNodeID()
        try await w.graph.transaction { scope in
            try scope.insert(GraphRecord(id: fresh, type: "Fresh"))
            _ = try scope.insert(GraphAttachmentPayload(id: newFile, ownerID: fresh, fileName: "new.bin", contentType: "public.data", data: bytes))
        }
        let seal = try await w.seal(), deletes = seal.changes.filter { $0.operation == .delete }, saves = seal.changes.filter { $0.operation == .save }
        #expect(Set(deletes.map(\.id)) == Set([a,b,edge,action,file]))
        #expect(Set(saves.map(\.id)) == Set([fresh,newFile]))
        #expect(try JSONEncoder().encode(seal).count < 4096)
        #expect(try await source.attachment(file)?.data == bytes)
        try await w.close(); try await source.close()
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await next.openMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        #expect(try await recovered.seal() == seal)
        #expect(try await recovered.graph.attachment(newFile)?.data == bytes)
        await #expect(throws: (any Error).self) { try await recovered.graph.removeAll() }
        try await recovered.discard(); try await original.close()
    }

    @Test func cascadesAndSurvivingActionAreIncluded() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let a = source.makeNodeID(), b = source.makeNodeID(), c = source.makeNodeID(), edge = source.makeNodeID(), action = source.makeNodeID()
        try await source.transaction { s in
            for id in [a,b,c] { try s.insert(GraphRecord(id: id, type: "Item")) }
            try s.insert(GraphRecord(id: edge, type: "Edge", endpoints: .relationship(subject: a, object: c)))
            try s.insert(GraphRecord(id: action, type: "Action", endpoints: .action(subjects: [a,b], objects: [c])))
        }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await w.graph.transaction { try $0.delete(a) }
        let seal = try await w.seal()
        #expect(seal.changes.contains(.init(id: a, kind: .entity, operation: .delete)))
        #expect(seal.changes.contains(.init(id: edge, kind: .relationship, operation: .delete)))
        #expect(seal.changes.contains(.init(id: action, kind: .action, operation: .save)))
        #expect(try await w.graph.read { try $0.record(for: action)?.endpoints } == .action(subjects: [b], objects: [c]))
        try await w.discard(); try await source.close()
    }

    @Test(arguments: ["transactions", "native", "logical", "encoded", "invalid"])
    func limitsRefuseWithoutSealingOrChangingData(kind: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let a = w.graph.makeNodeID(), b = w.graph.makeNodeID()
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: a, type: "A")) }
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: b, type: "B")) }
        let limits: GraphMigrationWorkspaceLimits
        switch kind {
        case "transactions": limits = .init(maximumTransactions: 1)
        case "native": limits = .init(maximumNativeChanges: 1)
        case "logical": limits = .init(maximumLogicalChanges: 1)
        case "encoded": limits = .init(maximumEncodedBytes: 1)
        default: limits = .init(maximumTransactions: 0)
        }
        await #expect(throws: (any Error).self) { try await w.seal(limits: limits) }
        _ = try await w.graph.transaction { try $0.patch(.init(id: a, properties: ["after": .set(.boolean(true))])) }
        #expect(try await w.seal().changes.count == 2)
        try await w.discard(); try await source.close()
    }

    @Test func editableWorkspaceReopensAfterMovesAndRejectsOldHandlesAndConcurrentOwner() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working")), id = w.graph.makeNodeID()
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Before")) }
        await #expect(throws: (any Error).self) { try await m.openMigrationWorkspace(for: source.id, at: w.directory) }
        #expect(try await w.graph.read { try $0.record(for: id)?.type } == "Before")
        try await w.close(); try await source.close()
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: w.directory, to: moved)
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await next.openMigrationWorkspace(for: source.id, at: moved)
        _ = try await recovered.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        await #expect(throws: (any Error).self) { try await w.graph.read { _ in true } }
        #expect(try await recovered.seal().changes.map(\.id) == [id])
        await #expect(throws: (any Error).self) { try await w.discard() }
        #expect(try await recovered.graph.read { try $0.record(for: id) } != nil)
        try await recovered.discard(); try await original.close()
    }

    @Test func sourceChangesRefuseRecoveryButMetadataOnlyProgressIsAllowed() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let first = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("First"))
        try await first.close()
        try await mutateNative(source, author: GraphSyncCheckpointAdapter.metadataAuthor) { context in
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
            root[dynamicMember: GraphTypedStoreAdapter.prefix + "testMetadata"] = "changed"
        }
        try await mutateNative(source, author: GraphSyncCheckpointAdapter.metadataAuthor) { context in
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
            root[dynamicMember: GraphTypedStoreAdapter.prefix + "testMetadata"] = nil
        }
        let recovered = try await m.openMigrationWorkspace(for: source.id, at: first.directory)
        try await recovered.close()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: source.makeNodeID(), type: "Late")) }
        await #expect(throws: GraphMigrationWorkspaceError.staleSource) { try await m.openMigrationWorkspace(for: source.id, at: first.directory) }
        try await source.transaction { _ in () }
        try await recovered.discard(); try await source.close()
    }

    @Test(arguments: ["foreign", "import", "pruned"])
    func untrustedOrMissingWorkingHistoryIsNeverAnEmptySeal(kind: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        if kind == "pruned" {
            try await w.graph.nativeOperation { container in
                try await container.performBackgroundTask { context in
                    _ = try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
                }
            }
        } else {
            try await mutateNative(w.graph, author: kind == "import" ? GraphSyncCheckpointAdapter.importAuthor : "untrusted") { context in
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
                root[dynamicMember: GraphTypedStoreAdapter.prefix + "testUnknown"] = "value"
            }
        }
        await #expect(throws: (any Error).self) { try await w.seal() }
        try await w.close()
        await #expect(throws: (any Error).self) { try await m.openMigrationWorkspace(for: source.id, at: w.directory) }
        try await w.discard(); try await source.close()
    }
    @Test func cancellationBeforeCommitRollsBackSealAndExplicitRetrySucceeds() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = GraphCoordinatorFactory.adapter, gate = WorkspaceSealGate(), native = try #require(base.workspace)
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            workspace: .init(inspect: native.inspect, seal: { context, descriptor, limits in
                let result = try native.seal(context, descriptor, limits)
                try gate.blockOnce()
                return result
            }), prepareWorkspace: base.prepareWorkspace, validateBackup: base.validateBackup, initialize: base.initialize)
        let m = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
        let source = try await create(m, root), w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        gate.enable()
        let sealing = Task { try await w.seal() }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        sealing.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await sealing.value }
        let id = w.graph.makeNodeID()
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: id, type: "AfterCancellation")) }
        #expect(try await w.seal().changes.map(\.id) == [id])
        try await w.discard(); try await source.close()
    }

    @Test func cancellationAfterSaveReportsCommittedSealAndRecoversIt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspaceSealGate()
        let registry = StoreRegistry(hooks: .init(afterCommit: { try? gate.blockOnce() }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let source = try await create(m, root), w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        gate.enable()
        let sealing = Task { try await w.seal() }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        sealing.cancel(); gate.release()
        let result = try await sealing.value
        await #expect(throws: (any Error).self) { try await w.graph.transaction { _ in () } }
        try await w.close(); try await source.close()
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await next.openMigrationWorkspace(for: source.id, at: w.directory)
        #expect(try await recovered.seal() == result)
        try await recovered.discard(); try await original.close()
    }

    @Test func nativeSealSurvivesLossOfTheInMemoryResultAndGuardsDirectFacadeWrites() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let descriptor = w.descriptor, native = try #require(GraphCoordinatorFactory.adapter.workspace)
        let committed = try await w.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let result = try native.seal(context, descriptor, .init())
                try context.save()
                return result
            }
        }
        // Emulate interruption after the native commit and before runtime result/hold installation.
        await #expect(throws: GraphMigrationWorkspaceError.sealed) { try await w.graph.transaction { _ in () } }
        try await w.close(); try await source.close()
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await next.openMigrationWorkspace(for: source.id, at: w.directory)
        #expect(try await recovered.seal() == committed)
        try await recovered.discard(); try await original.close()
    }

    @Test func sealDrainsAdmittedWritersAndCoalescesConcurrentRequests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspaceSealGate()
        let registry = StoreRegistry(hooks: .init(didRestrictWrites: { gate.signalRestriction() }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let source = try await create(m, root), w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let id = w.graph.makeNodeID()
        gate.enable()
        let writer = Task { try await w.graph.transaction { scope in
            // Signal only after entering the blocked native body, then enable restriction hints.
            try gate.blockOnce()
            try scope.insert(GraphRecord(id: id, type: "Admitted"))
        } }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        gate.enable()
        let sealing = Task { try await w.seal() }
        var restrictions = gate.restriction.stream.makeAsyncIterator(); _ = await restrictions.next()
        await #expect(throws: (any Error).self) { try await w.graph.transaction { _ in () } }
        #expect(try await w.graph.read { try $0.record(for: id) } == nil)
        let joined = Task { try await w.seal() }
        gate.release(); try await writer.value
        let result = try await sealing.value
        #expect(try await joined.value == result)
        #expect(result.changes.map(\.id) == [id])
        try await w.discard(); try await source.close()
    }

    @Test func aliasesRemainFencedAndDiscardWaitsForTheirNativeLease() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let session = try #require(UUID(uuidString: String(decoding: Data(contentsOf: w.directory.appendingPathComponent("activation")), as: UTF8.self)))
        let aliasHandle = try await m.registry.open(.init(location: .sqlite(w.directory.appendingPathComponent("Graph.sqlite")),
            exclusiveGraphID: source.id.rawValue, workspaceID: w.id, workspaceSessionID: session), schema: GraphRuntimeSchema.nativeIdentity)
        let alias = GraphStore.attached(id: source.id, handle: aliasHandle, adapter: GraphCoordinatorFactory.adapter.graph)
        _ = try await w.seal()
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        #expect(try await alias.read { _ in true })
        try await w.close()
        await #expect(throws: (any Error).self) { try await alias.read { _ in true } }
        await #expect(throws: (any Error).self) { try await w.discard() }
        #expect(FileManager.default.fileExists(atPath: w.directory.appendingPathComponent("Graph.sqlite").path))
        try await alias.close(); try await w.discard(); try await source.close()
    }

    @Test(arguments: ["source", "working", "descriptor", "seal"])
    func replacedOrCorruptRecoveryInputsArePreserved(kind: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        if kind == "seal" { _ = try await w.seal() }
        try await w.close(); try await source.close()
        let store = kind == "source" ? root.appendingPathComponent("Source.sqlite") : w.directory.appendingPathComponent("Graph.sqlite")
        var saved: URL?
        if kind == "source" || kind == "working" {
            let old = root.appendingPathComponent("Saved.sqlite")
            try FileManager.default.moveItem(at: store, to: old); try FileManager.default.copyItem(at: old, to: store)
            saved = old
        } else if kind == "descriptor" {
            try Data("{}".utf8).write(to: w.directory.appendingPathComponent("workspace.json"))
        } else {
            let raw = try await m.registry.open(.init(location: .sqlite(store), exclusiveGraphID: source.id.rawValue,
                workspaceID: w.id, workspaceSessionID: UUID()), schema: GraphRuntimeSchema.nativeIdentity)
            try await raw.controlTransaction { context in
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
                root[dynamicMember: GraphMigrationNativeWorkspace.sealKey] = Data("{}".utf8)
            }
            try await raw.close()
        }
        let before = try Data(contentsOf: store)
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        await #expect(throws: (any Error).self) { try await next.openMigrationWorkspace(for: source.id, at: w.directory) }
        #expect(try Data(contentsOf: store) == before)
        try await original.close()
        if let saved { try FileManager.default.removeItem(at: store); try FileManager.default.moveItem(at: saved, to: store) }
    }

    @Test func structuralForeignRowsRefuseSealAndOrdinaryStoresCannotUseWorkspacePrivileges() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let raw = try await m.registry.open(.init(location: .sqlite(root.appendingPathComponent("Source.sqlite")), exclusiveGraphID: source.id.rawValue), schema: GraphRuntimeSchema.nativeIdentity)
        let maintenance = try await raw.reserveMaintenance()
        await #expect(throws: StoreRuntimeError.self) { try await raw.workspaceTransaction(reservation: maintenance) { _ in () } }
        await maintenance.release()
        await #expect(throws: StoreRuntimeError.self) { try await raw.discardWorkspace {} }
        try await raw.close()
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await mutateNative(w.graph, author: GraphSyncCheckpointAdapter.localAuthor) { context in
            let foreign = Entity("Foreign", graph: GraphTypedStoreAdapter.facade(context))
            try GraphNativeIdentityColumns.stamp(foreign, graphID: GraphID(), nodeID: UUID())
        }
        await #expect(throws: (any Error).self) { try await w.seal() }
        try await w.graph.transaction { _ in () }
        #expect(try await source.read { _ in true })
        try await w.discard(); try await source.close()
    }

    @Test func reopeningRotatesCleanupAuthorityEvenAfterTheNewOwnerCloses() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let old = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await old.close()
        let current = try await m.openMigrationWorkspace(for: source.id, at: old.directory)
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await old.discard() }
        try await current.graph.transaction { _ in () }
        try await current.close()
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await old.discard() }
        try await current.discard(); try await source.close()
    }

    @Test func purgedSourceHistoryRefusesReopenWithoutRebasingTheConsumerWork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await w.close()
        let before = try Data(contentsOf: w.directory.appendingPathComponent("workspace.json"))
        try await source.nativeOperation { container in
            try await container.performBackgroundTask { context in
                _ = try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
            }
        }
        await #expect(throws: (any Error).self) { try await m.openMigrationWorkspace(for: source.id, at: w.directory) }
        #expect(try Data(contentsOf: w.directory.appendingPathComponent("workspace.json")) == before)
        try await w.discard(); try await source.close()
    }

    @Test func detailDeletionAndRollbackProduceOnlyCommittedLogicalChanges() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["remove": .integer(1)], tags: ["tag"], groups: ["group"])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        await #expect(throws: Abort.self) {
            try await w.graph.transaction { scope throws -> Void in
                try scope.insert(GraphRecord(id: w.graph.makeNodeID(), type: "RolledBack"))
                throw Abort()
            }
        }
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["remove": .remove], removingTags: ["tag"], removingGroups: ["group"])) }
        #expect(try await w.seal().changes == [.init(id: id, kind: .entity, operation: .save)])
        #expect(try await w.graph.read { try $0.record(for: id)?.properties.isEmpty } == true)
        try await w.discard(); try await source.close()
    }

    @Test func failedDetachedCleanupRetainsGlobalClaimsAndCanRetryWithoutTouchingSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await w.close()
        let owner = w.directory.appendingPathComponent("owner"), before = try Data(contentsOf: owner)
        try Data(UUID().uuidString.utf8).write(to: owner)
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await w.discard() }
        // The native store is detached, but cleanup still owns its global gateway claim.
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreRegistry().open(.init(location: .sqlite(w.directory.appendingPathComponent("Graph.sqlite")),
                exclusiveGraphID: source.id.rawValue, workspaceID: w.id, workspaceSessionID: UUID()), schema: GraphRuntimeSchema.nativeIdentity)
        }
        try await source.transaction { _ in () }
        try before.write(to: owner)
        try await w.discard(); try await source.close()
    }

    @Test func sourceFreshnessChecksPrimitiveEffectsEvenForMetadataAuthoredTransactions() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await w.close()
        try await mutateNative(source, author: GraphSyncCheckpointAdapter.metadataAuthor) { context in
            _ = try GraphNativeIdentityDatabaseAdapter.database.graph.patch(context, source.id,
                GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))]))
        }
        await #expect(throws: GraphMigrationWorkspaceError.staleSource) { try await m.openMigrationWorkspace(for: source.id, at: w.directory) }
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(2))
        try await w.discard(); try await source.close()
    }

}
