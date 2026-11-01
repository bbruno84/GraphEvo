import CoreData
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

@MainActor private func seedConversionSource(_ url: URL, empty: Bool = false, reserved: Bool = false, nullable: Bool = false) throws -> [String] {
    try autoreleasepool {
        let graph = Graph(storeURL: url, migrationEnabled: false)
        guard graph.isReady else { throw GraphV1ConversionError.unsupportedSource }
        var nodes = [Node]()
        if !empty {
            let a = Entity("Legacy.Invoice", graph: graph), b = Entity("Legacy.Category", graph: graph)
            a[dynamicMember: "amount"] = NSDecimalNumber(string: "12.34")
            a[dynamicMember: "name"] = "Retained"
            a[dynamicMember: "uuid"] = "00000000-0000-0000-0000-000000000123"
            if nullable { a[dynamicMember: "null"] = NSNull() }
            a[dynamicMember: "codableArchive"] = try GraphArchiver.archive(AnyCodableObject(["flag": AnyCodableObject(true), "bytes": AnyCodableObject(Data([4,5]))]))
            a[dynamicMember: "appDataVersion"] = 7
            a[dynamicMember: "nested"] = ["values": [1, true, "text"]]
            a[dynamicMember: "binary"] = Data(repeating: 91, count: 2 * 1024 * 1024)
            a[dynamicMember: "url"] = URL(string: "https://example.test/retained")!
            a[dynamicMember: "date"] = Date(timeIntervalSince1970: 5678)
            if reserved { a[dynamicMember: "__graphevo_v2.claim"] = "not-library-metadata" }
            try a.runtimeSetPropertyVersions(["name": 9])
            a.add(tags: "retained"); a.add(to: "invoices")
            a.setCreatedDate(Date(timeIntervalSince1970: 1234)); b.setImportedCreatedDate(nil)
            let edge = a.is(relationship: "categorized").of(b)
            let action = a.will(action: "review").add(objects: b)
            let optional = Relationship("optional", graph: graph)
            nodes = [a,b,edge,action,optional]
        }
        var failure: Error?
        graph.sync { if !$0 { failure = $1 } }; if let failure { throw failure }
        let ids = nodes.map(\.id)
        let container = try #require(graph.persistentContainer)
        graph.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        return ids
    }
}

private final class V1ConversionFailure: @unchecked Sendable {
    private let lock = NSLock(); private var armed = true
    func failOnce() throws { if lock.withLock({ let value = armed; armed = false; return value }) { throw GraphV1ConversionError.invalidReceipt } }
}
private final class V1ConversionGate: @unchecked Sendable {
    let arrivals = AsyncStream<Void>.makeStream()
    private let lock = NSLock(); private var armed = true
    private let semaphore = DispatchSemaphore(value: 0)
    func block() {
        guard lock.withLock({ let value = armed; armed = false; return value }) else { return }
        arrivals.continuation.yield(())
        _ = semaphore.wait(timeout: .now() + 10)
    }
    func release() { semaphore.signal() }
}

@Suite(.timeLimit(.minutes(2))) struct GraphV1ConversionTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V1Conversion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func manager(registry: StoreRegistry = StoreRegistry(), adapter: GraphCoordinatorAdapter = GraphCoordinatorFactory.adapter) -> GraphContextManager {
        .init(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
    }
    @Test func convertsCompleteLegacyGraphIntoS03WithVerifiedPortableBackupAndFreshHistory() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        let old = try await seedConversionSource(source), id = GraphID(), operation = UUID(), m = manager()
        let originalBytes = Data(SHA256.hash(data: try Data(contentsOf: source)))
        let result = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups"))
        #expect(!result.cleanupPending && result.receipt.nodeIDs.count == 5)
        #expect(Data(SHA256.hash(data: try Data(contentsOf: source))) == originalBytes)
        #expect(result.receipt.intent.sourceStoreID != result.receipt.targetStoreID)
        let graph = try await m.openGraph(id: id, at: target)
        let a = try #require(result.receipt.nodeIDs[old[0]]), b = try #require(result.receipt.nodeIDs[old[1]])
        let record = try #require(try await graph.read { try $0.record(for: a) })
        #expect(record.properties["name"] == .string("Retained"))
        #expect(record.properties["amount"] == .decimal(Decimal(string: "12.34")!))
        #expect(record.properties["uuid"] == .string("00000000-0000-0000-0000-000000000123"))
        #expect(record.properties["appDataVersion"] == .integer(7))
        guard case .data(let archive) = record.properties["codableArchive"] else { throw GraphV1ConversionError.invalidReceipt }
        let restoredWrapper = try #require(GraphArchiver.unarchive(archive) as? AnyCodableObject)
        let wrapped = try #require(restoredWrapper.value as? [String: AnyCodableObject])
        #expect(wrapped["flag"]?.value as? Bool == true && wrapped["bytes"]?.value as? Data == Data([4,5]))
        #expect(record.properties["binary"] == .data(Data(repeating: 91, count: 2 * 1024 * 1024)))
        #expect(record.tags == ["retained"] && record.groups == ["invoices"] && record.createdDate == Date(timeIntervalSince1970: 1234))
        #expect(try await graph.read { try $0.record(for: b)?.createdDate } == nil)
        let records = try await graph.read { scope in try result.receipt.nodeIDs.values.compactMap { try scope.record(for: $0) } }
        #expect(records.contains { $0.endpoints == .relationship(subject: a, object: b) })
        #expect(records.contains { $0.endpoints == .action(subjects: [a], objects: [b]) })
        #expect(records.contains { $0.type == "optional" && $0.endpoints == .relationship(subject: nil, object: nil) })
        #expect(try await graph.read { try $0.attachments(ownedBy: a).isEmpty })
        let legacyVersion = try await graph.read { try $0.withContext { context, _ in
            try GraphTypedStoreAdapter.Session(context, id, database: true).node(a)?.runtimePropertyVersions["name"]
        } }
        #expect(legacyVersion == 9)
        #expect(try await graph.collectSyncChanges() == 5)
        let batch = try await graph.prepareSyncBatch(maximumRecords: 100)
        #expect(Set(batch.items.map { $0.change.id }) == Set(result.receipt.nodeIDs.values))
        let backup = try await m.backups.verify(at: result.backupURL)
        #expect(backup.manifest.schemaIdentifier == GraphRuntimeSchema.current.identifier)
        let restored = try await m.backups.restore(at: result.backupURL, to: root.appendingPathComponent("Restored"))
        try await graph.close()
        try await MainActor.run {
            for url in [source, restored.storeURL] {
                let legacy = Graph(storeURL: url, migrationEnabled: false)
                #expect(legacy.isReady)
                let invoice = Search<Entity>(graph: legacy).where(.type("Legacy.Invoice")).sync().first
                #expect(invoice?.id == old[0])
                #expect(invoice?[dynamicMember: "binary"] as? Data == Data(repeating: 91, count: 2 * 1024 * 1024))
                let container = try #require(legacy.persistentContainer)
                legacy.managedObjectContext.reset()
                for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
                try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
            }
        }
        try FileManager.default.removeItem(at: root)
    }
    @Test func repeatedConversionRecoversStableIDsAndPreservesLaterV2Edits() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        let old = try await seedConversionSource(source), id = GraphID(), operation = UUID(), m = manager()
        let first = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups"))
        let graph = try await m.openGraph(id: id, at: target), a = try #require(first.receipt.nodeIDs[old[0]])
        _ = try await graph.transaction { try $0.patch(.init(id: a, properties: ["name": .set(.string("Later"))])) }
        try await graph.close()
        let restarted = manager()
        let retry = try await restarted.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups"))
        #expect(retry.receipt == first.receipt)
        #expect(try await restarted.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        let reopened = try await restarted.openGraph(id: id, at: target)
        #expect(try await reopened.read { try $0.record(for: a)?.properties["name"] } == .string("Later"))
        try await reopened.close(); try FileManager.default.removeItem(at: root)
    }
    @Test(arguments: ["records", "rows", "payload", "reserved", "backup"])
    func refusesInvalidSourceOrBudgetWithoutOpeningDestination(mode: String) async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source, reserved: mode == "reserved")
        let backups = root.appendingPathComponent("Backups")
        if mode == "backup" { try Data([1]).write(to: backups) }
        let limits = GraphV1ConversionLimits(maximumRecords: mode == "records" ? 1 : 10_000,
            maximumNativeRows: mode == "rows" ? 1 : 100_000, maximumPayloadBytes: mode == "payload" ? 1 : 32 * 1024 * 1024)
        await #expect(throws: (any Error).self) {
            try await self.manager().convertLocalV1Store(at: source, to: target, graphID: GraphID(), operationID: UUID(), backupsIn: backups, limits: limits)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        if mode != "backup" { #expect(!FileManager.default.fileExists(atPath: backups.path)) }
        try FileManager.default.removeItem(at: root)
    }
    @Test func existingGraphAndWrongOperationAreNotOverwritten() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source)
        let m = manager(), id = GraphID(), graph = try await m.createGraph(id: id, at: target)
        let record = try GraphRecord(id: graph.makeNodeID(), type: "Existing")
        _ = try await graph.transaction { try $0.insert(record) }
        let before = try await graph.read { try $0.record(for: record.id) }
        try await graph.close()
        await #expect(throws: (any Error).self) { try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: UUID(), backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).isEmpty)
        let reopened = try await m.openGraph(id: id, at: target)
        #expect(try await reopened.read { try $0.record(for: record.id) } == before)
        try await reopened.close(); try FileManager.default.removeItem(at: root)
    }
    @Test func emptyLegacyStoreConvertsWithoutInventingApplicationRecords() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source, empty: true)
        let m = manager(), id = GraphID()
        let result = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: UUID(), backupsIn: root.appendingPathComponent("Backups"))
        #expect(result.receipt.nodeIDs.isEmpty)
        let graph = try await m.openGraph(id: id, at: target)
        #expect(try await graph.collectSyncChanges() == 0)
        try await graph.close(); try FileManager.default.removeItem(at: root)
    }
    private func faultAdapter(_ failure: @escaping @Sendable () throws -> Void) -> GraphCoordinatorAdapter {
        let base = GraphCoordinatorFactory.adapter, conversion = base.v1Conversion!
        let replacement = GraphV1ConversionAdapter(sourceSchema: conversion.sourceSchema, targetSchemaIdentifier: conversion.targetSchemaIdentifier,
            snapshot: conversion.snapshot, receipt: conversion.receipt, apply: { context, intent, snapshot in
                let result = try conversion.apply(context, intent, snapshot); try failure(); return result
            })
        return .init(graph: base.graph, sync: base.sync, v1Conversion: replacement, migrationSource: replacement.migrationSource, initializePolicy: base.initializePolicy,
            publication: base.publication, workspace: base.workspace, prepareWorkspace: base.prepareWorkspace,
            validateBackup: base.validateBackup, initialize: base.initialize)
    }
    @Test func failedSaveRollsBackUnpublishedTargetAndReusesPinnedBackup() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source)
        let failure = V1ConversionFailure(), m = manager(adapter: faultAdapter { try failure.failOnce() }), id = GraphID(), operation = UUID()
        let backups = root.appendingPathComponent("Backups")
        await #expect(throws: (any Error).self) { try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: backups) }
        let backup = try #require(try await m.backups.list(in: backups).first)
        #expect(try await m.backups.retentionOwners(at: backup.url).contains(operation))
        await #expect(throws: (any Error).self) { try await m.openGraph(id: id, at: target) }
        let retry = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: backups)
        #expect(retry.receipt.intent.operationID == operation)
        #expect(try await m.backups.list(in: backups).count == 1)
        #expect(try await m.backups.retentionOwners(at: backup.url).isEmpty)
        let graph = try await m.openGraph(id: id, at: target); try await graph.close()
        try FileManager.default.removeItem(at: root)
    }
    @Test(arguments: [false, true]) func cancellationBeforeOrAfterCommitHasTruthfulOutcome(afterCommit: Bool) async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source)
        let gate = V1ConversionGate(), id = GraphID(), operation = UUID(), backups = root.appendingPathComponent("Backups")
        let registry: StoreRegistry
        if afterCommit { registry = StoreRegistry(hooks: .init(afterCommit: { gate.block() })) }
        else { registry = StoreRegistry() }
        let m = manager(registry: registry, adapter: afterCommit ? GraphCoordinatorFactory.adapter : faultAdapter { gate.block() })
        let task = Task { try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: backups) }
        for await _ in gate.arrivals.stream { break }
        task.cancel(); gate.release()
        if afterCommit {
            let result = try await task.value
            #expect(result.receipt.nodeIDs.count == 5)
        } else { await #expect(throws: CancellationError.self) { try await task.value } }
        let recovered = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: backups)
        #expect(recovered.receipt.nodeIDs.count == 5 && !recovered.cleanupPending)
        #expect(try await m.backups.list(in: backups).count == 1)
        try FileManager.default.removeItem(at: root)
    }
    @Test func legacyReadOnlyAdmissionCannotBeUsedForWritesOrMixedWithNormalReaders() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite")
        _ = try await seedConversionSource(source)
        let registry = StoreRegistry(), handle = try await registry.open(.init(location: .sqlite(source), access: .readOnly, legacyReadOnly: true), schema: GraphRuntimeSchema.current)
        await #expect(throws: StoreRuntimeError.self) { try await handle.transaction { _ in } }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(.init(location: .sqlite(source), access: .readOnly), schema: GraphRuntimeSchema.current) }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(.init(location: .sqlite(source), legacyReadOnly: true), schema: GraphRuntimeSchema.current) }
        try await handle.close(); try FileManager.default.removeItem(at: root)
    }
    @Test func nullIsPreservedOrRefusedButNeverDroppedAndWrappedValuesRemainOpaque() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        let old = try await seedConversionSource(source, nullable: true), m = manager(), id = GraphID()
        do {
            let result = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: UUID(), backupsIn: root.appendingPathComponent("Backups"))
            let graph = try await m.openGraph(id: id, at: target), a = try #require(result.receipt.nodeIDs[old[0]])
            #expect(try await graph.read { try $0.record(for: a)?.properties["null"] } == .null)
            try await graph.close()
        } catch GraphV1ConversionError.unsupportedSource { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        catch GraphModelError.unsupportedLegacyValue(let key) { #expect(key == "null" && !FileManager.default.fileExists(atPath: target.path)) }
        let wrappers: [Any] = [AnyCodableObject(["flag": AnyCodableObject(true)]),
            NSArrayOfAnyCodableObject([AnyCodableObject(Date(timeIntervalSince1970: 4321))]),
            DictionaryOfAnyCodableObject(["bytes": AnyCodableObject(Data([4,5]))])]
        for wrapper in wrappers {
            guard case .encoded(let encoded) = try GraphV1NativeConversion.valueFromLegacy(wrapper, key: "wrapped") else { throw GraphV1ConversionError.invalidReceipt }
            #expect(encoded.codec == GraphV1NativeConversion.legacyArchiveCodec)
            #expect(try GraphV1NativeConversion.valueFromLegacy(GraphArchiver.unarchive(encoded.data), key: "wrapped", canonical: true) == GraphV1NativeConversion.valueFromLegacy(wrapper, key: "wrapped", canonical: true))
        }
        try FileManager.default.removeItem(at: root)
    }

    @Test func sameVolumeRelocationRecoversReceiptWithoutPersistedURLsOrAnotherBackup() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source)
        let id = GraphID(), operation = UUID(), m = manager()
        let first = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups"))
        let data = try JSONEncoder().encode(first.receipt)
        #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
        let moved = root.deletingLastPathComponent().appendingPathComponent("Moved-" + UUID().uuidString)
        try FileManager.default.moveItem(at: root, to: moved)
        let recovered = try await manager().convertLocalV1Store(at: moved.appendingPathComponent("Legacy.sqlite"), to: moved.appendingPathComponent("V2.sqlite"),
            graphID: id, operationID: operation, backupsIn: moved.appendingPathComponent("Backups"))
        #expect(recovered.receipt == first.receipt && recovered.backupURL != first.backupURL && !recovered.cleanupPending)
        try FileManager.default.removeItem(at: moved)
    }
    @Test @MainActor func activeV1OwnerIsRefusedBeforeAnyBackupOrDestination() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        let legacy = Graph(storeURL: source, migrationEnabled: false)
        #expect(legacy.isReady)
        let entity = Entity("Retained", graph: legacy); legacy.sync()
        await #expect(throws: (any Error).self) { try await self.manager().convertLocalV1Store(at: source, to: target, graphID: GraphID(), operationID: UUID(), backupsIn: root.appendingPathComponent("Backups")) }
        #expect(!FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
        #expect(Search<Entity>(graph: legacy).where(.type("Retained")).sync().first?.id == entity.id)
        let container = try #require(legacy.persistentContainer); legacy.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        try FileManager.default.removeItem(at: root)
    }
    @Test func differentOperationOrChangedSourceCannotOverwriteCompletedConversion() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        let old = try await seedConversionSource(source)
        let id = GraphID(), operation = UUID(), m = manager()
        let first = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups"))
        await #expect(throws: GraphV1ConversionError.self) { try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: UUID(), backupsIn: root.appendingPathComponent("Backups")) }
        try await MainActor.run {
            let legacy = Graph(storeURL: source, migrationEnabled: false)
            let node = try #require(Search<Entity>(graph: legacy).where(.type("Legacy.Invoice")).sync().first)
            node[dynamicMember: "name"] = "Changed source"; legacy.sync()
            let container = try #require(legacy.persistentContainer); legacy.managedObjectContext.reset()
            for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
            try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        }
        await #expect(throws: GraphV1ConversionError.self) { try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: operation, backupsIn: root.appendingPathComponent("Backups")) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Backups")).count == 1)
        let graph = try await m.openGraph(id: id, at: target), invoice = try #require(first.receipt.nodeIDs[old[0]])
        #expect(try await graph.read { try $0.record(for: invoice)?.properties["name"] } == .string("Retained"))
        try await graph.close(); try FileManager.default.removeItem(at: root)
    }

    @Test func committedConversionReportsCleanupFailureAndKeepsNativeOwnershipReserved() async throws {
        let root = try root(), source = root.appendingPathComponent("Legacy.sqlite"), target = root.appendingPathComponent("V2.sqlite")
        _ = try await seedConversionSource(source)
        let failure = V1ConversionFailure(), registry = StoreRegistry(hooks: .init(beforeDetach: { try failure.failOnce() }))
        let m = manager(registry: registry), id = GraphID()
        let result = try await m.convertLocalV1Store(at: source, to: target, graphID: id, operationID: UUID(), backupsIn: root.appendingPathComponent("Backups"))
        #expect(result.receipt.nodeIDs.count == 5 && result.cleanupPending && result.cleanupFailure != nil)
        await #expect(throws: (any Error).self) { try await m.openGraph(id: id, at: target) }
        let other = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Independent.sqlite"))
        try await other.close()
        // Keep the quarantined target/files: failed detachment must never authorize deletion or a new owner.
    }

}
