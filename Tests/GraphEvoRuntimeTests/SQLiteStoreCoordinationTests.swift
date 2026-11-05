import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct SQLiteStoreCoordinationTests {
    @Test func aliasesConvergeAndIndependentStoresUseDifferentGrants() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let first = try ResolvedStore(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))))
        let same = try ResolvedStore(.init(location: .sqlite(alias.appendingPathComponent("Store.sqlite"))))
        let other = try ResolvedStore(.init(location: .sqlite(root.appendingPathComponent("Other.sqlite"))))
        let anchor = try SQLiteStoreCoordination.directory(first)
        #expect(try SQLiteStoreCoordination.directory(same) == anchor)
        #expect(try SQLiteStoreCoordination.directory(other) != anchor)
        let gate = DispatchSemaphore(value: 0), events = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await CoordinatedFiles.run([.write(anchor)]) {
                events.continuation.yield(())
                guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
            }
        }
        defer { gate.signal() }
        var signals = events.stream.makeAsyncIterator()
        _ = await signals.next()
        let registry = StoreRegistry(hooks: .init(didSubmitSQLiteAccess: { events.continuation.yield(()) }))
        let waiting = Task { try await registry.open(first.configuration, schema: fixtureSchema()) }
        _ = await signals.next()
        #expect(try first.fileIdentity() == nil)
        let independent = try await StoreRegistry().open(other.configuration, schema: fixtureSchema())
        try await independent.close()
        waiting.cancel()
        gate.signal()
        try await holder.value
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func workspaceRequiresExactOfflineRecoveryBeforeReopening() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Workspace.sqlite")
        let graphID = UUID()
        let workspaceID = UUID()
        let configuration = StoreConfiguration(location: .sqlite(url), exclusiveGraphID: graphID,
            workspaceID: workspaceID, workspaceSessionID: UUID())
        let resolved = try ResolvedStore(configuration)
        let registry = StoreRegistry()
        let seed = root.appendingPathComponent("Seed.sqlite")
        let source = try await registry.open(.init(location: .sqlite(seed)), schema: fixtureSchema())
        try await source.close()
        let migration = StoreNativeMigration(sourceSchema: fixtureSchema(), seedURL: seed, document: Data([1]),
                                             configure: { _, _ in }, finish: { _ in })
        let workspace = try await registry.open(configuration, schema: fixtureSchema(), nativeMigration: migration)
        let storeID = try await workspace.nativeOperation { container in
            try container.testNativeContext { context in
                let coordinator = try #require(context.persistentStoreCoordinator)
                let store = try #require(coordinator.persistentStores.first)
                var metadata = coordinator.metadata(for: store)
                metadata[StoreNativeContext.historySyncGraphKey] = graphID.uuidString
                metadata[StoreNativeContext.workspaceKey] = workspaceID.uuidString
                coordinator.setMetadata(metadata, for: store)
                NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue("kept", forKey: "value")
                try context.save()
                return try #require(metadata[NSStoreUUIDKey] as? String)
            }
        }
        let anchor = try SQLiteStoreCoordination.directory(resolved)
        let claims = anchor.appendingPathComponent(".owners-v1")
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: claims.path).first)
        let generation = try #require(UUID(uuidString: name))
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreRegistry.recoverOfflineWorkspace(configuration, generation: generation, storeID: storeID) {}
        }
        try await workspace.close()
        let abandoned = UUID()
        try await CoordinatedFiles.run([.write(anchor)]) {
            try AppGroupOwnerClaims.publish(abandoned, for: resolved, creating: false)
        }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: fixtureSchema()) }
        await #expect(throws: StoreRuntimeError.self) {
            try await StoreRegistry.recoverOfflineWorkspace(configuration, generation: generation, storeID: storeID) {}
        }
        try await StoreRegistry.recoverOfflineWorkspace(configuration, generation: abandoned, storeID: storeID) {}
        let reopened = try await registry.open(configuration, schema: fixtureSchema())
        #expect(try await reopened.read { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RuntimeFixture")) } == 1)
        try await reopened.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: claims.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".lock") })
    }

    @Test func unmarkedReadOnlyArchiveDoesNotCreateACoordinationDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.sqlite")
        let source = try await StoreRegistry().open(.init(location: .sqlite(sourceURL)), schema: fixtureSchema())
        try await source.close()
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let url = archive.appendingPathComponent("ReadOnly.sqlite")
        try FileManager.default.copyItem(at: sourceURL, to: url)
        let reader = try await StoreRegistry().open(.init(location: .sqlite(url), access: .readOnly), schema: fixtureSchema())
        try await reader.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).allSatisfy { !$0.hasPrefix(".graphevo-") })
    }
}
