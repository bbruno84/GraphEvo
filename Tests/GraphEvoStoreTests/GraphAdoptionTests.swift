import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime

@MainActor private func createV1(at url: URL) throws -> [String] {
    try autoreleasepool {
        let graph = Graph(storeURL: url, migrationEnabled: false)
        #expect(graph.isReady)
        let author = Entity("author", graph: graph), note = Entity("note", graph: graph)
        author[dynamicMember: "name"] = "Ada"
        author[dynamicMember: "unknown"] = Data([0, 255, 137])
        author.add(tags: "retained")
        author.add(to: "authors")
        author.setCreatedDate(Date(timeIntervalSince1970: 123_456))
        author.is(relationship: "writes").of(note)
        author.will(action: "reviews").add(objects: note)
        var failure: Error?
        graph.sync { if !$0 { failure = $1 } }
        if let failure { throw failure }
        let ids = [author.id, note.id]
        let container = try #require(graph.persistentContainer)
        graph.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        return ids
    }
}

private func adoptionDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphAdoption-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(1))) struct GraphAdoptionTests {
    @Test func explicitAdoptionBacksUpAndPreservesV1DataReferencesAndIDMapping() async throws {
        let directory = try adoptionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let oldIDs = try await createV1(at: url)
        await #expect(throws: GraphStoreError.self) { try await GraphStore.open(at: url) }
        let (store, report) = try await GraphStore.adoptLocalV1Store(at: url, backupRoot: directory.appendingPathComponent("backups"))
        #expect(report.nodeIDs.count == 4)
        let backup = try #require(report.backupURL)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Main.sqlite").path))
        let authorID = try #require(report.nodeIDs[oldIDs[0]])
        let noteID = try #require(report.nodeIDs[oldIDs[1]])
        let author = try #require(try await store.read { try $0.record(for: authorID) })
        #expect(author.properties["name"] == .string("Ada"))
        #expect(author.properties["unknown"] == .data(Data([0, 255, 137])))
        #expect(author.createdDate == Date(timeIntervalSince1970: 123_456))
        #expect(author.tags == ["retained"])
        #expect(author.groups == ["authors"])
        #expect(author.properties.keys.allSatisfy { !$0.hasPrefix("__graphevo_v2.") })
        let records = try await store.read { scope in
            try report.nodeIDs.values.compactMap { try scope.record(for: $0) }
        }
        #expect(records.contains { $0.endpoints == .relationship(subject: authorID, object: noteID) })
        #expect(records.contains { $0.endpoints == .action(subjects: [authorID], objects: [noteID]) })
        try await store.close()
        let (reopened, repeated) = try await GraphStore.adoptLocalV1Store(at: url, backupRoot: directory.appendingPathComponent("backups"))
        #expect(reopened.id == report.graphID)
        #expect(repeated.nodeIDs == report.nodeIDs)
        #expect(repeated.backupURL == nil)
        _ = try await reopened.transaction { scope in
            try scope.patch(GraphRecordPatch(id: authorID, properties: ["name": .set(.string("Grace"))]))
        }
        let patched = try #require(try await reopened.read { try $0.record(for: authorID) })
        #expect(patched.properties["name"] == .string("Grace"))
        #expect(patched.properties["unknown"] == author.properties["unknown"])
        try await reopened.close()
        // The backup is the pre-adoption store, usable through the original facade.
        try await MainActor.run {
            let backupGraph = Graph(storeURL: backup.appendingPathComponent("Main.sqlite"), migrationEnabled: false)
            #expect(backupGraph.isReady)
            #expect(Search<Entity>(graph: backupGraph).where(.type("author")).sync().count == 1)
        }
    }

    @Test func backupFailureLeavesTheSourceUsableByTheV1Facade() async throws {
        let directory = try adoptionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        _ = try await createV1(at: url)
        let invalidRoot = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: invalidRoot)
        await #expect(throws: (any Error).self) { try await GraphStore.adoptLocalV1Store(at: url, backupRoot: invalidRoot) }
        await MainActor.run {
            let graph = Graph(storeURL: url, migrationEnabled: false)
            #expect(graph.isReady)
            #expect(Search<Entity>(graph: graph).where(.type("author")).sync().count == 1)
        }
    }

    @Test @MainActor func legacyAndTypedGatewaysExcludeEachOther() async throws {
        let directory = try adoptionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("Legacy.sqlite")
        let legacy = Graph(storeURL: legacyURL, migrationEnabled: false)
        #expect(legacy.isReady)
        do {
            let unexpected = try await GraphStore.open(at: legacyURL)
            try await unexpected.close()
            Issue.record("Expected legacy ownership rejection.")
        } catch GraphStoreError.ownershipConflict {}
        let typedURL = directory.appendingPathComponent("Typed.sqlite")
        let typed = try await GraphStore.open(at: typedURL)
        let rejected = Graph(storeURL: typedURL, migrationEnabled: false)
        #expect(!rejected.isReady)
        if case .failed(.runtimeOwnershipConflict) = rejected.readiness {} else { Issue.record("Expected ownership conflict.") }
        try await typed.close()
        let converted = Graph(storeURL: typedURL, migrationEnabled: false)
        if case .failed(.requiresV2Runtime) = converted.readiness {} else { Issue.record("Expected typed-store-only rejection.") }
        let reopened = try await GraphStore.open(at: typedURL)
        try await reopened.close()
        _ = legacy
    }

    @Test func corruptedPersistedIDsAreReportedInsteadOfRegenerated() async throws {
        let directory = try adoptionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let store = try await GraphStore.open(at: url)
        let record = try GraphRecord(id: store.makeNodeID(), type: "record")
        try await store.transaction { try $0.insert(record) }
        let handle = try await StoreRegistry.shared.open(.init(location: .sqlite(url)), schema: GraphRuntimeSchema.current)
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("record")).sync().first)
            node[dynamicMember: "__graphevo_v2.nodeID"] = "invalid"
        }
        await #expect(throws: GraphStoreError.self) { try await store.read { try $0.record(for: record.id) } }
        try await handle.close()
        try await store.close()
        await #expect(throws: GraphStoreError.self) { try await GraphStore.open(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistedDuplicateIDsAndUnknownEnvelopeVersionsFailVisibly() async throws {
        let directory = try adoptionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let store = try await GraphStore.open(at: url)
        let a = try GraphRecord(id: store.makeNodeID(), type: "A", properties: ["value": .string("kept")])
        let b = try GraphRecord(id: store.makeNodeID(), type: "B")
        try await store.transaction { scope in try scope.insert(a); try scope.insert(b) }
        let handle = try await StoreRegistry.shared.open(.init(location: .sqlite(url)), schema: GraphRuntimeSchema.current)
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("A")).sync().first)
            var envelope = try #require(node[dynamicMember: "value"] as? Data)
            let text = try #require(String(data: envelope, encoding: .utf8))
            envelope = Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8)
            node[dynamicMember: "value"] = envelope
        }
        await #expect(throws: (any Error).self) { try await store.read { try $0.record(for: a.id) } }
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("B")).sync().first)
            node[dynamicMember: "__graphevo_v2.nodeID"] = a.id.rawValue.uuidString
        }
        await #expect(throws: GraphStoreError.self) { try await store.read { try $0.record(for: b.id) } }
        try await handle.close()
        try await store.close()
    }
}
