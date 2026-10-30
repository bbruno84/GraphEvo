import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor SyncTestSignal {
    private var signalled = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !signalled { await withCheckedContinuation { waiting.append($0) } } }
    func signal() {
        signalled = true
        let values = waiting; waiting.removeAll()
        for value in values { value.resume() }
    }
}

@Suite(.timeLimit(.minutes(2))) struct GraphSyncPendingTests {
    private struct Fixture {
        let directory: URL; let url: URL; let manager: GraphContextManager; let graph: GraphStore
        let a: GraphNodeID; let b: GraphNodeID
    }
    private func fixture(adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter,
                         registry: StoreRegistry = StoreRegistry()) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Graph.sqlite")
        let manager = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
        let graph = try await manager.createGraph(id: GraphID(), at: url)
        let a = graph.makeNodeID(), b = graph.makeNodeID()
        try await graph.transaction {
            try $0.insert(GraphRecord(id: a, type: ObservedItem.graphType, properties: ["value": .integer(1)], tags: ["initial"], groups: ["initial"]))
            try $0.insert(GraphRecord(id: b, type: "child"))
        }
        return Fixture(directory: directory, url: url, manager: manager, graph: graph, a: a, b: b)
    }
    private func acknowledgeAll(_ graph: GraphStore) async throws {
        let batch = try await graph.prepareSyncBatch(maximumRecords: 100)
        _ = try await graph.acknowledgeSyncBatch(batch.id, succeeded: Set(batch.items.map { $0.change.id }))
    }
    private func state(_ graph: GraphStore, replacing: Data? = nil) async throws -> Data? {
        let id = graph.id
        return try await graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                context.userInfo[StoreNativeContext.privateURLKey] = container.persistentStoreCoordinator.persistentStores.first?.url
                let facade = GraphTypedStoreAdapter.facade(context)
                let root = try #require(Search<Entity>(graph: facade).where(.type(GraphTypedStoreAdapter.rootType)).sync().first)
                if let replacing {
                    root[dynamicMember: GraphSyncCheckpointAdapter.stateKey] = replacing
                    context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
                    try context.save()
                }
                #expect(root[dynamicMember: GraphTypedStoreAdapter.graphKey] as? String == id.rawValue.uuidString)
                return root[dynamicMember: GraphSyncCheckpointAdapter.stateKey] as? Data
            }
        }
    }

    @Test func updatesCoalesceAndOldAcknowledgementsKeepNewerChanges() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let batch = try await f.graph.prepareSyncBatch(maximumRecords: 10)
        #expect(Set(batch.items.map { $0.change.id }) == [f.a, f.b])
        for number in 2...4 { try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(Int64(number)))])) } }
        #expect(batch.items.first { $0.change.id == f.a }?.record?.properties["value"] == .integer(1))
        #expect(try await f.graph.acknowledgeSyncBatch(batch.id, succeeded: [f.a, f.b]) == 1)
        let next = try await f.graph.prepareSyncBatch(maximumRecords: 10)
        #expect(next.items.count == 1 && next.items.first?.change.id == f.a)
        #expect(next.items.first?.record?.properties["value"] == .integer(4))
        #expect(next.items.first!.change.generation > batch.items.first { $0.change.id == f.a }!.change.generation)
        _ = try await f.graph.acknowledgeSyncBatch(next.id, succeeded: [f.a])
        #expect(try await f.graph.collectSyncChanges() == 0)
        try await f.graph.close()
    }

    @Test func failedPublicationRollsBackCheckpointAndReplaysCommittedData() async throws {
        struct Interrupted: Error {}
        let base = GraphCoordinatorFactory.adapter, sync = try #require(base.sync)
        let failing = GraphSyncAdapter(collect: { context, id, limits in
            _ = try sync.collect(context, id, limits)
            throw Interrupted()
        }, prepare: sync.prepare, acknowledge: sync.acknowledge, importPatches: sync.importPatches)
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: failing, initialize: base.initialize)
        let f = try await fixture(adapter: adapter); defer { try? FileManager.default.removeItem(at: f.directory) }
        await #expect(throws: Interrupted.self) { try await f.graph.collectSyncChanges() }
        #expect(try await state(f.graph) == nil)
        #expect(try await f.graph.read { try $0.record(for: f.a)?.properties["value"] } == .integer(1))
        try await f.graph.close()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: base)
        let reopened = try await manager.openGraph(id: f.graph.id, at: f.url)
        #expect(try await reopened.collectSyncChanges() == 2)
        try await reopened.close()
    }

    @Test func pendingAndCheckpointSurviveReopenAndRejectOldReceipts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let batch = try await f.graph.prepareSyncBatch(maximumRecords: 10)
        let before = try await state(f.graph)
        try await f.graph.close()
        let reopened = try await f.manager.openGraph(id: f.graph.id, at: f.url)
        #expect(try await state(reopened) == before)
        await #expect(throws: GraphSyncError.self) { try await reopened.acknowledgeSyncBatch(batch.id, succeeded: [f.a]) }
        let next = try await reopened.prepareSyncBatch(maximumRecords: 10)
        #expect(next.items.map(\.change) == batch.items.map(\.change))
        _ = try await reopened.acknowledgeSyncBatch(next.id, succeeded: [f.a])
        #expect(try await reopened.collectSyncChanges() == 1)
        await #expect(throws: GraphSyncError.self) { try await reopened.acknowledgeSyncBatch(next.id, succeeded: [f.b]) }
        try await reopened.close()
    }

    @Test func bookkeepingDoesNotFeedHistoryBackIntoItself() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(try await f.graph.collectSyncChanges() == 2)
        let before = try await state(f.graph)
        for _ in 0..<4 { #expect(try await f.graph.collectSyncChanges() == 2) }
        #expect(try await state(f.graph) == before)
        try await acknowledgeAll(f.graph)
        let empty = try await state(f.graph)
        for _ in 0..<4 { #expect(try await f.graph.collectSyncChanges() == 0) }
        #expect(try await state(f.graph) == empty)
        try await f.graph.close()
    }

    @Test func importsRemainObservableWithoutUploadAcrossReopen() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await acknowledgeAll(f.graph)
        let observation = try await f.graph.observe(observationQuery())
        _ = try await waitForObservation(observation) { $0.items.first?.record.properties["value"] == .integer(1) }
        try await f.graph.applyImportedPatches([GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(20))])])
        _ = try await waitForObservation(observation) { $0.items.first?.record.properties["value"] == .integer(20) }
        #expect(try await f.graph.collectSyncChanges() == 0)
        observation.cancel(); try await f.graph.close()
        let reopened = try await f.manager.openGraph(id: f.graph.id, at: f.url)
        #expect(try await reopened.collectSyncChanges() == 0)
        try await reopened.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(21))])) }
        let batch = try await reopened.prepareSyncBatch(maximumRecords: 10)
        #expect(batch.items.map { $0.change.id } == [f.a])
        try await reopened.abandonSyncBatch(batch.id); try await reopened.close()
    }

    @Test func importCannotOverwriteUncollectedLocalChanges() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(try await state(f.graph) == nil)
        await #expect(throws: GraphSyncError.self) {
            try await f.graph.applyImportedPatches([GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(99))])])
        }
        #expect(try await state(f.graph) == nil)
        #expect(try await f.graph.read { try $0.record(for: f.a)?.properties["value"] } == .integer(1))
        #expect(try await f.graph.collectSyncChanges() == 2)
        try await f.graph.close()
    }

    @Test func deletedDetailsCascadesAndRecreationRemainRecoverable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let edge = f.graph.makeNodeID(), action = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: f.a, object: f.b)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [f.a], objects: [f.b])))
        }
        let source = f.directory.appendingPathComponent("input.bin"); try Data([1, 2, 3]).write(to: source)
        let file = try await f.graph.importAttachment(from: source, ownedBy: edge)
        try await acknowledgeAll(f.graph)
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(2))])) }
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .remove], removingTags: ["initial"], removingGroups: ["initial"])) }
        try await f.graph.delete(f.a)
        let batch = try await f.graph.prepareSyncBatch(maximumRecords: 100)
        for id in [f.a, edge, file.id] {
            let item = try #require(batch.items.first { $0.change.id == id })
            #expect(item.change.operation == .delete && item.record == nil)
        }
        #expect(batch.items.first { $0.change.id == action }?.record?.endpoints == .action(subjects: [], objects: [f.b]))
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: f.a, type: ObservedItem.graphType, properties: ["value": .integer(3)])) }
        _ = try await f.graph.acknowledgeSyncBatch(batch.id, succeeded: Set(batch.items.map { $0.change.id }))
        let recreated = try await f.graph.prepareSyncBatch(maximumRecords: 100)
        #expect(recreated.items.first { $0.change.id == f.a }?.change.operation == .save)
        #expect(recreated.items.first { $0.change.id == f.a }?.record?.properties["value"] == .integer(3))
        try await f.graph.abandonSyncBatch(recreated.id); try await f.graph.close()
    }

    @Test func limitsRefuseWithoutAdvancingAndGraphsRemainIndependent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges(limits: .init(maximumPending: 1)) }
        #expect(try await state(f.graph) == nil)
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges(limits: .init(maximumChanges: 1)) }
        #expect(try await state(f.graph) == nil)
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges(limits: .init(maximumTransactions: 1)) }
        #expect(try await state(f.graph) == nil)
        #expect(try await f.graph.collectSyncChanges() == 2)
        let other = try await f.manager.createGraph(id: GraphID(), at: f.directory.appendingPathComponent("Other.sqlite"))
        #expect(try await other.collectSyncChanges() == 0)
        let batch = try await f.graph.prepareSyncBatch(maximumRecords: 1)
        #expect(batch.items.count == 1)
        await #expect(throws: GraphSyncError.self) { try await f.graph.prepareSyncBatch(maximumRecords: 1) }
        try await f.graph.abandonSyncBatch(batch.id)
        #expect(try await f.graph.collectSyncChanges() == 2)
        try await f.graph.close(); try await other.close()
    }

    @Test(arguments: ["bytes", "store", "token"]) func corruptStateIsNeverSilentlyReset(_ variant: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.graph.collectSyncChanges()
        let bytes: Data
        if variant == "bytes" { bytes = Data([0, 1]) }
        else {
            let original = try #require(try await state(f.graph))
            var data = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            if variant == "store" { data["storeID"] = "wrong" }
            else { data["token"] = Data([0, 1]).base64EncodedString() }
            bytes = try JSONSerialization.data(withJSONObject: data)
        }
        _ = try await state(f.graph, replacing: bytes)
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges() }
        #expect(try await state(f.graph) == bytes)
        try await f.graph.close()
    }

    @Test func expiredHistoryIsNotTreatedAsAnEmptySuccessfulScan() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await acknowledgeAll(f.graph)
        let before = try await state(f.graph)
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(2))])) }
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                _ = try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
            }
        }
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges() }
        #expect(try await state(f.graph) == before)
        try await f.graph.close()
    }

    @Test func unknownAuthorsAreVisibleAndDoNotAdvanceTheCheckpoint() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await acknowledgeAll(f.graph)
        let before = try await state(f.graph), target = f.a
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                context.userInfo[StoreNativeContext.privateURLKey] = container.persistentStoreCoordinator.persistentStores.first?.url
                context.transactionAuthor = "unsupported-writer"
                _ = try GraphNativeIdentityDatabaseAdapter.database.graph.patch(context, target.graphID,
                    GraphRecordPatch(id: target, properties: ["value": .set(.integer(3))]))
                try context.save()
            }
        }
        await #expect(throws: GraphSyncError.self) { try await f.graph.collectSyncChanges() }
        #expect(try await state(f.graph) == before)
        try await f.graph.close()
    }

    @Test func concurrentPrepareHasOnlyOneWinnerAndClosedHandlesCannotSync() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let winners = await withTaskGroup(of: GraphSyncBatch?.self) { group in
            for _ in 0..<8 { group.addTask { try? await f.graph.prepareSyncBatch(maximumRecords: 1) } }
            var result: [GraphSyncBatch] = []
            for await value in group { if let value { result.append(value) } }
            return result
        }
        #expect(winners.count == 1)
        let winner = try #require(winners.first)
        try await f.graph.abandonSyncBatch(winner.id)
        try await f.graph.close()
        await #expect(throws: GraphStoreError.self) { try await f.graph.collectSyncChanges() }
    }

    @Test(arguments: ["property-remove", "tag-remove", "group-remove", "tag-add", "group-add", "edge", "action", "file"])
    func realDetailAndTopologyChangesReachPreparedRecords(_ operation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let edge = f.graph.makeNodeID(), action = f.graph.makeNodeID()
        try await f.graph.transaction {
            try $0.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: f.a, object: f.b)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [f.a], objects: [f.b])))
        }
        let source = f.directory.appendingPathComponent("input.bin"); try Data([1, 2, 3]).write(to: source)
        let file = try await f.graph.importAttachment(from: source, ownedBy: f.a)
        try await acknowledgeAll(f.graph)
        let target: GraphNodeID
        if operation == "file" {
            try Data([4, 5]).write(to: source)
            _ = try await f.graph.replaceAttachment(file.id, from: source)
            target = file.id
        } else {
            let patch: GraphRecordPatch
            switch operation {
            case "property-remove":
                try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(2))])) }
                patch = try GraphRecordPatch(id: f.a, properties: ["value": .remove])
            case "tag-remove": patch = try GraphRecordPatch(id: f.a, removingTags: ["initial"])
            case "group-remove": patch = try GraphRecordPatch(id: f.a, removingGroups: ["initial"])
            case "tag-add": patch = try GraphRecordPatch(id: f.a, addingTags: ["added"])
            case "group-add": patch = try GraphRecordPatch(id: f.a, addingGroups: ["added"])
            case "edge": patch = try GraphRecordPatch(id: edge, endpoints: .relationship(subject: f.b, object: f.a))
            default: patch = try GraphRecordPatch(id: action, endpoints: .action(subjects: [f.b], objects: [f.a]))
            }
            target = patch.id
            try await f.graph.transaction { _ = try $0.patch(patch) }
        }
        let batch = try await f.graph.prepareSyncBatch(maximumRecords: 100)
        let changed = try #require(batch.items.first { $0.change.id == target })
        #expect(changed.change.operation == .save && changed.record?.id == target)
        if operation == "property-remove" { #expect(changed.record?.properties["value"] == nil) }
        try await f.graph.abandonSyncBatch(batch.id); try await f.graph.close()
    }

    @Test func failedMaterializationDoesNotPublishCheckpointOrDropPendingWork() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await acknowledgeAll(f.graph)
        let before = try await state(f.graph)
        try await f.graph.nativeOperation { container in
            try await container.performBackgroundTask { context in
                context.userInfo[StoreNativeContext.containerKey] = container
                context.transactionAuthor = GraphSyncCheckpointAdapter.localAuthor
                let facade = GraphTypedStoreAdapter.facade(context)
                let node = try #require(Search<Entity>(graph: facade).where(.type(ObservedItem.graphType)).sync().first)
                // The native Data archive remains valid; the application GraphValue envelope is invalid.
                node[dynamicMember: "value"] = Data([0, 1])
                try context.save()
            }
        }
        await #expect(throws: (any Error).self) { try await f.graph.prepareSyncBatch(maximumRecords: 10) }
        #expect(try await state(f.graph) == before)
        // Discovery inspects identity/ownership rather than decoding the application body.
        #expect(try await f.graph.collectSyncChanges() == 1)
        try await f.graph.close()
    }

    @Test func coordinatedStoreCannotStartNativeMirroringOrGrowAnotherGraph() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.graph.collectSyncChanges()
        try await f.graph.close()
        for paired in [false, true] {
            let absent = f.directory.appendingPathComponent("NeverCreated.sqlite")
            do {
                let unexpected = try await (paired
                    ? GraphDatabase.openMirrored(privateStoreAt: absent, sharedStoreAt: f.url, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
                    : GraphDatabase.openMirrored(at: f.url, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity))
                try await unexpected.close(); Issue.record("A coordinated store was admitted to native mirroring.")
            } catch GraphStoreError.persistence(underlying: let error) {
                guard let runtime = error as? StoreRuntimeError, case .invalidConfiguration = runtime else { throw error }
            }
            #expect(!FileManager.default.fileExists(atPath: absent.path))
        }
        let local = try await GraphDatabase.open(at: f.url, schema: .nativeIdentity)
        await #expect(throws: GraphStoreError.self) { try await local.createGraph() }
        #expect(try await local.graphIDs() == [f.graph.id]); try await local.close()
        let reader = try await GraphDatabase.openReadOnly(at: f.url, schema: .nativeIdentity)
        let graph = try await reader.openGraph(f.graph.id)
        #expect(try await graph.fetchAll(ObservedItem.self).count == 1)
        try await graph.close(); try await reader.close()
        let reopened = try await f.manager.openGraph(id: f.graph.id, at: f.url)
        #expect(try await reopened.collectSyncChanges() == 2); try await reopened.close()
    }

    @Test func unmarkedS03IsNotSilentlyActivatedAsACoordinatedStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnmarkedSync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Unmarked.sqlite")
        let db = try await GraphDatabase.open(at: url, schema: .nativeIdentity), graph = try await db.createGraph()
        let node = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "retained")) }
        try await graph.close(); try await db.close()
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        await #expect(throws: GraphSyncError.self) { try await manager.openGraph(id: graph.id, at: url) }
        let retained = try await GraphDatabase.open(at: url, schema: .nativeIdentity), data = try await retained.openGraph(graph.id)
        #expect(try await data.read { try $0.record(for: node)?.type } == "retained")
        try await data.close(); try await retained.close()
    }

    @Test func closeRetiresAnInFlightPreparationWithoutLosingItsPendingWork() async throws {
        struct Deadline: Error {}
        let ready = SyncTestSignal(), closing = SyncTestSignal(), proceed = DispatchSemaphore(value: 0)
        let base = GraphCoordinatorFactory.adapter, sync = try #require(base.sync)
        let delayed = GraphSyncAdapter(collect: sync.collect, prepare: { context, id, limits, count in
            let result: GraphSyncPrepared
            do { result = try sync.prepare(context, id, limits, count) }
            catch { Task { await ready.signal() }; throw error }
            Task { await ready.signal() }
            guard proceed.wait(timeout: .now() + 30) == .success else { throw Deadline() }
            return result
        }, acknowledge: sync.acknowledge, importPatches: sync.importPatches)
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: delayed, initialize: base.initialize)
        let f = try await fixture(adapter: adapter, registry: StoreRegistry(hooks: .init(didBeginClose: { await closing.signal() })))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let preparation = Task { try await f.graph.prepareSyncBatch(maximumRecords: 10) }
        await ready.wait()
        let close = Task { try await f.graph.close() }; await closing.wait()
        proceed.signal()
        await #expect(throws: GraphStoreError.self) { try await preparation.value }
        try await close.value
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: base)
        let reopened = try await manager.openGraph(id: f.graph.id, at: f.url)
        #expect(try await reopened.collectSyncChanges() == 2)
        try await reopened.close()
    }
}
