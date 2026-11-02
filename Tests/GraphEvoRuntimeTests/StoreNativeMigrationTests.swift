import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1)))
struct StoreNativeMigrationTests {
    @Test func seedMetadataFailureDoesNotPublishAnUnmarkedV1Destination() async throws {
        struct StampFailure: Error {}
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.sqlite")
        let destination = directory.appendingPathComponent("Target.sqlite")
        try await createV1Fixture(at: source)
        let original = try Data(contentsOf: source)
        let operation = UUID(), graph = UUID()
        let document = Data("native-seed-test".utf8)
        let plan = StoreNativeMigration(sourceSchema: graphSchema(), seedURL: source, document: document,
            configure: { _, _ in }, finish: { _ in })
        let configuration = StoreConfiguration(location: .sqlite(destination), exclusiveGraphID: graph,
            workspaceID: operation, workspaceSessionID: UUID())
        let resolved = try ResolvedStore(configuration)

        #expect(throws: StampFailure.self) { try plan.seed(resolved, beforeStamp: { throw StampFailure() }) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try GraphStoreMetadata.isCompatible(at: source))
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".graphevo-native-seed-") })

        try plan.seed(resolved)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: destination)
        #expect(metadata[StoreNativeContext.workspaceKey] as? String == operation.uuidString)
        #expect(metadata[StoreNativeContext.historySyncGraphKey] as? String == graph.uuidString)
        #expect(metadata[StoreNativeMigration.documentKey] as? Data == document)
        #expect(try !GraphStoreMetadata.isCompatible(at: destination))
        let registry = StoreRegistry()
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(.init(location: .sqlite(destination)), schema: graphSchema())
        }
        #expect(try Data(contentsOf: source) == original)
    }
}
