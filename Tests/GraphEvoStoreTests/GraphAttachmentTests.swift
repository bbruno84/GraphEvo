import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoModel

@Suite(.timeLimit(.minutes(2))) struct GraphAttachmentTests {
    private struct Abort: Error {}
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphAttachments-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func source(_ directory: URL, bytes: Data, name: String = "source.bin") throws -> URL {
        let url = directory.appendingPathComponent(name); try bytes.write(to: url); return url
    }
    private func owner(_ graph: GraphStore, kind: GraphEndpoints = .entity) async throws -> GraphNodeID {
        let id = graph.makeNodeID()
        try await graph.transaction { _ = try $0.insert(GraphRecord(id: id, type: "owner", endpoints: kind)) }
        return id
    }

    @Test func localReopenReplacementExportAndClosedWholeDirectoryBackupRetainExactContent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Live")
        let url = live.appendingPathComponent("Graph.sqlite")
        let graph = try await GraphStore.open(at: url)
        let owner = try await owner(graph)
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        let input = try source(root, bytes: bytes)
        let first = try await graph.importAttachment(from: input, ownedBy: owner, contentType: "public.data")
        try FileManager.default.removeItem(at: input)
        #expect(try await graph.attachment(first.id)?.data == bytes)
        let exported = root.appendingPathComponent("Export.bin")
        #expect(try await graph.exportAttachment(first.id, to: exported) == first)
        #expect(try Data(contentsOf: exported) == bytes)
        await #expect(throws: GraphAttachmentError.self) { try await graph.exportAttachment(first.id, to: exported) }
        #expect(try Data(contentsOf: exported) == bytes)
        let dangling = root.appendingPathComponent("dangling.bin")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent.bin"))
        await #expect(throws: GraphAttachmentError.self) { try await graph.exportAttachment(first.id, to: dangling) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path).hasSuffix("absent.bin"))
        let nextBytes = Data([0, 128, 255, 0])
        let replacement = try source(root, bytes: nextBytes)
        let next = try await graph.replaceAttachment(first.id, from: replacement, fileName: "replaced.bin")
        #expect(next.id == first.id && next.ownerID == owner && next.revision != first.revision)
        #expect(next.sha256 != first.sha256)
        #expect(try await graph.attachments(ownedBy: owner) == [next])
        try await graph.close()
        let backup = root.appendingPathComponent("Backup")
        try await GraphStoreBackup.copyClosedDirectory(from: live, to: backup)
        let restored = try await GraphStore.open(at: backup.appendingPathComponent("Graph.sqlite"))
        #expect(try await restored.attachment(first.id)?.data == nextBytes)
        try await restored.close()
        let reopened = try await GraphStore.open(at: url)
        #expect(try await reopened.attachment(first.id)?.metadata == next)
        try await reopened.deleteAttachment(first.id)
        #expect(try await reopened.attachment(first.id) == nil)
        try await reopened.close()
    }

    @Test(arguments: [0, 10 * 1024 * 1024]) func boundedContentRoundTrips(size: Int) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphStore.open(at: root.appendingPathComponent("Graph.sqlite"))
        let owner = try await owner(graph)
        let bytes = Data(repeating: 173, count: size)
        let source = try source(root, bytes: bytes)
        let result = try await graph.importAttachment(from: source, ownedBy: owner)
        #expect(result.byteCount == size)
        #expect(try await graph.attachment(result.id)?.data == bytes)
        try FileManager.default.removeItem(at: source)
        try await graph.close()
        let backup = root.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: backup) }
        try await GraphStoreBackup.copyClosedDirectory(from: root, to: backup)
        let restored = try await GraphStore.open(at: backup.appendingPathComponent("Graph.sqlite"))
        #expect(try await restored.attachment(result.id)?.data == bytes)
        try await restored.close()
    }

    @Test func ownerDeletionCascadesForEveryNodeKindAndRollbackRetainsBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphStore.inMemory()
        let input = try source(root, bytes: Data([0, 255]))
        for kind in [GraphEndpoints.entity, .relationship(subject: nil, object: nil), .action(subjects: [], objects: [])] {
            let owner = try await owner(graph, kind: kind)
            let a = try await graph.importAttachment(from: input, ownedBy: owner)
            let b = try await graph.importAttachment(from: input, ownedBy: owner)
            await #expect(throws: Abort.self) {
                try await graph.transaction { scope throws -> Void in try scope.delete(owner); throw Abort() }
            }
            #expect(try await graph.attachment(a.id)?.data == Data([0, 255]))
            try await graph.delete(owner)
            #expect(try await graph.attachment(a.id) == nil)
            #expect(try await graph.attachment(b.id) == nil)
        }
        try await graph.close()
    }

    @Test func deletingAnEndpointAlsoCleansFilesOwnedByItsImplicitlyDeletedEdge() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphStore.inMemory()
        let endpoint = try await owner(graph)
        let edge = try await owner(graph, kind: .relationship(subject: endpoint, object: nil))
        let input = try source(root, bytes: Data([1, 2, 3]))
        let attachment = try await graph.importAttachment(from: input, ownedBy: edge)
        try await graph.delete(endpoint)
        #expect(try await graph.attachment(attachment.id) == nil)
        try await graph.close()
    }

    @Test func invalidSourcesMetadataOwnersAndCancellationLeavePreviousContentUntouched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphStore.inMemory()
        let owner = try await owner(graph)
        let input = try source(root, bytes: Data([42]))
        let original = try await graph.importAttachment(from: input, ownedBy: owner)
        await #expect(throws: GraphAttachmentError.self) { try await graph.replaceAttachment(original.id, from: root) }
        await #expect(throws: GraphAttachmentError.self) { try await graph.importAttachment(from: input, ownedBy: owner, fileName: "../escape") }
        await #expect(throws: GraphStoreError.self) { try await graph.importAttachment(from: input, ownedBy: GraphNodeID(graphID: GraphID())) }
        await #expect(throws: GraphAttachmentError.self) { try await graph.importAttachment(from: input, ownedBy: original.id) }
        let oversized = try source(root, bytes: Data(repeating: 0, count: GraphStore.maximumAttachmentByteCount + 1), name: "large.bin")
        await #expect(throws: GraphAttachmentError.self) { try await graph.replaceAttachment(original.id, from: oversized) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await graph.replaceAttachment(original.id, from: input)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await graph.attachment(original.id)?.metadata == original)
        #expect(try await graph.attachment(original.id)?.data == Data([42]))
        #expect(try await graph.attachments(ownedBy: owner).count == 1)
        try await graph.close()
        await #expect(throws: GraphStoreError.self) { try await graph.exportAttachment(original.id, to: root.appendingPathComponent("closed.bin")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("closed.bin").path))
    }

    @Test func rawEditsCannotTransferOwnershipOrReplaceContentWithInvalidMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphStore.inMemory()
        let first = try await owner(graph), second = try await owner(graph)
        let input = try source(root, bytes: Data([8]))
        let metadata = try await graph.importAttachment(from: input, ownedBy: first)
        let transferred = try GraphAttachmentPayload(id: metadata.id, ownerID: second, fileName: "other.bin", contentType: "public.data", data: Data([9]))
        let record = try transferred.graphRecord()
        try await graph.transaction { scope in
            let patch = try GraphRecordPatch(id: metadata.id, properties: record.properties.mapValues { .set($0) })
            #expect(throws: GraphAttachmentError.self) { try scope.patch(patch) }
            let malformed = try GraphRecordPatch(id: metadata.id, properties: ["content": .set(.data(Data([0])))])
            #expect(throws: GraphAttachmentError.self) { try scope.patch(malformed) }
        }
        #expect(try await graph.attachment(metadata.id)?.metadata == metadata)
        #expect(try await graph.attachment(metadata.id)?.data == Data([8]))
        try await graph.close()
    }

    @Test func sharingIntegrityRejectsAnImportedFileWithAnUnavailableOwnerButControlLookupSurvives() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let owner = try await owner(graph)
        let metadata = try await graph.importAttachment(from: source(root, bytes: Data([1])), ownedBy: owner)
        let orphan = try GraphAttachmentPayload(id: metadata.id, ownerID: graph.makeNodeID(), fileName: "orphan.bin", contentType: "public.data", data: Data([1])).graphRecord()
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let file = try #require(session.nodes[metadata.id])
                // Inject a partial-import reference through its scoped facade; no mutation is committed.
                file[dynamicMember: "content"] = try GraphValueCodec.encode(try #require(orphan.properties["content"]))
                #expect(throws: GraphAttachmentError.self) { try GraphTypedStoreAdapter.mirroringRoot(context, id: graph.id) }
                #expect(throws: GraphAttachmentError.self) { try GraphTypedStoreAdapter.nativeMembers(context, id: graph.id) }
                #expect(try GraphTypedStoreAdapter.controlRoot(context, id: graph.id).runtimeTypeIfPresent == GraphTypedStoreAdapter.rootType)
            }
        }
        #expect(try await graph.attachment(metadata.id)?.metadata == metadata)
        try await graph.close(); try await database.close()
    }

    @Test func wholeDirectoryBackupRejectsNestedAndExistingDestinations() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Live"); try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        _ = try source(live, bytes: Data([7]))
        let broken = root.appendingPathComponent("Broken"), missing = root.appendingPathComponent("Missing")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        await #expect(throws: GraphAttachmentError.self) { try await GraphStoreBackup.copyClosedDirectory(from: live, to: broken) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        await #expect(throws: GraphAttachmentError.self) { try await GraphStoreBackup.copyClosedDirectory(from: live, to: live.appendingPathComponent("nested")) }
        await #expect(throws: GraphAttachmentError.self) { try await GraphStoreBackup.copyClosedDirectory(from: live, to: root) }
        let destination = root.appendingPathComponent("Existing"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await #expect(throws: GraphAttachmentError.self) { try await GraphStoreBackup.copyClosedDirectory(from: live, to: destination) }
    }
}
