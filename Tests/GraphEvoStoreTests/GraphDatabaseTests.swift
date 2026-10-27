import Foundation
import Testing
import GraphEvo

private struct CatalogItem: GraphModel {
    static let graphType = "catalog.item"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let label: String
    init(id: GraphNodeID, label: String) { self.id = id; self.label = label }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id; label = try graphRecord.value(for: "label")
    }
    func graphRecord() throws -> GraphRecord {
        try GraphRecord(id: id, type: Self.graphType, properties: ["label": label.graphValue])
    }
}

@Suite(.timeLimit(.minutes(1))) struct GraphDatabaseTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphDatabase-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func separateGraphsRetainIdentityAndIndependentLeasesThroughReopen() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Database.sqlite")
        let database = try await GraphDatabase.open(at: url)
        #expect(try await database.graphIDs().isEmpty)
        let a = try await database.createGraph(), b = try await database.createGraph()
        let first = CatalogItem(id: a.makeNodeID(), label: "A")
        let second = CatalogItem(id: b.makeNodeID(), label: "B")
        try await a.insert(first); try await b.insert(second)
        #expect(try await a.fetchAll(CatalogItem.self).map(\.label) == ["A"])
        #expect(try await b.fetchAll(CatalogItem.self).map(\.label) == ["B"])
        await #expect(throws: GraphStoreError.self) { try await a.fetch(second.id, as: CatalogItem.self) }
        try await database.close()
        let anotherA = try await GraphDatabase.open(at: url)
        let sibling = try await anotherA.openGraph(a.id)
        try await a.close()
        #expect(try await sibling.fetch(first.id, as: CatalogItem.self)?.label == "A")
        try await sibling.close(); try await anotherA.close(); try await b.close()
        let reopened = try await GraphDatabase.open(at: url)
        #expect(Set(try await reopened.graphIDs()) == [a.id, b.id])
        let recovered = try await reopened.openGraph(b.id)
        #expect(try await recovered.fetch(second.id, as: CatalogItem.self)?.label == "B")
        try await recovered.close(); try await reopened.close()
    }

    @Test func membershipSurvivesEmptyEndpointsCyclesPatchesAndDeletion() async throws {
        let database = try await GraphDatabase.inMemory()
        let graph = try await database.createGraph(), control = try await database.createGraph()
        let a = CatalogItem(id: graph.makeNodeID(), label: "A"), b = CatalogItem(id: graph.makeNodeID(), label: "B")
        let edge = try GraphRecord(id: graph.makeNodeID(), type: "edge", endpoints: .relationship(subject: nil, object: nil))
        let event = try GraphRecord(id: graph.makeNodeID(), type: "event", endpoints: .action(subjects: [], objects: []))
        try await graph.transaction { scope throws -> Void in
            try scope.insert(a); try scope.insert(b); try scope.insert(edge); try scope.insert(event)
            #expect(try scope.record(for: edge.id)?.endpoints == edge.endpoints)
            #expect(try scope.record(for: event.id)?.endpoints == event.endpoints)
            _ = try scope.patch(GraphRecordPatch(id: edge.id, endpoints: .relationship(subject: a.id, object: b.id)))
            _ = try scope.patch(GraphRecordPatch(id: event.id, endpoints: .action(subjects: [a.id, b.id], objects: [a.id])))
        }
        try await graph.delete(a.id)
        #expect(try await graph.read { try $0.record(for: edge.id) } == nil)
        #expect(try await graph.read { try $0.record(for: event.id)?.endpoints } == .action(subjects: [b.id], objects: []))
        try await graph.delete(b.id)
        #expect(try await graph.read { try $0.record(for: event.id)?.endpoints } == event.endpoints)
        #expect(try await control.fetchAll(CatalogItem.self).isEmpty)
        try await graph.close(); try await control.close(); try await database.close()
    }

    @Test func crossGraphReferencesAreRejectedBeforeMutation() async throws {
        let database = try await GraphDatabase.inMemory()
        let a = try await database.createGraph(), b = try await database.createGraph()
        let item = CatalogItem(id: a.makeNodeID(), label: "A")
        try await a.insert(item)
        await #expect(throws: GraphStoreError.self) { try await b.insert(item) }
        // Constructing the record also validates graph-aware endpoint ownership.
        #expect(throws: GraphModelError.self) {
            try GraphRecord(id: b.makeNodeID(), type: "edge", endpoints: .relationship(subject: item.id, object: nil))
        }
        #expect(try await b.fetchAll(CatalogItem.self).isEmpty)
        try await a.close(); try await b.close(); try await database.close()
    }

    @Test func explicitA3UpgradeBacksUpAndRetainsApplicationIDs() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Database.sqlite")
        let backup = directory.appendingPathComponent("Backups")
        let old = try await GraphStore.open(at: url)
        let item = CatalogItem(id: old.makeNodeID(), label: "A3")
        try await old.insert(item)
        let event = try GraphRecord(id: old.makeNodeID(), type: "event", endpoints: .action(subjects: [], objects: []))
        try await old.transaction { try $0.insert(event) }
        try await old.close()
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: url) }
        let database = try await GraphDatabase.upgradeLocalA3Store(at: url, backupRoot: backup)
        #expect(try await database.graphIDs() == [old.id])
        let graph = try await database.openGraph(old.id)
        #expect(try await graph.fetch(item.id, as: CatalogItem.self)?.label == "A3")
        #expect(try await graph.read { try $0.record(for: event.id)?.endpoints } == event.endpoints)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: backup.path)).isEmpty)
        try await graph.close(); try await database.close()
        await #expect(throws: GraphStoreError.self) { try await GraphStore.open(at: url) }
        let repeated = try await GraphDatabase.upgradeLocalA3Store(at: url, backupRoot: backup)
        #expect(try await repeated.graphIDs() == [old.id])
        try await repeated.close()
    }
    @Test func concurrentCatalogCreationAndClosedErrorsUsePublicContracts() async throws {
        let database = try await GraphDatabase.inMemory()
        let ids = try await withThrowingTaskGroup(of: GraphID.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let graph = try await database.createGraph()
                    try await graph.close()
                    return graph.id
                }
            }
            var ids = Set<GraphID>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        #expect(ids.count == 12)
        #expect(Set(try await database.graphIDs()) == ids)
        await #expect { try await database.openGraph(GraphID()) } throws: { error in
            if case GraphStoreError.missingGraph = error { return true }; return false
        }
        try await database.close()
        await #expect { try await database.graphIDs() } throws: { error in
            if case GraphStoreError.closed = error { return true }; return false
        }
    }

    @Test func aLocalResourceCannotPrepareOrInspectCloudBoundaries() async throws {
        let database = try await GraphDatabase.inMemory()
        let graph = try await database.createGraph()
        await #expect(throws: GraphMirroringError.self) { try await database.prepareMirroring(for: graph.id) }
        await #expect(throws: GraphMirroringError.self) { try await database.inspectMirroring(for: graph.id) }
        #expect(try await database.graphIDs() == [graph.id])
        try await graph.close(); try await database.close()
    }

    @Test func anUpgradeBackupFailurePreservesTheA3LayoutAndMissingSourcesStayMissing() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Database.sqlite")
        let original = try await GraphStore.open(at: url)
        let id = original.id
        try await original.close()
        let blocked = directory.appendingPathComponent("NotADirectory")
        try Data([1]).write(to: blocked)
        await #expect(throws: (any Error).self) { try await GraphDatabase.upgradeLocalA3Store(at: url, backupRoot: blocked) }
        let reopened = try await GraphStore.open(at: url)
        #expect(reopened.id == id)
        try await reopened.close()
        let missing = directory.appendingPathComponent("Missing.sqlite")
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.upgradeLocalA3Store(at: missing, backupRoot: blocked) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func removingReservedMetadataInsideACaughtPatchCannotDamageIdentity() async throws {
        let graph = try await GraphStore.inMemory()
        let item = CatalogItem(id: graph.makeNodeID(), label: "retained")
        try await graph.insert(item)
        try await graph.transaction { scope throws -> Void in
            for name in ["__graphevo_v2.graphID", "__graphevo_v2.nodeID", "__graphevo_v2.encodedKeys"] {
                let patch = try GraphRecordPatch(id: item.id, properties: [name: .remove])
                #expect(throws: GraphStoreError.self) { try scope.patch(patch) }
            }
        }
        #expect(try await graph.fetch(item.id, as: CatalogItem.self)?.label == "retained")
        try await graph.close()
    }

}
