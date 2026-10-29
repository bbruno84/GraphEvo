import Foundation
import GraphEvo
import XCTest
@testable import GraphEvoDemo

@MainActor final class WidgetProbeOwnerTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetOwnerTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testOwnerCloseAndResumePreservesIdentityAndCounter() async throws {
        let root = try root(), owner = WidgetProbeOwner(root: root), run = UUID()
        let initial = try await owner.prepare(run: run, mirrored: false); XCTAssertEqual(initial, 0)
        let original = try WidgetProbeStorage.manifest(in: root)
        let first = try await owner.increment(expectedRun: run); XCTAssertEqual(first, 1)
        try await owner.close()
        let second = try await owner.increment(expectedRun: run); XCTAssertEqual(second, 2)
        try await owner.close()
        let resumed = try WidgetProbeStorage.manifest(in: root)
        XCTAssertEqual(original.graphID, resumed.graphID); XCTAssertEqual(original.nodeID, resumed.nodeID)
        let database = try await GraphDatabase.openReadOnly(at: WidgetProbeStorage.urls(in: WidgetProbeStorage.folder(resumed, root: root)).0, schema: .nativeIdentity)
        let graph = try await database.openGraph(resumed.graphID)
        let item = try await graph.fetch(resumed.nodeID, as: WidgetProbeItem.self); XCTAssertEqual(item?.value, 2)
        try await graph.close(); try await database.close()
        try FileManager.default.removeItem(at: root)
    }

    func testReservedPrepareCannotReplayOrReplaceExistingFixture() async throws {
        let root = try root(), owner = WidgetProbeOwner(root: root), run = UUID()
        _ = try await owner.prepare(run: run, mirrored: false)
        let original = try WidgetProbeStorage.manifest(in: root)
        do { _ = try await owner.prepare(run: run, mirrored: false); XCTFail("A seed was replayed.") }
        catch WidgetProbeStorage.Failure.replay { }
        let kept = try WidgetProbeStorage.manifest(in: root)
        XCTAssertEqual(original.graphID, kept.graphID); XCTAssertEqual(original.nodeID, kept.nodeID)
        let next = try await owner.increment(expectedRun: run); XCTAssertEqual(next, 1)
        try await owner.close(); try FileManager.default.removeItem(at: root)
    }

    func testForeignRunCannotMutateThePublishedCounter() async throws {
        let root = try root(), owner = WidgetProbeOwner(root: root), run = UUID()
        _ = try await owner.prepare(run: run, mirrored: false)
        do { _ = try await owner.increment(expectedRun: UUID()); XCTFail("An unrelated run changed the counter.") }
        catch WidgetProbeStorage.Failure.mismatch { }
        let next = try await owner.increment(expectedRun: run); XCTAssertEqual(next, 1)
        try await owner.close(); try FileManager.default.removeItem(at: root)
    }
}
