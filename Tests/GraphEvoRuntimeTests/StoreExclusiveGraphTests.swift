import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreExclusiveGraphTests {
    @Test func exclusiveOwnershipCannotCoalesceWithGenericOrOtherGraphRequests() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("A.sqlite"), id = UUID(), registry = StoreRegistry()
        let exclusive = StoreConfiguration(location: .sqlite(url), exclusiveGraphID: id)
        let owner = try await registry.open(exclusive, schema: fixtureSchema())
        let sibling = try await registry.open(exclusive, schema: fixtureSchema())
        #expect(try await owner.snapshot().runtimeID == sibling.snapshot().runtimeID)
        for configuration in [StoreConfiguration(location: .sqlite(url)),
                              StoreConfiguration(location: .sqlite(url), exclusiveGraphID: UUID())] {
            await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: fixtureSchema()) }
        }
        try await owner.close(); try await sibling.close()
        let generic = try await registry.open(.init(location: .sqlite(url)), schema: fixtureSchema())
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(exclusive, schema: fixtureSchema()) }
        try await generic.close()
    }

    @Test func canonicalResolutionRetainsExclusiveIdentityAcrossAliases() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), url = directory.appendingPathComponent("A.sqlite"), registry = StoreRegistry()
        let owner = try await registry.open(.init(location: .sqlite(url), exclusiveGraphID: id), schema: fixtureSchema())
        let alias = directory.appendingPathComponent("Alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let direct = try StoreRegistry.resolve(.init(location: .sqlite(url), exclusiveGraphID: id))
        let resolved = try StoreRegistry.resolve(.init(location: .sqlite(alias), exclusiveGraphID: id))
        #expect(resolved.key == direct.key)
        #expect(resolved.configuration.exclusiveGraphID == id)
        let sibling = try await registry.open(resolved.configuration, schema: fixtureSchema())
        #expect(try await owner.snapshot().runtimeID == sibling.snapshot().runtimeID)
        try await owner.close(); try await sibling.close()
    }

    @Test func exclusiveGraphsRejectMirrorsPairsMemoryAndReadOnlyBeforeCreatingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("A.sqlite"), id = UUID()
        for configuration in [StoreConfiguration(location: .sqlite(url), access: .readOnly, exclusiveGraphID: id),
                              StoreConfiguration(location: .sqlite(url), cloudKitContainerIdentifier: "iCloud.invalid", exclusiveGraphID: id),
                              StoreConfiguration(location: .sqlite(url), sharedStoreURL: directory.appendingPathComponent("Shared.sqlite"), exclusiveGraphID: id),
                              StoreConfiguration(location: .inMemory(UUID()), exclusiveGraphID: id)] {
            #expect(throws: StoreRuntimeError.self) { try StoreRegistry.resolve(configuration) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
