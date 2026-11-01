import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class PublicationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func arm() { lock.withLock { enabled = true } }
    func failOnce() throws { if lock.withLock({ let value = enabled; enabled = false; return value }) { throw GraphMigrationPublicationError.unsupportedStructure } }
}

private final class PublicationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func advance() { lock.withLock { date = Date(timeIntervalSince1970: 2000) } }
    func now() -> Date { lock.withLock { date } }
}
private final class PublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    let arrival = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { enabled = true } }
    func blockOnce() {
        guard lock.withLock({ let value = enabled; enabled = false; return value }) else { return }
        arrival.continuation.yield(())
        _ = semaphore.wait(timeout: .now() + 10)
    }
    func release() { semaphore.signal() }
}

@Suite(.timeLimit(.minutes(2))) struct GraphMigrationPublicationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func manager(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
    }
    private func create(_ m: GraphContextManager, _ root: URL) async throws -> GraphStore {
        try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
    }
    private func originalIdentity(_ graph: GraphStore) async throws -> String {
        try await graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let coordinator = try #require(context.persistentStoreCoordinator), store = try #require(coordinator.persistentStores.first)
                return try #require(coordinator.metadata(for: store)[NSStoreUUIDKey] as? String)
            }
        }
    }

    @Test func patchCascadeAndSurvivingActionPublishWithBackupAndPreserveFrozenGeneration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), nativeID = try await originalIdentity(source)
        let a = source.makeNodeID(), b = source.makeNodeID(), edge = source.makeNodeID(), action = source.makeNodeID(), file = source.makeNodeID()
        let bytes = Data(repeating: 5, count: 2 * 1024 * 1024)
        try await source.transaction { s in
            try s.insert(GraphRecord(id: a, type: "A", properties: ["value": .integer(1)], tags: ["before"]))
            try s.insert(GraphRecord(id: b, type: "B"))
            try s.insert(GraphRecord(id: edge, type: "Edge", endpoints: .relationship(subject: a, object: b)))
            try s.insert(GraphRecord(id: action, type: "Action", endpoints: .action(subjects: [a,b], objects: [a])))
            _ = try s.insert(GraphAttachmentPayload(id: file, ownerID: edge, fileName: "before.bin", contentType: "public.data", data: bytes))
        }
        let frozen = try await source.prepareSyncBatch(maximumRecords: 100)
        let before = try await source.read { try $0.record(for: a) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.patch(.init(id: a, properties: ["value": .set(.integer(2))], addingTags: ["after"], removingTags: ["before"])) }
        try await w.graph.transaction { try $0.delete(b) }
        let seal = try await w.seal()
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        let result = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"), reason: "Consumer migration example")
        #expect(result.receipt.selectedChanges == seal.changes.count)
        #expect(!result.backupRetentionPending)
        #expect(try await source.read { try $0.record(for: a)?.properties["value"] } == .integer(2))
        #expect(try await source.read { try $0.record(for: a)?.createdDate } == before?.createdDate)
        #expect(try await source.read { try $0.record(for: action)?.endpoints } == .action(subjects: [a], objects: [a]))
        #expect(try await source.attachment(file) == nil)
        #expect(try await source.read { try $0.record(for: edge) } == nil)
        #expect(try await originalIdentity(source) == nativeID)
        #expect(try await source.acknowledgeSyncBatch(frozen.id, succeeded: Set(frozen.items.map { $0.change.id })) == 0)
        #expect(try await source.collectSyncChanges() == seal.changes.count)
        try await source.transaction { _ in () }
        let backups = try await m.backups.list(in: root.appendingPathComponent("Backups"))
        #expect(backups.count == 1 && backups[0].manifest.reason == "Consumer migration example")
        #expect(try await m.backups.retentionOwners(at: result.backupURL).isEmpty)
        let restored = try await m.backups.restore(at: result.backupURL, to: root.appendingPathComponent("Restored"))
        let peer = manager(), old = try await peer.openGraph(id: source.id, at: restored.storeURL)
        #expect(try await old.read { try $0.record(for: a)?.properties["value"] } == .integer(1))
        #expect(try await old.attachment(file)?.data == bytes)
        try await old.close()
        let repeated = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"))
        #expect(repeated.receipt == result.receipt)
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        try await w.discard(); try await source.close()
    }

    @Test func emptyAndRepopulatePublishesFilesAndRetainsDeletionIdentity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), oldID = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: oldID, type: "Old")) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        #expect(try await w.graph.removeAll() == 1)
        let fresh = w.graph.makeNodeID(), file = w.graph.makeNodeID(), bytes = Data(repeating: 7, count: 2 * 1024 * 1024)
        try await w.graph.transaction { s in
            try s.insert(GraphRecord(id: fresh, type: "Fresh"))
            _ = try s.insert(GraphAttachmentPayload(id: file, ownerID: fresh, fileName: "new.bin", contentType: "public.data", data: bytes))
        }
        let result = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"))
        #expect(result.receipt.selectedChanges == 3)
        #expect(try await source.read { try $0.record(for: oldID) } == nil)
        #expect(try await source.attachment(file)?.data == bytes)
        await #expect(throws: (any Error).self) { try await source.transaction { try $0.insert(GraphRecord(id: oldID, type: "Reused")) } }
        #expect(try await source.collectSyncChanges() == 3)
        try await w.discard(); try await source.close()
    }

    @Test(arguments: ["records", "payload", "invalid"])
    func limitsCreateNoBackupOrIntentAndRetryDoesNotReplayTheConsumer(kind: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await w.graph.transaction { s in
            try s.insert(GraphRecord(id: w.graph.makeNodeID(), type: "A", properties: ["bytes": .data(Data(repeating: 9, count: 1024))]))
            try s.insert(GraphRecord(id: w.graph.makeNodeID(), type: "B"))
        }
        let limits: GraphMigrationPublicationLimits = kind == "records" ? .init(maximumRecords: 1) : (kind == "payload" ? .init(maximumPayloadBytes: 1) : .init(maximumRecords: 0))
        await #expect(throws: (any Error).self) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"), limits: limits) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: w.directory.appendingPathComponent("publication.json").path))
        #expect(try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")).receipt.selectedChanges == 2)
        try await w.discard(); try await source.close()
    }

    @Test func failedApplyRollsBackAndReusesThePinnedVerifiedBackup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = GraphCoordinatorFactory.adapter, native = try #require(base.publication), failure = PublicationFailure()
        let publication = GraphMigrationPublicationAdapter(snapshot: native.snapshot, receipt: native.receipt, preflight: native.preflight,
            apply: { context, descriptor, seal, intent, items in
                let receipt = try native.apply(context, descriptor, seal, intent, items)
                try failure.failOnce()
                return receipt
            })
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            publication: publication, workspace: base.workspace, prepareWorkspace: base.prepareWorkspace,
            validateBackup: base.validateBackup, initialize: base.initialize)
        let m = manager(adapter: adapter), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        failure.arm()
        await #expect(throws: GraphMigrationPublicationError.unsupportedStructure) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        let backups = try await m.backups.list(in: root.appendingPathComponent("Backups"))
        #expect(backups.count == 1)
        #expect(try await m.backups.retentionOwners(at: backups[0].url) == [w.id])
        await #expect(throws: GraphBackupError.retained) { try await m.backups.remove(at: backups[0].url) }
        await #expect(throws: (any Error).self) { try await source.transaction { _ in () } }
        let result = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"))
        #expect(result.receipt.backupID == backups[0].manifest.id)
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(2))
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        try await w.discard(); try await source.close()
    }
    @Test func allTypedValuesEndpointsAndPerRecordDatesArePreserved() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = PublicationClock(), m = manager(adapter: GraphCoordinatorFactory.makeAdapter(clock: { clock.now() }))
        let source = try await create(m, root), a = source.makeNodeID(), b = source.makeNodeID(), edge = source.makeNodeID()
        try await source.transaction { s in
            try s.insert(GraphRecord(id: a, type: "A")); try s.insert(GraphRecord(id: b, type: "B"))
            try s.insert(GraphRecord(id: edge, type: "Edge", endpoints: .relationship(subject: a, object: b)))
        }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working")), fresh = w.graph.makeNodeID()
        clock.advance()
        let payload: [String: GraphValue] = ["null": .null, "uuid": .uuid(UUID()), "array": .array([.integer(7), .string("text")]),
            "encoded": .encoded(try GraphEncodedValue(codec: "consumer", version: 1, data: Data([1,2,3])))]
        try await w.graph.transaction { s in
            try s.insert(GraphRecord(id: fresh, type: "New", properties: payload))
            _ = try s.patch(GraphRecordPatch(id: edge, endpoints: .relationship(subject: fresh, object: a)))
        }
        let expected = try await w.graph.read { try $0.record(for: fresh) }
        _ = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"))
        #expect(try await source.read { try $0.record(for: fresh) } == expected)
        #expect(try await source.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: fresh, object: a))
        let modified = try await source.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let session = try GraphTypedStoreAdapter.Session(context, source.id, database: true)
                let node = try #require(session.nodes[fresh])
                return try GraphMutationMetadata.modifiedAt(node)
            }
        }
        #expect(modified == Date(timeIntervalSince1970: 2000))
        try await w.discard(); try await source.close()
    }

    @Test func backupValidationFailureCannotCommitAndRetryRetainsOneBackup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = GraphCoordinatorFactory.adapter, failure = PublicationFailure()
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            publication: base.publication, workspace: base.workspace, prepareWorkspace: base.prepareWorkspace,
            validateBackup: { context, id in try failure.failOnce(); try base.validateBackup?(context, id) }, initialize: base.initialize)
        let m = manager(adapter: adapter), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        failure.arm()
        await #expect(throws: (any Error).self) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        #expect(try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")).receipt.selectedChanges == 1)
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        try await w.discard(); try await source.close()
    }

    @Test func nativeCommitBeforeResultRecoversWithoutReapplyingOrOverwritingLaterEdits() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        let seal = try await w.seal(), native = try #require(GraphCoordinatorFactory.adapter.publication)
        let items = try await w.publicationItems(seal, adapter: native, limits: .init())
        let intent = try await w.publicationIntent(seal, reason: "Recovery example")
        let backup = try await m.snapshotBackup(for: source.id, in: root.appendingPathComponent("Backups"), reason: intent.reason,
            artifacts: [.init(name: "__graphevo_publication.json", data: try intent.encoded())], backupID: intent.backupID, retentionOwner: w.id)
        let raw = try await m.registry.open(.init(location: .sqlite(root.appendingPathComponent("Source.sqlite")), exclusiveGraphID: source.id.rawValue), schema: GraphRuntimeSchema.nativeIdentity)
        let maintenance = try await raw.reserveMaintenance(), descriptor = w.descriptor
        let committed = try await raw.publicationTransaction(graphID: source.id.rawValue, reservation: maintenance) {
            try native.apply($0, descriptor, seal, intent, items)
        }
        await maintenance.release(); try await raw.close()
        // The original's native commit is authoritative even though no workspace result was installed.
        try await w.close()
        _ = try await source.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(3))])) }
        try await source.close()
        let moved = root.appendingPathComponent("MovedBackups")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Backups"), to: moved)
        let next = manager(), original = try await next.openGraph(id: source.id, at: root.appendingPathComponent("Source.sqlite"))
        let recovered = try await next.openMigrationWorkspace(for: source.id, at: w.directory)
        let result = try await next.publishMigrationWorkspace(recovered, backupsIn: moved)
        #expect(result.receipt == committed)
        #expect(try await original.read { try $0.record(for: id)?.properties["value"] } == .integer(3))
        #expect(try await next.backups.list(in: moved).count == 1)
        #expect(try await next.backups.retentionOwners(at: moved.appendingPathComponent(backup.manifest.id.uuidString).appendingPathExtension("geb")).isEmpty)
        try await recovered.discard(); try await original.close()
    }

    @Test func cancellationAfterCommitReturnsReceiptAndOriginalWritesResume() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PublicationGate(), registry = StoreRegistry(hooks: .init(afterCommit: { gate.blockOnce() }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let source = try await create(m, root), w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working")), id = w.graph.makeNodeID()
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: id, type: "Published")) }
        _ = try await w.seal(); gate.arm()
        let operation = Task { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        operation.cancel(); gate.release()
        let result = try await operation.value
        #expect(result.receipt.selectedChanges == 1)
        #expect(try await source.read { try $0.record(for: id)?.type } == "Published")
        try await source.transaction { _ in () }
        #expect(try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")).receipt == result.receipt)
        try await w.discard(); try await source.close()
    }

    @Test func anotherManagerCannotBorrowWorkspaceHoldsAndManualReservationsSurviveCommit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let hold = try await m.suspendLocalWrites(for: source.id)
        try await m.pauseCloudSynchronization(for: source.id)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        await #expect(throws: (any Error).self) { try await manager().publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        _ = try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"))
        await #expect(throws: (any Error).self) { try await source.transaction { _ in () } }
        #expect(try await m.cloudSynchronizationState(for: source.id) == .paused)
        await hold.release()
        try await source.transaction { _ in () }
        try await m.resumeCloudSynchronization(for: source.id)
        try await w.discard(); try await source.close()
    }

    @Test func cancellationBeforeSaveRollsBackAndCloseWaitsForAnAdmittedPublication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = GraphCoordinatorFactory.adapter, native = try #require(base.publication), gate = PublicationGate()
        let wrapped = GraphMigrationPublicationAdapter(snapshot: native.snapshot, receipt: native.receipt, preflight: native.preflight,
            apply: { context, descriptor, seal, intent, items in
                let result = try native.apply(context, descriptor, seal, intent, items)
                gate.blockOnce()
                return result
            })
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            publication: wrapped, workspace: base.workspace, prepareWorkspace: base.prepareWorkspace, validateBackup: base.validateBackup, initialize: base.initialize)
        let m = manager(adapter: adapter), source = try await create(m, root), id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item", properties: ["value": .integer(1)])) }
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.patch(.init(id: id, properties: ["value": .set(.integer(2))])) }
        gate.arm()
        let operation = Task { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        let closing = Task { try await w.close() }
        operation.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        try await closing.value
        #expect(try await source.read { try $0.record(for: id)?.properties["value"] } == .integer(1))
        try await source.transaction { _ in () }
        let reopened = try await m.openMigrationWorkspace(for: source.id, at: w.directory)
        #expect(try await m.publishMigrationWorkspace(reopened, backupsIn: root.appendingPathComponent("Backups")).receipt.selectedChanges == 1)
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        try await reopened.discard(); try await source.close()
    }

    @Test func corruptPinnedBackupRefusesRetryWithoutChangingOriginal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = GraphCoordinatorFactory.adapter, native = try #require(base.publication), failure = PublicationFailure()
        let wrapped = GraphMigrationPublicationAdapter(snapshot: native.snapshot, receipt: native.receipt, preflight: native.preflight,
            apply: { context, descriptor, seal, intent, items in
                try failure.failOnce()
                return try native.apply(context, descriptor, seal, intent, items)
            })
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, initializePolicy: base.initializePolicy,
            publication: wrapped, workspace: base.workspace, prepareWorkspace: base.prepareWorkspace, validateBackup: base.validateBackup, initialize: base.initialize)
        let m = manager(adapter: adapter), source = try await create(m, root), id = source.makeNodeID()
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        _ = try await w.graph.transaction { try $0.insert(GraphRecord(id: id, type: "New")) }
        failure.arm()
        await #expect(throws: (any Error).self) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        let backups = try await m.backups.list(in: root.appendingPathComponent("Backups"))
        let backup = try #require(backups.first)
        try Data("corrupt".utf8).write(to: backup.url)
        await #expect(throws: (any Error).self) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await source.read { try $0.record(for: id) } == nil)
        #expect(try Data(contentsOf: backup.url) == Data("corrupt".utf8))
        try await w.discard(); try await source.close()
    }

    @Test func invalidReasonAndIntentNeverCreateBackupOrAcknowledgePublication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await create(m, root)
        let w = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        await #expect(throws: GraphBackupError.invalidReason) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups"), reason: "   ") }
        #expect(!FileManager.default.fileExists(atPath: w.directory.appendingPathComponent("publication.json").path))
        try Data("{}".utf8).write(to: w.directory.appendingPathComponent("publication.json"))
        await #expect(throws: (any Error).self) { try await m.publishMigrationWorkspace(w, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        try await w.discard(); try await source.close()
    }

}
