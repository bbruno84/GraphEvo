import Foundation
import Testing
import GraphEvoRuntime
import GraphEvoStore
@testable import GraphEvo

@Suite(.timeLimit(.minutes(2))) struct GraphReadOnlyDatabaseTests {
    private enum Failure: Error { case bodyInvoked }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnlyGraph-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectReadOnly<Value: Sendable>(_ operation: () async throws -> Value) async {
        do { _ = try await operation(); Issue.record("A read-only database admitted a mutation.") }
        catch GraphStoreError.readOnly { }
        catch { Issue.record("Unexpected read-only failure: \(error)") }
    }

    @Test(arguments: [false, true])
    func publicReaderPreservesDataFilesAndRejectsMutationBodies(native: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Main.sqlite")
        let schema: GraphDatabaseSchema = native ? .nativeIdentity : .current
        let writer = try await GraphDatabase.open(at: url, schema: schema)
        let graph = try await writer.createGraph(), id = graph.makeNodeID()
        try await graph.transaction { _ = try $0.insert(GraphRecord(id: id, type: "item", properties: ["name": .string("kept")])) }
        let source = root.appendingPathComponent("input.bin"); try Data([2, 4, 6]).write(to: source)
        let attachment = try await graph.importAttachment(from: source, ownedBy: id)
        try await graph.close(); try await writer.close()

        let reader = try await GraphDatabase.openReadOnly(at: url, schema: schema)
        #expect(try await reader.graphIDs() == [graph.id])
        let view = try await reader.openGraph(graph.id)
        #expect(try await view.read { try $0.record(for: id)?.properties["name"] } == .string("kept"))
        #expect(try await view.attachment(attachment.id)?.data == Data([2, 4, 6]))
        await expectReadOnly { try await reader.createGraph() }
        await expectReadOnly { try await view.transaction { _ -> Int in throw Failure.bodyInvoked } }
        await expectReadOnly { try await view.delete(id) }
        if native { #expect(try await reader.validateIntegrity(of: graph.id) == 2) }
        try await view.close(); try await reader.close()
        let reopened = try await GraphDatabase.open(at: url, schema: schema)
        #expect(try await reopened.graphIDs() == [graph.id])
        let check = try await reopened.openGraph(graph.id)
        #expect(try await check.attachment(attachment.id)?.data == Data([2, 4, 6]))
        try await check.close(); try await reopened.close()
    }

    @Test(arguments: [false, true])
    func pairedReaderRoutesBothCatalogsWithoutNativeMirroring(native: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let schema: GraphDatabaseSchema = native ? .nativeIdentity : .current
        let privateURL = root.appendingPathComponent("private.sqlite"), sharedURL = root.appendingPathComponent("shared.sqlite")
        var graphIDs: [GraphID] = []
        let commonUUID = UUID()
        for url in [privateURL, sharedURL] {
            let db = try await GraphDatabase.open(at: url, schema: schema), graph = try await db.createGraph()
            graphIDs.append(graph.id)
            let node = GraphNodeID(graphID: graph.id, rawValue: commonUUID)
            try await graph.transaction { _ = try $0.insert(GraphRecord(id: node, type: "pair.item", properties: ["source": .string(url.lastPathComponent)])) }
            try await graph.close(); try await db.close()
        }
        let reader = try await GraphDatabase.openReadOnly(privateStoreAt: privateURL, sharedStoreAt: sharedURL, schema: schema)
        #expect(Set(try await reader.graphIDs()) == Set(graphIDs))
        for id in graphIDs {
            let view = try await reader.openGraph(id)
            let expected = id == graphIDs[0] ? privateURL.lastPathComponent : sharedURL.lastPathComponent
            #expect(try await view.read { try $0.record(for: GraphNodeID(graphID: id, rawValue: commonUUID))?.properties["source"] } == .string(expected))
            if native { #expect(try await reader.validateIntegrity(of: id) == 1) }
            await expectReadOnly { try await view.transaction { _ -> Int in throw Failure.bodyInvoked } }
            try await view.close()
        }
        // Diagnostics confirm that a local paired reader has no native synchronization owner.
        await #expect(throws: GraphMirroringError.self) { try await reader.cloudSetupStatus() }
        try await reader.close()
    }

    @Test func missingOrIncompatibleResourcesAreNeverInitializedOrConverted() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Absent/Main.sqlite")
        await #expect { try await GraphDatabase.openReadOnly(at: missing) } throws: { error in
            if case GraphStoreError.missingStore = error { return true }; return false
        }
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let existing = root.appendingPathComponent("existing.sqlite")
        let db = try await GraphDatabase.open(at: existing); try await db.close()
        await #expect(throws: (any Error).self) { try await GraphDatabase.openReadOnly(at: existing, schema: .nativeIdentity) }
        await #expect(throws: (any Error).self) {
            try await GraphDatabase.openReadOnly(privateStoreAt: existing, sharedStoreAt: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let preserved = try await GraphDatabase.openReadOnly(at: existing)
        #expect(try await preserved.graphIDs().isEmpty); try await preserved.close()
    }

    @Test func readOnlyDoesNotBypassSameProcessOwnershipAndErrorsRemainPublic() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Main.sqlite"), db = try await GraphDatabase.open(at: url)
        await #expect { try await GraphDatabase.openReadOnly(at: url) } throws: { error in
            if case GraphStoreError.ownershipConflict = error { return true }; return false
        }
        try await db.close()
        guard case GraphStoreError.synchronizationUnavailableInExtension = GraphStore.translate(StoreRuntimeError.synchronizationUnavailableInExtension) else {
            Issue.record("Extension mirroring refusal lost its public typed error."); return
        }
    }
}
