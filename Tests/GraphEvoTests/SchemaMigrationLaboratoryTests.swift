import CoreData
import XCTest
@testable import GraphEvo

@available(iOS 17, macOS 14, *)
@MainActor final class SchemaMigrationLaboratoryTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SchemaMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("store.sqlite")
    }
    func testLaboratoryModelsMatchNativeCandidateAndVersionIsNullable() throws {
        let v1 = GraphSchemaMigrationLaboratory.model(.v1)
        let native = GraphSchemaMigrationLaboratory.model(.native)
        let versioned = GraphSchemaMigrationLaboratory.model(.versioned)
        XCTAssertEqual(v1.entityVersionHashesByName, Model.makeModel().entityVersionHashesByName)
        XCTAssertEqual(native.entityVersionHashesByName, GraphNativeIdentityColumns.makeModel(indexed: true).entityVersionHashesByName)
        XCTAssertNotEqual(v1.entityVersionHashesByName, native.entityVersionHashesByName)
        XCTAssertNotEqual(native.entityVersionHashesByName, versioned.entityVersionHashesByName)
        for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
            let attribute = try XCTUnwrap(versioned.entitiesByName[name]?.attributesByName[GraphSchemaMigrationLaboratory.versionKey])
            XCTAssertTrue(attribute.isOptional); XCTAssertNil(attribute.defaultValue)
        }
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: v1, destinationModel: native)
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: native, destinationModel: versioned)
    }
    func testLightweightPreservesV1RowsAndAddsNullableNativeColumns() async throws {
        let url = try location(), run = UUID()
        let old = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        try await old.seed(); let before = try await old.snapshot(); XCTAssertEqual(before.count, 4)
        try await old.close()
        let migrated = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .native)
        let after = try await migrated.snapshot(); XCTAssertEqual(after, before)
        try await migrated.close()
        let versioned = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .versioned)
        let unchanged = try await versioned.snapshot(); XCTAssertEqual(unchanged, before)
        try await versioned.transform(value: "ordinary-save", version: 2)
        let changed = try await versioned.snapshot()
        XCTAssertTrue(changed.allSatisfy { $0.dataVersion == 2 && $0.nodeProjection == $0.id && $0.graphProjection == run.uuidString })
        XCTAssertEqual(changed.map(\.bytes), before.map(\.bytes))
        try await versioned.close()
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    func testStagedHandlersTransformBeforeAndAfterNativeMigration() async throws {
        let url = try location(), run = UUID()
        let old = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        try await old.seed(); let before = try await old.snapshot(); try await old.close()
        let migrated = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .versioned, route: .staged)
        XCTAssertEqual(migrated.handlerEvents, ["will", "did"])
        let rows = try await migrated.snapshot()
        XCTAssertEqual(rows.map(\.id), before.map(\.id)); XCTAssertEqual(rows.map(\.bytes), before.map(\.bytes))
        XCTAssertEqual(rows.map(\.subjects), before.map(\.subjects)); XCTAssertEqual(rows.map(\.objects), before.map(\.objects))
        XCTAssertTrue(rows.allSatisfy { $0.label == "handler-after" && $0.dataVersion == 1 })
        try await migrated.close()
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    func testFailedStageRetainsSourceAndDoesNotAuthorizeBlindReplay() async throws {
        let url = try location(), run = UUID()
        let old = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        try await old.seed(); let before = try await old.snapshot(); try await old.close()
        let backup = url.deletingLastPathComponent().appendingPathExtension("backup")
        try FileManager.default.copyItem(at: url.deletingLastPathComponent(), to: backup)
        do {
            _ = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .versioned, route: .stagedFailure)
            XCTFail("The injected stage failure was ignored.")
        } catch GraphSchemaMigrationLaboratory.Failure.injected { }
        let source = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        let interrupted = try await source.snapshot()
        XCTAssertEqual(interrupted.map(\.id), before.map(\.id))
        XCTAssertTrue(interrupted.allSatisfy { $0.label == "handler-before" })
        try await source.close()
        let protected = try await GraphSchemaMigrationLaboratory.open(urls: [backup.appendingPathComponent("store.sqlite")], run: run, layout: .v1)
        let original = try await protected.snapshot(); XCTAssertEqual(original, before)
        try await protected.close()
        try FileManager.default.removeItem(at: url.deletingLastPathComponent()); try FileManager.default.removeItem(at: backup)
    }

    func testOverlappingOwnersAreRejectedUntilExplicitDetach() async throws {
        let url = try location(), run = UUID()
        let first = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        do {
            _ = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .versioned)
            XCTFail("An overlapping owner was admitted.")
        } catch GraphSchemaMigrationLaboratory.Failure.overlap { }
        try await first.close()
        let next = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .versioned)
        try await next.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testImportReadinessRejectsFourRowsWithMissingEndpoints() async throws {
        let url = try location(), run = UUID()
        let owner = try await GraphSchemaMigrationLaboratory.open(urls: [url], run: run, layout: .v1)
        try await owner.seed(); let rows = try await owner.snapshot()
        XCTAssertTrue(GraphSchemaMigrationLaboratory.completeFixture(rows))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)) as? [[String: Any]])
        let edge = try XCTUnwrap(json.firstIndex { $0["kind"] as? String == "relationship" })
        json[edge]["subjects"] = []
        let partial = try JSONDecoder().decode([GraphSchemaMigrationLaboratory.Row].self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(partial.count, 4)
        XCTAssertFalse(GraphSchemaMigrationLaboratory.completeFixture(partial))
        try await owner.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

}
