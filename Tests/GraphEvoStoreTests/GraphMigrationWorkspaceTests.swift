import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private struct WorkspacePreparationGate: Sendable {
    let arrival = AsyncStream<Void>.makeStream()
    let resume = DispatchSemaphore(value: 0)
    func block() throws {
        arrival.continuation.yield(())
        guard resume.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
    }
}

private actor WorkspaceOpenFailure {
    var loads = 0
    func load() throws {
        loads += 1
        if loads == 2 { throw StoreRuntimeError.shutdownFailed(nil, underlying: GraphMigrationWorkspaceError.unavailable) }
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphMigrationWorkspaceTests {
    private struct Abort: Error {}
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manager(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
    }
    private func boundary(_ graph: GraphStore) async throws -> GraphMigrationBoundary {
        try await graph.nativeOperation { container in
            try await container.performBackgroundTask { try GraphMigrationBoundary.capture($0) }
        }
    }
    private func changes(after boundary: GraphMigrationBoundary, in graph: GraphStore) async throws -> [String] {
        try await graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: boundary.token)
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.resultType = .transactionsAndChanges
                guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction] else { throw Abort() }
                return transactions.map { $0.author ?? "unknown" }
            }
        }
    }

    @Test func coherentCopyPreservesIdentitiesFilesAndPendingOriginalButHasFreshHistoryCut() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let a = source.makeNodeID(), b = source.makeNodeID(), edge = source.makeNodeID(), action = source.makeNodeID(), file = source.makeNodeID()
        let bytes = Data(repeating: 19, count: 2 * 1024 * 1024)
        try await source.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "Item", properties: ["value": .integer(1), "null": .null, "uuid": .uuid(UUID())], tags: ["tag"], groups: ["group"]))
            try scope.insert(GraphRecord(id: b, type: "Child"))
            try scope.insert(GraphRecord(id: edge, type: "Link", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "Use", endpoints: .action(subjects: [a], objects: [b])))
            _ = try scope.insert(GraphAttachmentPayload(id: file, ownerID: a, fileName: "data.bin", contentType: "public.data", data: bytes))
        }
        let batch = try await source.prepareSyncBatch(maximumRecords: 100)
        let workspace = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        #expect(workspace.graph.id == source.id)
        #expect(workspace.descriptor.source.storeID == workspace.descriptor.baseline.storeID)
        let originalRecord = try await source.read { try $0.record(for: a) }
        #expect(try await workspace.graph.read { try $0.record(for: a) } == originalRecord)
        #expect(try await workspace.graph.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: a, object: b))
        #expect(try await workspace.graph.read { try $0.record(for: action)?.endpoints } == .action(subjects: [a], objects: [b]))
        #expect(try await workspace.graph.attachment(file)?.data == bytes)
        #expect(try await changes(after: workspace.descriptor.baseline, in: workspace.graph).isEmpty)
        await #expect(throws: (any Error).self) { try await workspace.graph.collectSyncChanges() }
        let controls = try await workspace.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
                return root[dynamicMember: GraphSyncCheckpointAdapter.stateKey] == nil && root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] == nil
            }
        }
        #expect(controls)
        _ = try await workspace.graph.transaction { try $0.patch(GraphRecordPatch(id: a, properties: ["value": .set(.integer(2))])) }
        #expect(try await changes(after: workspace.descriptor.baseline, in: workspace.graph) == [GraphSyncCheckpointAdapter.localAuthor])
        #expect(try await source.read { try $0.record(for: a)?.properties["value"] } == .integer(1))
        #expect(try await workspace.graph.removeAll() == 5)
        #expect(try await source.attachment(file)?.data == bytes)
        let encoded = try Data(contentsOf: workspace.directory.appendingPathComponent("workspace.json"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(root.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
        try await workspace.close()
        #expect(try await source.acknowledgeSyncBatch(batch.id, succeeded: Set(batch.items.map { $0.change.id })) == 5)
        #expect(try await source.collectSyncChanges() == 0)
        try await workspace.discard(); try await source.close()
    }

    @Test func ordinaryOpeningsAndWrongPurposeAreRefusedEvenAfterClose() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let workspace = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let url = workspace.directory.appendingPathComponent("Graph.sqlite")
        await #expect(throws: (any Error).self) { try await manager().openGraph(id: source.id, at: url) }
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
        try await workspace.close()
        await #expect(throws: (any Error).self) { try await manager().openGraph(id: source.id, at: url) }
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: url, schema: .nativeIdentity) }
        await #expect(throws: (any Error).self) {
            try await StoreRegistry().open(.init(location: .sqlite(url), exclusiveGraphID: source.id.rawValue, workspaceID: UUID()), schema: GraphRuntimeSchema.nativeIdentity)
        }
        await #expect(throws: (any Error).self) {
            try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Missing.sqlite")), exclusiveGraphID: source.id.rawValue, workspaceID: UUID()), schema: GraphRuntimeSchema.nativeIdentity)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Missing.sqlite").path))
        await #expect(throws: (any Error).self) { try await workspace.graph.read { _ in true } }
        try await workspace.discard(); try await source.close()
    }

    @Test func overlappingMigrationsAndCallerHoldsRemainIndependent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), url = root.appendingPathComponent("A.sqlite")
        let a = try await m.createGraph(id: GraphID(), at: url), alias = try await m.openGraph(id: a.id, at: url)
        let b = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        try await m.pauseCloudSynchronization(for: a.id)
        let hold = try await m.suspendLocalWrites(for: a.id)
        let first = try await m.prepareMigrationWorkspace(for: a.id, at: root.appendingPathComponent("First"))
        let second = try await m.prepareMigrationWorkspace(for: a.id, at: root.appendingPathComponent("Second"))
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        #expect(try await alias.read { _ in true })
        _ = try await b.transaction { try $0.insert(GraphRecord(id: b.makeNodeID(), type: "Independent")) }
        try await first.discard(); await hold.release()
        await #expect(throws: (any Error).self) { try await alias.transaction { _ in () } }
        try await second.close()
        try await alias.transaction { _ in () }
        #expect(try await m.cloudSynchronizationState(for: a.id) == .paused)
        try await m.resumeCloudSynchronization(for: a.id)
        try await second.discard(); try await alias.close(); try await a.close(); try await b.close()
    }

    @Test(arguments: [GraphCloudSharePermission.readOnly, .readWrite])
    func participantsAreRefusedWithoutRemovingTheirAuthority(permission: GraphCloudSharePermission) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let access = GraphCloudParticipantAccess(binding: .init(zone: .init(scope: .shared, owner: "owner", name: "test"), graphID: source.id), account: "participant", permission: permission, accepted: true)
        _ = try await source.participantAccess(access)
        await #expect(throws: GraphMigrationWorkspaceError.participantUnsupported) {
            try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        }
        #expect(try await source.participantAccess() == access)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Working").path))
        #expect(try await m.cloudSynchronizationState(for: source.id) == .active)
        try await source.close()
    }

    @Test func validationFailurePreservesSourceAndReleasesOnlyOwnedHolds() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let native = GraphCoordinatorFactory.adapter
        let adapter = GraphCoordinatorAdapter(graph: native.graph, sync: native.sync, initializePolicy: native.initializePolicy,
            prepareWorkspace: native.prepareWorkspace, validateBackup: { _, _ in throw Abort() }, initialize: native.initialize)
        let m = manager(adapter: adapter), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let id = source.makeNodeID()
        _ = try await source.transaction { try $0.insert(GraphRecord(id: id, type: "Item")) }
        try await m.pauseCloudSynchronization(for: source.id)
        await #expect(throws: Abort.self) { try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working")) }
        #expect(try await source.read { try $0.record(for: id) } != nil)
        try await source.transaction { _ in () }
        #expect(try await m.cloudSynchronizationState(for: source.id) == .paused)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".workspace-") && $0 != "Working" && $0 != "Backups" })
        try await source.close()
    }

    @Test func occupiedAndNestedDestinationsAreUntouchedAndCancellationDoesNotCreateCopy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let occupied = root.appendingPathComponent("Occupied"), bytes = Data([1, 2, 3])
        try bytes.write(to: occupied)
        await #expect(throws: GraphMigrationWorkspaceError.invalidDestination) { try await m.prepareMigrationWorkspace(for: source.id, at: occupied) }
        await #expect(throws: GraphMigrationWorkspaceError.invalidDestination) { try await m.prepareMigrationWorkspace(for: source.id, at: root) }
        #expect(try Data(contentsOf: occupied) == bytes)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Cancelled")) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Cancelled").path))
        try await source.transaction { _ in () }; try await source.close()
    }

    @Test func discardRefusesReplacedDirectoryCorruptDescriptorAndLinks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let workspace = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        try await workspace.close()
        let saved = root.appendingPathComponent("Saved")
        try FileManager.default.moveItem(at: workspace.directory, to: saved)
        try FileManager.default.createDirectory(at: workspace.directory, withIntermediateDirectories: false)
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await workspace.discard() }
        try FileManager.default.removeItem(at: workspace.directory); try FileManager.default.moveItem(at: saved, to: workspace.directory)
        let manifest = workspace.directory.appendingPathComponent("workspace.json"), original = try Data(contentsOf: manifest)
        try Data("{}".utf8).write(to: manifest)
        await #expect(throws: (any Error).self) { try await workspace.discard() }
        try original.write(to: manifest)
        let link = workspace.directory.appendingPathComponent("unexpected")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("A.sqlite"))
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await workspace.discard() }
        try FileManager.default.removeItem(at: link)
        let store = workspace.directory.appendingPathComponent("Graph.sqlite"), savedStore = root.appendingPathComponent("Saved.sqlite")
        try FileManager.default.moveItem(at: store, to: savedStore)
        try FileManager.default.copyItem(at: savedStore, to: store)
        await #expect(throws: GraphMigrationWorkspaceError.invalidWorkspace) { try await workspace.discard() }
        try FileManager.default.removeItem(at: store); try FileManager.default.moveItem(at: savedStore, to: store)
        try await workspace.discard(); try await workspace.discard()
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
        try await source.transaction { _ in () }; try await source.close()
    }
    @Test func cancellationDuringPreparationRollsBackCopyAndKeepsCallerReservation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let native = GraphCoordinatorFactory.adapter, gate = WorkspacePreparationGate()
        let adapter = GraphCoordinatorAdapter(graph: native.graph, sync: native.sync, initializePolicy: native.initializePolicy,
            prepareWorkspace: native.prepareWorkspace, validateBackup: { context, id in
                try gate.block(); try native.validateBackup?(context, id)
            }, initialize: native.initialize)
        let m = manager(adapter: adapter), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let caller = try await m.suspendLocalWrites(for: source.id)
        let operation = Task { try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working")) }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        #expect(try await source.read { _ in true })
        operation.cancel(); gate.resume.signal()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await #expect(throws: (any Error).self) { try await source.transaction { _ in () } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".workspace-") && $0 != "Working" })
        await caller.release()
        try await source.transaction { _ in () }; try await source.close()
    }

    @Test func closeDrainsWorkingWriterBeforeRestoringOriginalAndTerminatesObservation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        let workspace = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let observation = try await workspace.graph.observe(observationQuery())
        var observed = observation.makeAsyncIterator()
        if case .value = await observed.next() {} else { Issue.record("Expected working query's initial value") }
        let gate = WorkspacePreparationGate(), id = workspace.graph.makeNodeID()
        let writer = Task { try await workspace.graph.transaction { scope in
            try gate.block()
            try scope.insert(GraphRecord(id: id, type: "Working"))
        } }
        var arrivals = gate.arrival.stream.makeAsyncIterator(); _ = await arrivals.next()
        let closing = Task { try await workspace.close() }
        await #expect(throws: (any Error).self) { try await source.transaction { _ in () } }
        gate.resume.signal(); try await writer.value; try await closing.value
        #expect(await observed.next() == nil)
        #expect(try await source.read { try $0.record(for: id) } == nil)
        try await source.transaction { _ in () }
        async let first: Void = workspace.discard()
        async let second: Void = workspace.discard()
        _ = try await (first, second)
        try await source.close()
    }

    @Test func frozenCloudTransportIsRemovedOnlyFromCopyAndDeletionEvidenceIsPreserved() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"), conflictPolicy: .cloudWins)
        let deleted = source.makeNodeID(), surviving = source.makeNodeID()
        try await source.transaction { scope in
            try scope.insert(GraphRecord(id: deleted, type: "Deleted"))
            try scope.insert(GraphRecord(id: surviving, type: "Kept"))
        }
        try await source.transaction { try $0.delete(deleted) }
        let binding = GraphCloudTransportBinding(identity: .init(container: "iCloud.workspace.test", environment: .development, account: "test-account"),
            route: .init(zone: .init(scope: .private, owner: "owner", name: "test-zone"), graphID: source.id))
        let frozen = try await source.prepareTransport(binding)
        let workspace = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
        let metadata = try await workspace.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                let session = try GraphTypedStoreAdapter.Session(context, source.id, database: true)
                let control = try GraphTypedStoreAdapter.controlRoot(context, id: source.id)
                return (control[dynamicMember: GraphSyncCheckpointAdapter.transportKey] == nil,
                    try GraphMutationMetadata.policy(control), try GraphMutationMetadata.deletedIDs(control),
                    try session.nodes[surviving].map { try GraphMutationMetadata.modifiedAt($0) })
            }
        }
        #expect(metadata.0 && metadata.1 == .cloudWins)
        #expect(metadata.2.contains(deleted.rawValue.uuidString))
        #expect(metadata.3 != nil)
        await #expect(throws: (any Error).self) {
            try await workspace.graph.transaction { try $0.insert(GraphRecord(id: deleted, type: "Reused")) }
        }
        try await workspace.close()
        #expect(try await source.prepareTransport(binding) == frozen)
        #expect(try await source.conflictPolicy == .cloudWins)
        try await workspace.discard(); try await source.close()
    }

    @Test func shutdownFailureWithoutReturnedHandlePreservesStageAndReportsCleanup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let failure = WorkspaceOpenFailure()
        // Simulate the registry's failed-open error without leaving a native test owner attached.
        let registry = StoreRegistry(hooks: .init(beforeLoad: { try await failure.load() }))
        let m = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let source = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("A.sqlite"))
        do {
            _ = try await m.prepareMigrationWorkspace(for: source.id, at: root.appendingPathComponent("Working"))
            Issue.record("Expected a visible retained-stage cleanup failure")
        } catch let error as GraphMigrationWorkspaceCleanupFailure {
            #expect(error.directory.lastPathComponent.hasPrefix(".workspace-"))
            #expect(FileManager.default.fileExists(atPath: error.directory.appendingPathComponent("Graph.sqlite").path))
        }
        #expect(try await m.cloudSynchronizationState(for: source.id) == .active)
        try await source.transaction { _ in () }; try await source.close()
    }

}
