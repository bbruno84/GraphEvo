import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite struct StoreProcessRoleTests {
    @Test func classifiesExtensionBundlesAndMetadataWithoutAppNameHeuristics() {
        #expect(StoreProcessRole.classify(bundleURL: URL(fileURLWithPath: "/Apps/Main.app"), hasExtensionConfiguration: false) == .application)
        #expect(StoreProcessRole.classify(bundleURL: URL(fileURLWithPath: "/Apps/Widget.APPEX"), hasExtensionConfiguration: false) == .appExtension)
        #expect(StoreProcessRole.classify(bundleURL: URL(fileURLWithPath: "/Apps/Service.bundle"), hasExtensionConfiguration: true) == .appExtension)
    }

    @Test func extensionMirroringRefusesBeforeReservationModelFactoryOrFileCreation() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let primary = folder.appendingPathComponent("NotCreated/private.sqlite")
        let shared = folder.appendingPathComponent("NotCreated/shared.sqlite")
        let source = fixtureSchema()
        let schema = StoreSchema(identifier: source.identifier, entityVersionHashes: source.entityVersionHashes) {
            Issue.record("Extension mirroring must be refused before constructing a native model.")
            return fixtureModel()
        }
        let registry = StoreRegistry(hooks: .init(processRole: .appExtension, beforeLoad: {
            Issue.record("Extension mirroring must be refused before native loading.")
        }))
        for secondary in [nil, shared] {
            await #expect {
                try await registry.open(.init(location: .sqlite(primary), cloudKitContainerIdentifier: "iCloud.invalid",
                                               sharedStoreURL: secondary), schema: schema)
            } throws: { error in
                if case StoreRuntimeError.synchronizationUnavailableInExtension = error { return true }
                return false
            }
        }
        #expect(!FileManager.default.fileExists(atPath: primary.deletingLastPathComponent().path))
        // Refusal must leave no gateway claim behind.
        let independent = StoreRegistry()
        let handle = try await independent.open(.init(location: .sqlite(primary)), schema: fixtureSchema())
        try await handle.close()
    }

    @Test func extensionAllowsExistingLocalReadOnlyResources() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Main.sqlite")
        let writer = try await StoreRegistry().open(.init(location: .sqlite(url)), schema: fixtureSchema())
        try await writer.close()
        let registry = StoreRegistry(hooks: .init(processRole: .appExtension))
        let reader = try await registry.open(.init(location: .sqlite(url), access: .readOnly), schema: fixtureSchema())
        #expect(try await reader.snapshot().access == .readOnly)
        try await reader.close()
    }
}
