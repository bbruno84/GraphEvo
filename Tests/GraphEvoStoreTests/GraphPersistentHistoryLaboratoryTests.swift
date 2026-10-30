import CoreData
import Foundation
import Testing
@testable import GraphEvo
import GraphEvoRuntime

private typealias PH01 = GraphPersistentHistoryLaboratory

@Suite(.timeLimit(.minutes(2))) struct GraphPersistentHistoryLaboratoryTests {
    private struct Fixture {
        let directory: URL; let url: URL; let database: GraphDatabase; let graph: GraphStore
        let a: GraphNodeID; let b: GraphNodeID; let edge: GraphNodeID; let action: GraphNodeID
    }
    private func fixture(preserved: Bool = true) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-PH01-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("graph.sqlite")
        let database = try await (preserved ? PH01.open(at: url) : GraphDatabase.open(at: url, schema: .nativeIdentity))
        let graph = try await database.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction {
            try $0.insert(GraphRecord(id: a, type: ObservedItem.graphType, properties: ["value": .integer(1)], tags: ["initial"], groups: ["initial"]))
            try $0.insert(GraphRecord(id: b, type: "child"))
            try $0.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)))
            try $0.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b])))
        }
        return Fixture(directory: directory, url: url, database: database, graph: graph, a: a, b: b, edge: edge, action: action)
    }
    private func close(_ f: Fixture) async throws { try await f.graph.close(); try await f.database.close() }

    @Test func laboratoryChangesOnlyIdentityPreservationAndRemainsRefusedByNormalOpeners() async throws {
        let original = GraphRuntimeSchema.makeNativeModel(), preserved = PH01.model()
        #expect(original.entityVersionHashesByName != preserved.entityVersionHashesByName)
        #expect(original.entities.count == preserved.entities.count)
        for entity in original.entities {
            let other = try #require(preserved.entitiesByName[entity.name!])
            #expect(entity.properties.map(\.name) == other.properties.map(\.name))
        }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await close(f)
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: f.url, schema: .nativeIdentity) }
    }

    @Test func baselineS02DoesNotProvideDeletedLogicalIdentity() async throws {
        let f = try await fixture(preserved: false); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        try await f.graph.delete(f.edge)
        let history = try await PH01.history(f.database, after: checkpoint)
        let deletion = try #require(history.transactions.flatMap(\.changes).first { $0.entity == "ManagedRelationship" && $0.operation == 2 })
        #expect(deletion.preservedGraph == nil && deletion.preservedNode == nil)
        #expect(throws: PH01.Failure.self) { try PH01.candidates(history) }
        try await close(f)
    }

    @Test(arguments: ["property", "remove-property", "add-tag", "remove-tag", "add-group", "remove-group", "edge", "action"])
    func realModelDetailsAndTopologyReachTheCorrectRecord(_ operation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        let target = operation == "edge" ? f.edge : (operation == "action" ? f.action : f.a)
        let patch: GraphRecordPatch
        switch operation {
        case "property": patch = try GraphRecordPatch(id: target, properties: ["value": .set(.integer(2))])
        case "remove-property": patch = try GraphRecordPatch(id: target, properties: ["value": .remove])
        case "add-tag": patch = try GraphRecordPatch(id: target, addingTags: ["added"])
        case "remove-tag": patch = try GraphRecordPatch(id: target, removingTags: ["initial"])
        case "add-group": patch = try GraphRecordPatch(id: target, addingGroups: ["added"])
        case "remove-group": patch = try GraphRecordPatch(id: target, removingGroups: ["initial"])
        case "edge": patch = try GraphRecordPatch(id: target, endpoints: .relationship(subject: f.b, object: f.a))
        default: patch = try GraphRecordPatch(id: target, endpoints: .action(subjects: [f.b], objects: [f.a]))
        }
        try await f.graph.transaction { _ = try $0.patch(patch) }
        let history = try await PH01.history(f.database, after: checkpoint)
        #expect(try PH01.candidates(history)[target] == .save)
        if operation == "property" {
            #expect(history.transactions.flatMap(\.changes).contains { $0.entity == "ManagedEntityProperty" && $0.owner == f.a })
        }
        if operation == "remove-property" {
            #expect(history.transactions.flatMap(\.changes).contains { $0.id == f.a && $0.properties.contains("propertySet") })
        }
        try await close(f)
    }

    @Test(arguments: [false, true]) func delayedDetailAndOwnerDeletionStillYieldTheFinalIntent(_ deleteOwner: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(2))])) }
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .remove])) }
        if deleteOwner { try await f.graph.delete(f.a) }
        let history = try await PH01.history(f.database, after: checkpoint), candidates = try PH01.candidates(history)
        #expect(candidates[f.a] == (deleteOwner ? .delete : .save))
        if deleteOwner {
            #expect(candidates[f.edge] == .delete)
            #expect(candidates[f.action] == .save)
            #expect(history.transactions.flatMap(\.changes).contains { $0.preservedNode == f.a.rawValue.uuidString })
            #expect(try await f.graph.read { try $0.record(for: f.action)?.endpoints } == .action(subjects: [], objects: [f.b]))
        }
        try await close(f)
    }

    @Test func cascadedAttachmentsAndSurvivingActionsRemainDiscoverable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let source = f.directory.appendingPathComponent("source.bin"); try Data([1, 2, 3]).write(to: source)
        let fileA = try await f.graph.importAttachment(from: source, ownedBy: f.a)
        let fileEdge = try await f.graph.importAttachment(from: source, ownedBy: f.edge)
        let checkpoint = try await PH01.history(f.database).token
        try await f.graph.delete(f.a)
        let candidates = try PH01.candidates(await PH01.history(f.database, after: checkpoint))
        for id in [f.a, f.edge, fileA.id, fileEdge.id] { #expect(candidates[id] == .delete) }
        #expect(candidates[f.action] == .save)
        try await close(f)
    }

    @Test func tokenPersistsAcrossReopenAndCheckpointReplayIsDeterministic() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let baseline = try await PH01.history(f.database), token = try #require(baseline.token)
        let tokenFile = f.directory.appendingPathComponent("checkpoint.bin"); try token.write(to: tokenFile, options: .atomic)
        try await f.graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(2))])) }
        try await f.graph.delete(f.edge)
        let beforeCrash = try await PH01.history(f.database, after: token)
        let expected = try PH01.candidates(beforeCrash)
        try await close(f)
        let reopened = try await PH01.open(at: f.url)
        let replay = try await PH01.history(reopened, after: Data(contentsOf: tokenFile))
        #expect(replay.storeID == baseline.storeID)
        #expect(try PH01.candidates(replay) == expected)
        #expect(replay.transactions.map(\.number) == beforeCrash.transactions.map(\.number))
        let saved = try #require(replay.token); try saved.write(to: tokenFile, options: .atomic)
        #expect(try await PH01.history(reopened, after: Data(contentsOf: tokenFile)).transactions.isEmpty)
        try await reopened.close()
    }

    @Test func importsAreObservableButExcludedAndSubsequentLocalEditsAreIncluded() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        let observation = try await f.graph.observe(observationQuery())
        _ = try await waitForObservation(observation) { $0.items.first?.record.properties["value"] == .integer(1) }
        try await PH01.importPatch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(20))]), into: f.database)
        _ = try await waitForObservation(observation) { $0.items.first?.record.properties["value"] == .integer(20) }
        let imported = try await PH01.history(f.database, after: checkpoint)
        #expect(imported.transactions.allSatisfy { $0.author == PH01.importAuthor })
        #expect(try PH01.candidates(imported).isEmpty)
        observation.cancel(); try await close(f)
        let reopened = try await PH01.open(at: f.url), graph = try await reopened.openGraph(f.graph.id)
        #expect(try PH01.candidates(await PH01.history(reopened, after: checkpoint)).isEmpty)
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(21))])) }
        #expect(try PH01.candidates(await PH01.history(reopened, after: checkpoint))[f.a] == .save)
        try await graph.close(); try await reopened.close()
    }

    @Test func insertDeleteAndRecreateBeforeCollectionRetainTheFinalIntent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        let id = f.graph.makeNodeID()
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "rapid")) }
        try await f.graph.delete(id)
        #expect(try PH01.candidates(await PH01.history(f.database, after: checkpoint))[id] == .delete)
        _ = try await f.graph.transaction { try $0.insert(GraphRecord(id: id, type: "rapid", properties: ["value": .integer(2)])) }
        #expect(try PH01.candidates(await PH01.history(f.database, after: checkpoint))[id] == .save)
        try await close(f)
    }

    @Test func replacementKeepsTheAttachmentIdentityDiscoverable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let source = f.directory.appendingPathComponent("source.bin"); try Data([1, 2, 3]).write(to: source)
        let file = try await f.graph.importAttachment(from: source, ownedBy: f.a)
        let checkpoint = try await PH01.history(f.database).token
        try Data([4, 5, 6, 7]).write(to: source)
        let replacement = try await f.graph.replaceAttachment(file.id, from: source)
        #expect(replacement.id == file.id)
        #expect(try PH01.candidates(await PH01.history(f.database, after: checkpoint))[file.id] == .save)
        try await close(f)
    }

    @Test func actionDeletionPreservesItsIdentity() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        try await f.graph.delete(f.action)
        #expect(try PH01.candidates(await PH01.history(f.database, after: checkpoint))[f.action] == .delete)
        try await close(f)
    }

    @Test func rolledBackMutationsDoNotAppearInHistory() async throws {
        struct Abort: Error {}
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let checkpoint = try await PH01.history(f.database).token
        await #expect(throws: Abort.self) {
            try await f.graph.transaction {
                _ = try $0.patch(GraphRecordPatch(id: f.a, properties: ["value": .set(.integer(99))]))
                throw Abort()
            }
        }
        #expect(try await PH01.history(f.database, after: checkpoint).transactions.isEmpty)
        try await close(f)
    }
}
