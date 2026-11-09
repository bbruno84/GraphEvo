import CoreData
import Darwin
import Foundation
@testable import GraphEvo
import GraphEvoStore
import Testing

@Suite(.timeLimit(.minutes(2))) struct GraphLocalFileTests {
    private struct EntityView: GraphModel {
        static let graphType = "probe.entity"
        static let graphKind = GraphNodeKind.entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) throws { record = graphRecord }
        func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
    }

    private struct FileAsEntity: GraphModel {
        static let graphType = "GraphEvo.File.v1"
        static let graphKind = GraphNodeKind.entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) throws { record = graphRecord }
        func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
    }

    private struct FileNode: GraphModel {
        static let graphType = "GraphEvo.File.v1"
        static let graphKind = GraphNodeKind.file
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) throws { record = graphRecord }
        func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
    }

    private enum Interrupted: Error { case beforeCommit }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func contentRoot(_ store: URL) throws -> URL {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: store,
            options: [NSReadOnlyPersistentStoreOption: true])
        let id = try #require((metadata[NSStoreUUIDKey] as? String).flatMap(UUID.init(uuidString:)))
        return GraphFileDisk.root(for: store, storeID: id)
    }

    @available(iOS 17, macOS 14, *)
    @Test func migratesClosedS04AndPreservesLinksAndExactQueries() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let s04 = root.appendingPathComponent("S04.sqlite")
        let graphID = GraphID(), local = GraphContext(manager: GraphContextManager(schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter))
        let original = try await local.createGraph(id: graphID, at: s04)
        let a = original.makeNodeID(), b = original.makeNodeID(), relation = original.makeNodeID(), action = original.makeNodeID()
        let legacyBytes = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        let attachmentSource = root.appendingPathComponent("ExistingAttachment.bin")
        try legacyBytes.write(to: attachmentSource)
        let records = [
            try GraphRecord(id: a, type: EntityView.graphType, properties: ["rank": .integer(7), "legacyBytes": .string(legacyBytes.base64EncodedString())]),
            try GraphRecord(id: b, type: EntityView.graphType),
            try GraphRecord(id: relation, type: "edge", endpoints: .relationship(subject: a, object: b)),
            try GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b]))
        ]
        try await original.transaction { scope in for record in records { try scope.insert(record) } }
        let attachment = try await original.importAttachment(from: attachmentSource, ownedBy: a)
        try FileManager.default.removeItem(at: attachmentSource)
        let destination = root.appendingPathComponent("Migrated")
        do {
            _ = try await GraphContext.migrateClosedS04Store(from: s04, into: destination)
            Issue.record("Migration accepted a source with a live owner.")
        } catch GraphStoreError.ownershipConflict { }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await original.close()
        let migrated = try await GraphContext.migrateClosedS04Store(from: s04, into: destination)
        let old = try await local.openGraph(id: graphID, at: s04)
        #expect(try await old.read { try $0.record(for: relation)?.endpoints } == records[2].endpoints)
        try await old.close()

        let fileContext = GraphContext(manager: GraphContextManager(schema: GraphRuntimeSchema.localFiles, adapter: GraphCoordinatorFactory.adapter))
        let graph = try await fileContext.openGraph(id: graphID, at: migrated)
        let migratedAttachment = try await graph.attachment(attachment.id)
        #expect(migratedAttachment?.metadata == attachment)
        #expect(migratedAttachment?.data == legacyBytes)
        try await graph.read { scope in
            for record in records {
                let loaded = try scope.record(for: record.id)
                #expect(loaded?.endpoints == record.endpoints)
                #expect(loaded?.properties == record.properties)
            }
        }
        let source = root.appendingPathComponent("source")
        try Data("file".utf8).write(to: source)
        let file = try await graph.importFile(from: source, name: "file.pdf", contentType: "com.adobe.pdf")
        let newEdge = graph.makeNodeID(), sameType = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: sameType, type: FileAsEntity.graphType))
            _ = try scope.patch(GraphRecordPatch(id: file.id, addingTags: ["invoice"], addingGroups: ["expenses"]))
            _ = try scope.patch(GraphRecordPatch(id: relation, endpoints: .relationship(subject: a, object: file.id)))
            try scope.insert(GraphRecord(id: newEdge, type: "edge", endpoints: .relationship(subject: file.id, object: a)))
            _ = try scope.patch(GraphRecordPatch(id: action, endpoints: .action(subjects: [a, file.id], objects: [file.id])))
        }
        try await graph.close()
        let reopened = try await fileContext.openGraph(id: graphID, at: migrated)
        #expect(try await reopened.files() == [file])
        let budget = try GraphQueryBudget(maximumCandidates: 100)
        let entityQuery = GraphQuery<EntityView>(budget: budget)
        let fileQuery = GraphQuery<FileNode>(budget: budget)
        let asEntity = GraphQuery<FileAsEntity>(budget: budget)
        #expect(Set(try await reopened.query(entityQuery).items.map(\.id)) == [a, b])
        #expect(try await reopened.query(asEntity).items.map(\.id) == [sameType])
        #expect(try await reopened.count(asEntity).value == 1)
        #expect(try await reopened.project(asEntity, properties: []).rows.map(\.id) == [sameType])
        let classified = fileQuery.where(.tag("invoice") && .group("expenses"))
        #expect(try await reopened.query(classified).items.map(\.id) == [file.id])
        await #expect(throws: GraphFileError.fixedMetadata) {
            try await reopened.transaction { scope in
                try scope.patch(GraphRecordPatch(id: file.id, properties: ["name": .set(.string("changed"))],
                    addingTags: ["invalid"]))
            }
        }
        #expect(try await reopened.read { try $0.record(for: file.id)?.tags } == ["invoice"])
        #expect(try await reopened.read { try $0.record(for: newEdge)?.endpoints } == .relationship(subject: file.id, object: a))
        #expect(try await reopened.read { try $0.record(for: action)?.endpoints } == .action(subjects: [a, file.id], objects: [file.id]))
        try await reopened.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: b, addingTags: ["pending"]))
            #expect(try scope.count(asEntity).value == 1)
            let updated = try scope.patch(GraphRecordPatch(id: file.id,
                addingTags: ["paid"], removingTags: ["invoice"],
                addingGroups: ["archive"], removingGroups: ["expenses"]))
            #expect(updated.tags == ["paid"])
            #expect(updated.groups == ["archive"])
            #expect(try scope.count(classified).value == 0)
            #expect(try scope.count(fileQuery.where(.tag("paid") && .group("archive"))).value == 1)
        }
        #expect(try await reopened.count(classified).value == 0)
        #expect(try await reopened.count(fileQuery.where(.tag("paid") && .group("archive"))).value == 1)
        try await reopened.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func interruptedReplacementKeepsOriginalAndReclaimRemovesOrphan() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("Graph.sqlite")
        let id = GraphID(), context = GraphContext.localFiles()
        let graph = try await context.createGraph(id: id, at: store)
        let source = root.appendingPathComponent("source")
        try Data("one".utf8).write(to: source)
        let file = try await graph.importFile(from: source)
        try Data("two".utf8).write(to: source)
        await #expect(throws: Interrupted.beforeCommit) {
            try await graph.saveFile(file.id, from: source, name: file.name, contentType: file.contentType,
                                     expectedRevision: file.revision) { throw Interrupted.beforeCommit }
        }
        try await graph.close()
        let reopened = try await context.openGraph(id: id, at: store)
        #expect(try await reopened.file(file.id) == file)
        #expect(try await reopened.withFileURL(file.id) { try Data(contentsOf: $0) } == Data("one".utf8))
        let abandoned = try contentRoot(store).appendingPathComponent(UUID().uuidString + ".partial")
        try Data("partial".utf8).write(to: abandoned)
        #expect(try await reopened.reclaimFiles() == 2)
        #expect(try await reopened.reclaimFiles() == 0)
        try await reopened.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func replacementKeepsScopedReaderAndBackupRestoresCurrentFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("Graph.sqlite")
        let id = GraphID(), context = GraphContext.localFiles()
        let graph = try await context.createGraph(id: id, at: store)
        let source = root.appendingPathComponent("source")
        try Data("old".utf8).write(to: source)
        let file = try await graph.importFile(from: source)
        try await graph.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: file.id, addingTags: ["retained"], addingGroups: ["documents"]))
        }
        try Data("new".utf8).write(to: source)
        let ready = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let reading = Task {
            try await graph.withFileURL(file.id) { url in
                ready.continuation.yield(())
                ready.continuation.finish()
                guard release.wait(timeout: .now() + 15) == .success else { throw Interrupted.beforeCommit }
                return try Data(contentsOf: url)
            }
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        let replacement: GraphFile
        do { replacement = try await graph.replaceFile(file, from: source) }
        catch { release.signal(); _ = try? await reading.value; throw error }
        let reclaiming = AsyncStream<Void>.makeStream()
        let reclaim = Task {
            reclaiming.continuation.yield(())
            reclaiming.continuation.finish()
            return try await graph.reclaimFiles()
        }
        for await _ in reclaiming.stream { break }
        try await Task.sleep(for: .milliseconds(200))
        let pinned = try GraphFileDisk.url(for: file, in: contentRoot(store))
        #expect(FileManager.default.fileExists(atPath: pinned.path))
        release.signal()
        #expect(try await reclaim.value == 1)
        #expect(try await reading.value == Data("old".utf8))
        #expect(replacement.id == file.id)
        #expect(replacement.revision != file.revision)
        await #expect(throws: GraphFileError.conflict) { try await graph.replaceFile(file, from: source) }
        try FileManager.default.removeItem(at: source)
        let copy = try await graph.copyLocalFileGraph(into: root.appendingPathComponent("Backup"))
        try await graph.deleteFile(file.id)
        try await graph.close()

        let reopened = try await context.openGraph(id: id, at: store)
        #expect(try await reopened.file(file.id) == nil)
        let unrelated = GraphFileDisk.root(for: store, storeID: UUID())
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let unrelatedFile = unrelated.appendingPathComponent(UUID().uuidString)
        try Data("other store".utf8).write(to: unrelatedFile)
        #expect(try await reopened.reclaimFiles() == 1)
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
        try await reopened.close()
        let restored = try await GraphContext.localFiles().openGraph(id: id, at: copy)
        #expect(try await restored.file(file.id) == replacement)
        let record = try await restored.read { try $0.record(for: file.id) }
        #expect(record?.tags == ["retained"])
        #expect(record?.groups == ["documents"])
        #expect(try await restored.withFileURL(file.id) { try Data(contentsOf: $0) } == Data("new".utf8))
        #expect(try await restored.reclaimFiles() == 0)
        try await restored.close()
    }


    @available(iOS 17, macOS 14, *)
    @Test func importsAFileLargerThanTheAttachmentLimit() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext.localFiles().createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let source = root.appendingPathComponent("Large.bin")
        try Data().write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        let size = 25 * 1024 * 1024
        try writer.truncate(atOffset: UInt64(size))
        try writer.close()
        let file = try await graph.importFile(from: source)
        try FileManager.default.removeItem(at: source)
        #expect(file.byteCount == Int64(size))
        #expect(try await graph.withFileURL(file.id) {
            try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } == size)
        try await graph.close()
    }

#if os(macOS) && compiler(>=6.2)
    @available(macOS 15, *)
    @Test func processExitAfterRenameLeavesCommittedRevisionReadable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("Graph.sqlite"), source = root.appendingPathComponent("source")
        let graphID = GraphID(), context = GraphContext.localFiles()
        let graph = try await context.createGraph(id: graphID, at: store)
        try Data("committed".utf8).write(to: source)
        let file = try await graph.importFile(from: source)
        try await graph.close()
        try Data("uncommitted".utf8).write(to: source)
        let fileID = file.id, revision = file.revision
        await #expect(processExitsWith: .signal(SIGKILL)) { [
            store = store as URL, source = source as URL, graphID = graphID as GraphID,
            fileID = fileID as GraphNodeID, revision = revision as UUID
        ] in
            let peer = try await GraphContext.localFiles().openGraph(id: graphID, at: store)
            _ = try await peer.saveFile(fileID, from: source, name: "source", contentType: "public.data",
                                       expectedRevision: revision) {
                kill(getpid(), SIGKILL)
            }
        }
        let reopened = try await context.openGraph(id: graphID, at: store)
        #expect(try await reopened.file(fileID) == file)
        #expect(try await reopened.withFileURL(fileID) { try Data(contentsOf: $0) } == Data("committed".utf8))
        #expect(try await reopened.reclaimFiles() == 1)
        try await reopened.close()
    }
#endif
}


extension GraphLocalFileTests {
    @available(iOS 17, macOS 14, *)
    @Test func configuredImportCommitsFileAndRelationshipTogether() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Atomic.sqlite"), source = root.appendingPathComponent("Input.bin")
        let bytes = Data(repeating: 43, count: 256 * 1024); try bytes.write(to: source)
        let context = GraphContext.localFiles(), graph = try await context.createGraph(id: GraphID(), at: path)
        let note = graph.makeNodeID(), edge = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "Note")) }
        let file = try await graph.importFile(from: source) { scope, file in
            #expect(try scope.file(file.id) == file)
            try scope.insert(GraphRecord(id: edge, type: "NoteFile", endpoints: .relationship(subject: note, object: file.id)))
            _ = try scope.patch(GraphRecordPatch(id: note, properties: ["hasFile": .set(.boolean(true))]))
        }
        try await graph.close()
        let reopened = try await context.openGraph(id: graph.id, at: path)
        #expect(try await reopened.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: note, object: file.id))
        #expect(try await reopened.read { try $0.record(for: note)?.properties["hasFile"] } == .boolean(true))
        #expect(try await reopened.withFileURL(file.id) { try Data(contentsOf: $0) } == bytes)
        try await reopened.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func configuredImportFailureRollsBackAllRowsAndLeavesReclaimableBytes() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Atomic.sqlite"), source = root.appendingPathComponent("Input.bin")
        try Data(repeating: 8, count: 1024).write(to: source)
        let context = GraphContext.localFiles(), graph = try await context.createGraph(id: GraphID(), at: path)
        let note = graph.makeNodeID(), edge = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "Note", properties: ["name": .string("before")])) }
        await #expect(throws: Interrupted.self) {
            _ = try await graph.importFile(from: source) { scope, file in
                try scope.insert(GraphRecord(id: edge, type: "NoteFile", endpoints: .relationship(subject: note, object: file.id)))
                _ = try scope.patch(GraphRecordPatch(id: note, properties: ["name": .set(.string("after"))]))
                throw Interrupted.beforeCommit
            }
        }
        #expect(try await graph.files().isEmpty)
        #expect(try await graph.read { try $0.record(for: edge) } == nil)
        #expect(try await graph.read { try $0.record(for: note)?.properties["name"] } == .string("before"))
        #expect(try await graph.reclaimFiles() == 1)
        try await graph.close()
    }
    @available(iOS 17, macOS 14, *)
    @Test func configuredImportCannotReturnAnAlreadyDeletedFile() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Input.bin"); try Data([1,2,3]).write(to: source)
        let graph = try await GraphContext.localFiles().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        await #expect(throws: GraphFileError.self) {
            _ = try await graph.importFile(from: source) { scope, file in try scope.delete(file.id) }
        }
        #expect(try await graph.files().isEmpty)
        #expect(try await graph.reclaimFiles() == 1)
        try await graph.close()
    }

}
