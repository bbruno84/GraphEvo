import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreResourceGroupTests {
    @Test func pairedFilesShareOneOwnerAndExcludeEveryOverlappingGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let config = StoreConfiguration(location: .sqlite(primary), sharedStoreURL: shared)
        let registry = StoreRegistry()
        let a = try await registry.open(config, schema: fixtureSchema())
        let b = try await registry.open(config, schema: fixtureSchema())
        #expect(try await a.snapshot().runtimeID == b.snapshot().runtimeID)
        #expect(try await a.read { $0.persistentStoreCoordinator?.persistentStores.count } == 2)
        for request in [StoreConfiguration(location: .sqlite(shared)),
                        StoreConfiguration(location: .sqlite(shared), sharedStoreURL: primary),
                        StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Other.sqlite")), sharedStoreURL: shared)] {
            await #expect(throws: StoreRuntimeError.self) { try await registry.open(request, schema: fixtureSchema()) }
        }
        let independentRegistry = StoreRegistry()
        await #expect(throws: StoreRuntimeError.self) {
            try await independentRegistry.open(.init(location: .sqlite(shared)), schema: fixtureSchema())
        }
        try await a.close()
        #expect(try await b.read { $0.persistentStoreCoordinator?.persistentStores.count } == 2)
        try await b.close()
        let independent = try await independentRegistry.open(.init(location: .sqlite(shared)), schema: fixtureSchema())
        try await independent.close()
    }

    @Test func sharedFileReplacementAndTopologyChangesAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let config = StoreConfiguration(location: .sqlite(primary), sharedStoreURL: shared)
        let registry = StoreRegistry()
        let handle = try await registry.open(config, schema: fixtureSchema())
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(.init(location: .sqlite(primary)), schema: fixtureSchema())
        }
        try FileManager.default.moveItem(at: shared, to: directory.appendingPathComponent("Retained.sqlite"))
        try Data("replacement".utf8).write(to: shared)
        await #expect { try await handle.snapshot() } throws: { error in
            if case StoreRuntimeError.storeReplaced = error { return true }; return false
        }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(config, schema: fixtureSchema()) }
        try await handle.close()
        #expect(try Data(contentsOf: shared) == Data("replacement".utf8))
    }

    @Test func secondaryAliasesCoalesceAndOneFileCannotHaveBothRoles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let alias = directory.appendingPathComponent("Alias.sqlite")
        let registry = StoreRegistry()
        let a = try await registry.open(.init(location: .sqlite(primary), sharedStoreURL: shared), schema: fixtureSchema())
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        let b = try await registry.open(.init(location: .sqlite(primary), sharedStoreURL: alias), schema: fixtureSchema())
        #expect(try await a.snapshot().runtimeID == b.snapshot().runtimeID)
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(.init(location: .sqlite(primary), sharedStoreURL: primary), schema: fixtureSchema())
        }
        try await a.close(); try await b.close()
    }

    @Test func aLoadFailureDetachesAllLoadedStoresAndReleasesBothClaims() async throws {
        struct LoadFailure: Error {}
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(didLoadStore: { url in
            if url == shared { throw LoadFailure() }
        }))
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(.init(location: .sqlite(primary), sharedStoreURL: shared), schema: fixtureSchema())
        }
        let next = StoreRegistry()
        let a = try await next.open(.init(location: .sqlite(primary)), schema: fixtureSchema())
        let b = try await next.open(.init(location: .sqlite(shared)), schema: fixtureSchema())
        try await a.close(); try await b.close()
    }

    @Test func failedLoadCleanupQuarantinesBothNativeResources() async throws {
        struct InjectedFailure: Error {}
        // Quarantine intentionally retains its native files until process exit; do not delete open stores.
        let directory = try temporaryDirectory()
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { throw InjectedFailure() }, didLoadStore: { _ in throw InjectedFailure() }))
        let config = StoreConfiguration(location: .sqlite(primary), sharedStoreURL: shared)
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(config, schema: fixtureSchema()) }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(config, schema: fixtureSchema()) }
        let independent = StoreRegistry()
        for url in [primary, shared] {
            await #expect(throws: StoreRuntimeError.self) { try await independent.open(.init(location: .sqlite(url)), schema: fixtureSchema()) }
        }
    }
    @Test func replacingTheSharedPathWithASymlinkDoesNotChangeTheOwnedResourceKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Private.sqlite"), shared = directory.appendingPathComponent("Shared.sqlite")
        let alternate = directory.appendingPathComponent("Alternate.sqlite")
        let config = StoreConfiguration(location: .sqlite(primary), sharedStoreURL: shared)
        let registry = StoreRegistry()
        let handle = try await registry.open(config, schema: fixtureSchema())
        try FileManager.default.moveItem(at: shared, to: alternate)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: alternate)
        await #expect(throws: StoreRuntimeError.self) { try await handle.snapshot() }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(config, schema: fixtureSchema()) }
        try await handle.close()
    }

}
