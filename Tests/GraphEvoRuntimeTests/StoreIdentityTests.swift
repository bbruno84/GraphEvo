import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite struct StoreIdentityTests {
    @Test func caseAliasesAreCoordinatedBeforeTheFileExists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sensitive = try #require(directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames as Bool?)
        let loading = LifecycleGate(), reserved = LifecycleGate()
        await reserved.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await loading.enter() },
                                                              didReserveHandle: { await reserved.enter() }))
        let schema = graphSchema()
        let first = Task { try await registry.open(StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Main.sqlite"))), schema: schema) }
        let second = Task { try await registry.open(StoreConfiguration(location: .sqlite(directory.appendingPathComponent("MAIN.SQLITE"))), schema: schema) }
        await reserved.waitForArrivals(2)
        await loading.release()
        let a = try await first.value, b = try await second.value
        #expect((try await a.snapshot().runtimeID == b.snapshot().runtimeID) == !sensitive)
        #expect(await loading.count() == (sensitive ? 2 : 1))
        try await a.close()
        try await b.close()
    }

    @Test func danglingFileAndDirectorySymlinksAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let danglingFile = directory.appendingPathComponent("Link.sqlite")
        let missing = directory.appendingPathComponent("Absent.sqlite")
        try FileManager.default.createSymbolicLink(at: danglingFile, withDestinationURL: missing)
        let danglingDirectory = directory.appendingPathComponent("LinkDirectory")
        try FileManager.default.createSymbolicLink(at: danglingDirectory, withDestinationURL: directory.appendingPathComponent("AbsentDirectory"))
        let registry = StoreRegistry()
        for url in [danglingFile, danglingDirectory.appendingPathComponent("Main.sqlite")] {
            await #expect { try await registry.open(StoreConfiguration(location: .sqlite(url)), schema: graphSchema()) } throws: { error in
                if case StoreRuntimeError.unsupportedFileAlias = error { return true }
                return false
            }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func directorySymlinkAndMissingAncestorsResolveToOneOwner() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let registry = StoreRegistry()
        let schema = graphSchema()
        let first = try await registry.open(StoreConfiguration(location: .sqlite(alias.appendingPathComponent("new/sub/Main.sqlite"))), schema: schema)
        let second = try await registry.open(StoreConfiguration(location: .sqlite(actual.appendingPathComponent("new/sub/Main.sqlite"))), schema: schema)
        #expect(try await first.snapshot().runtimeID == second.snapshot().runtimeID)
        try await first.close()
        try await second.close()
    }

    @Test func existingFileSymlinkSharesTheOriginalOwner() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Main.sqlite")
        let alias = directory.appendingPathComponent("Alias.sqlite")
        let registry = StoreRegistry()
        let first = try await registry.open(StoreConfiguration(location: .sqlite(original)), schema: graphSchema())
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let second = try await registry.open(StoreConfiguration(location: .sqlite(alias)), schema: graphSchema())
        #expect(try await first.snapshot().runtimeID == second.snapshot().runtimeID)
        try await first.close()
        try await second.close()
    }

    @Test func hardLinksAreRejectedInsteadOfOpeningAnotherCoordinator() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Main.sqlite")
        let alias = directory.appendingPathComponent("Alias.sqlite")
        let registry = StoreRegistry()
        let first = try await registry.open(StoreConfiguration(location: .sqlite(original)), schema: graphSchema())
        try FileManager.default.linkItem(at: original, to: alias)
        await #expect { try await registry.open(StoreConfiguration(location: .sqlite(alias)), schema: graphSchema()) } throws: { error in
            if case StoreRuntimeError.unsupportedFileAlias = error { return true }
            return false
        }
        try FileManager.default.removeItem(at: alias)
        _ = try await first.snapshot()
        try await first.close()
    }

    @Test func replacedFilesAreDetectedBeforeReadOrJoin() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Main.sqlite")
        let registry = StoreRegistry()
        let configuration = StoreConfiguration(location: .sqlite(original))
        let handle = try await registry.open(configuration, schema: graphSchema())
        try FileManager.default.moveItem(at: original, to: directory.appendingPathComponent("retained.sqlite"))
        try Data("replacement".utf8).write(to: original)
        await #expect { try await handle.snapshot() } throws: { error in
            if case StoreRuntimeError.storeReplaced = error { return true }
            return false
        }
        await #expect { try await registry.open(configuration, schema: graphSchema()) } throws: { error in
            if case StoreRuntimeError.storeReplaced = error { return true }
            return false
        }
        try await handle.close()
        #expect(try Data(contentsOf: original) == Data("replacement".utf8))
    }

    @Test func invalidLocationsAndMissingReadOnlyFilesAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = StoreRegistry()
        for location in [StoreLocation.sqlite(URL(string: "https://example.invalid/Main.sqlite")!),
                         .sqlite(directory), .inMemory(UUID())] {
            let access: StoreAccess = if case .inMemory = location { .readOnly } else { .readWrite }
            await #expect(throws: StoreRuntimeError.self) {
                try await registry.open(StoreConfiguration(location: location, access: access), schema: graphSchema())
            }
        }
        let missing = directory.appendingPathComponent("Missing.sqlite")
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(StoreConfiguration(location: .sqlite(missing), access: .readOnly), schema: graphSchema())
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func unreadableFileIsNotReplaced() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Unreadable.sqlite")
        let bytes = Data("not a store".utf8)
        try bytes.write(to: url)
        let registry = StoreRegistry()
        await #expect { try await registry.open(StoreConfiguration(location: .sqlite(url)), schema: graphSchema()) } throws: { error in
            if case StoreRuntimeError.loadFailed = error { return true }
            return false
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func readOnlyReopenUsesTheExistingStore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ReadOnly.sqlite")
        let registry = StoreRegistry()
        let writable = try await registry.open(StoreConfiguration(location: .sqlite(url)), schema: graphSchema())
        try await writable.close()
        let readOnly = try await registry.open(StoreConfiguration(location: .sqlite(url), access: .readOnly), schema: graphSchema())
        #expect(try await readOnly.snapshot().access == .readOnly)
        #expect(try await readOnly.read { $0.persistentStoreCoordinator!.persistentStores[0].isReadOnly })
        try await readOnly.close()
    }

    @Test func accidentalReadMutationsAreRolledBackBeforeTheNextOperation() async throws {
        let registry = StoreRegistry()
        let handle = try await registry.open(StoreConfiguration(location: .inMemory(UUID())), schema: fixtureSchema())
        await #expect {
            try await handle.read { context in
                let row = NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context)
                row.setValue("unsaved", forKey: "value")
            }
        } throws: { error in
            if case StoreRuntimeError.mutationInReadScope = error { return true }
            return false
        }
        #expect(try await handle.read { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RuntimeFixture")) } == 0)
        try await handle.close()
    }
}
