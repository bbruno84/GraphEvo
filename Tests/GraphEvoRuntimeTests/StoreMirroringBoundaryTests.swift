import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreMirroringBoundaryTests {
    @Test func localOwnerHasNoNativeMirrorOrCloudSetup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = StoreRegistry()
        let handle = try await registry.open(.init(location: .sqlite(directory.appendingPathComponent("Local.sqlite"))),
                                             schema: fixtureSchema())
        let local = try await handle.nativeOperation { container in
            !(container is NSPersistentCloudKitContainer) &&
                container.persistentStoreDescriptions.count == 1 &&
                container.persistentStoreDescriptions.allSatisfy { $0.cloudKitContainerOptions == nil }
        }
        #expect(local)
        let setup = try await handle.cloudSetup()
        #expect(!setup.configured)
        #expect(setup.storeCount == 1)
        #expect(setup.readyStoreCount == 0)
        #expect(setup.latestFailureDomain == nil)
        #expect(setup.latestFailureCode == nil)
        try await handle.close()
    }

    @Test func invalidNativeMirrorIsRefusedBeforeConfiguringDescriptions() throws {
        let url = URL(fileURLWithPath: "/unused/Local.sqlite")
        for configuration in [StoreConfiguration(location: .sqlite(url)),
                              StoreConfiguration(location: .sqlite(url), cloudKitContainerIdentifier: " \n"),
                              StoreConfiguration(location: .sqlite(url), access: .readOnly, cloudKitContainerIdentifier: "iCloud.invalid"),
                              StoreConfiguration(location: .inMemory(UUID()), cloudKitContainerIdentifier: "iCloud.invalid")] {
            let description = NSPersistentStoreDescription(url: url)
            #expect(throws: StoreRuntimeError.self) {
                try LegacyStoreMirroring.makeContainer(name: "Rejected", model: fixtureModel(),
                    descriptions: [description], configuration: configuration)
            }
            #expect(description.cloudKitContainerOptions == nil)
        }
    }
}
