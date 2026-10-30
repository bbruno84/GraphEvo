import CoreData
import CryptoKit
import Foundation
import Testing
import os
@testable import GraphEvo

/// Distinguishes actual native transformation from merely skipping typed envelope decoding.
private final class NativeAuditBodyProbe: NSSecureUnarchiveFromDataTransformer, @unchecked Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { reads.withLock { $0 } }
    func reset() { reads.withLock { $0 = 0 } }
    override func transformedValue(_ value: Any?) -> Any? {
        let result = GraphValueTransformer().transformedValue(value)
        if result as? String == "native-audit-body-poison" {
            reads.withLock { $0 += 1 }
            GraphValueDecodingDiagnostics.record(NSError(domain: "NativeIdentityAudit.Body", code: 1))
            return nil
        }
        return result
    }
    override func reverseTransformedValue(_ value: Any?) -> Any? { GraphValueTransformer().reverseTransformedValue(value) }
}

@Suite(.timeLimit(.minutes(2))) struct GraphNativeIdentityPrototypeTests {
    private struct Fixture: Sendable { let a: GraphID; let b: GraphID; let records: [GraphRecord]; let source: URL }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func seed(_ root: URL) async throws -> Fixture {
        let source = root.appendingPathComponent("Source/Graph.sqlite")
        let database = try await GraphDatabase.open(at: source), a = try await database.createGraph(), b = try await database.createGraph()
        let first = a.makeNodeID(), second = a.makeNodeID(), edge = a.makeNodeID(), action = a.makeNodeID(), foreign = GraphNodeID(graphID: b.id, rawValue: first.rawValue)
        let opaque = try GraphEncodedValue(codec: "future", version: 9, data: Data([0, 255]))
        try await a.transaction { scope in
            try scope.insert(GraphRecord(id: first, type: "item", properties: ["name": .string("original"), "nil": .null,
                "opaque": .encoded(opaque), "bytes": .data(Data([0, 255])), "uuid": .uuid(UUID())], tags: ["tag"], groups: ["group"], createdDate: Date(timeIntervalSince1970: 1_700_000_000)))
            try scope.insert(GraphRecord(id: second, type: "item"))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: first, object: second)))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [first], objects: [second])))
        }
        try await b.transaction { try $0.insert(GraphRecord(id: foreign, type: "foreign")) }
        let input = root.appendingPathComponent("input.bin"); try Data(repeating: 173, count: 512).write(to: input)
        let file = try await a.importAttachment(from: input, ownedBy: first)
        let records = try await a.read { scope in try [first, second, edge, action, file.id].map { try #require(try scope.record(for: $0)) } }
        try await a.close(); try await b.close(); try await database.close()
        return Fixture(a: a.id, b: b.id, records: records, source: source)
    }
    private func convert(_ root: URL, fixture: Fixture, indexed: Bool) async throws -> URL {
        let copy = root.appendingPathComponent("Copy")
        try await GraphStoreBackup.copyClosedDirectory(from: fixture.source.deletingLastPathComponent(), to: copy)
        let destination = root.appendingPathComponent("Candidate.sqlite")
        try await Task.detached { try GraphNativeIdentityPrototype.migrateCopy(from: copy.appendingPathComponent("Graph.sqlite"), to: destination, indexed: indexed) }.value
        return destination
    }
    private func open(_ url: URL, indexed: Bool) throws -> NSPersistentContainer {
        GraphValueTransformer.register()
        let container = NSPersistentContainer(name: "IdentityPrototype", managedObjectModel: GraphNativeIdentityPrototype.makeModel(indexed: indexed))
        _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: false, NSInferMappingModelAutomaticallyOption: false])
        return container
    }
    private func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }

    @Test func defaultModelIsUnchangedAndNativeColumnsAreOptionalWithNoUniquenessConstraint() {
        let hashes = Model.makeModel().entityVersionHashesByName
        let prototype = GraphNativeIdentityPrototype.makeModel(indexed: true)
        #expect(prototype.entityVersionHashesByName != hashes)
        #expect(Model.makeModel().entityVersionHashesByName == hashes)
        for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
            let entity = prototype.entitiesByName[name]!
            #expect(entity.attributesByName[GraphNativeIdentityPrototype.graphAttribute]?.isOptional == true)
            #expect(entity.attributesByName[GraphNativeIdentityPrototype.nodeAttribute]?.isOptional == true)
            #expect(entity.indexes.count == 1 && entity.uniquenessConstraints.isEmpty)
        }
    }

    @Test(arguments: [false, true]) @MainActor func explicitConversionBackfillPreservesAllRecordsAndSource(indexed: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root), before = SHA256.hash(data: try Data(contentsOf: fixture.source))
        let destination = try await convert(root, fixture: fixture, indexed: indexed)
        #expect(SHA256.hash(data: try Data(contentsOf: fixture.source)) == before)
        let container = try open(destination, indexed: indexed)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: fixture.records[0].id) }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            // A targeted hit is valid, but the unconverted second graph prevents resource-wide absence readiness.
            #expect(try GraphNativeIdentityPrototype.record(context, id: fixture.records[0].id) == fixture.records[0])
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: GraphNodeID(graphID: fixture.a)) }
            context.rollback()
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: fixture.records[0].id) }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b)
            try context.save(); context.reset()
            for expected in fixture.records { #expect(try GraphNativeIdentityPrototype.record(context, id: expected.id) == expected) }
            #expect(try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) == 5)
            #expect(try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.b) == 1)
            #expect(try GraphNativeIdentityPrototype.record(context, id: GraphNodeID(graphID: fixture.b, rawValue: fixture.records[0].id.rawValue))?.type == "foreign")
            #expect(try GraphNativeIdentityPrototype.record(context, id: GraphNodeID(graphID: fixture.a)) == nil)
            #expect(!context.hasChanges)
        }
        try close(container)
        let original = try await GraphDatabase.open(at: fixture.source), graph = try await original.openGraph(fixture.a)
        #expect(try await graph.read { try $0.record(for: fixture.records[0].id) } == fixture.records[0])
        try await graph.close(); try await original.close()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: destination)
        #expect(!Model.makeModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
    }

    @Test @MainActor func pendingPatchesInsertsDeletesAndRollbackPreserveLocalViewAndUnknownFields() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root), destination = try await convert(root, fixture: fixture, indexed: true)
        let container = try open(destination, indexed: true)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b); try context.save()
            let original = fixture.records[0]
            let patch = try GraphRecordPatch(id: original.id, properties: ["name": .set(.string("updated")), "added": .set(.null)])
            #expect(try GraphNativeIdentityPrototype.patch(context, patch) == patch.applying(to: original))
            #expect(try GraphNativeIdentityPrototype.record(context, id: original.id)?.properties["opaque"] == original.properties["opaque"])
            let newID = GraphNodeID(graphID: fixture.a)
            try GraphNativeIdentityPrototype.insert(context, GraphRecord(id: newID, type: "pending"))
            let session = try GraphTypedStoreAdapter.Session(context, fixture.a, database: true)
            let nativeID = try #require(session.nodes[newID]?.runtimeObjectID)
            #expect(try GraphNativeIdentityPrototype.record(context, id: newID)?.id == newID)
            #expect(session.nodes[newID]?.runtimeObjectID == nativeID)
            try session.delete(newID)
            #expect(try GraphNativeIdentityPrototype.record(context, id: newID) == nil)
            context.rollback()
            #expect(try GraphNativeIdentityPrototype.record(context, id: original.id) == original)
            #expect(try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) == 5)
        }
        try close(container)
    }

    @Test @MainActor func batchedActionReferencesPreserveEndpointsAndRejectPendingDuplicateOrMissingIdentity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root)
        let database = try await GraphDatabase.open(at: fixture.source), graph = try await database.openGraph(fixture.a)
        let ids = (0..<130).map { _ in graph.makeNodeID() }, actionID = graph.makeNodeID()
        let expected = try GraphRecord(id: actionID, type: "wide", endpoints: .action(subjects: Set(ids), objects: Set(ids)), createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        try await graph.transaction { scope in
            for id in ids { try scope.insert(GraphRecord(id: id, type: "endpoint")) }
            try scope.insert(expected)
        }
        try await graph.close(); try await database.close()
        let destination = try await convert(root, fixture: fixture, indexed: true), container = try open(destination, indexed: true)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b); try context.save(); context.reset()
            #expect(try GraphNativeIdentityPrototype.record(context, id: actionID) == expected)
            let session = try GraphTypedStoreAdapter.Session(context, fixture.a, database: true)
            let endpoint = try #require(session.nodes[ids[129]])
            let otherAction = try #require(session.nodes[fixture.records[3].id])
            try otherAction.setPrototypeIdentity(ids[129])
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: actionID) }
            context.rollback()
            try endpoint.setPrototypeIdentity(nil)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: actionID) }
            context.rollback()
            endpoint[dynamicMember: GraphTypedStoreAdapter.stageKey] = UUID().uuidString
            #expect(endpoint[dynamicMember: GraphTypedStoreAdapter.stageKey] != nil)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: actionID) }
            context.rollback()
            endpoint[dynamicMember: GraphTypedStoreAdapter.graphKey] = fixture.b.rawValue.uuidString
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: actionID) }
            context.rollback()
            #expect(try GraphNativeIdentityPrototype.record(context, id: actionID) == expected)
            #expect(!context.hasChanges)
        }
        try close(container)
    }

    @Test @MainActor func identityAuditDoesNotTransformNativeApplicationBodiesAndRequestedReadsStillFail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        GraphValueTransformer.register()
        let transformer = NativeAuditBodyProbe(), name = NSValueTransformerName("NativeAudit-\(UUID())")
        ValueTransformer.setValueTransformer(transformer, forName: name)
        defer { ValueTransformer.setValueTransformer(nil, forName: name) }
        let model = GraphNativeIdentityPrototype.makeModel(indexed: true)
        for entity in model.entities { entity.attributesByName["object"]?.valueTransformerName = name.rawValue }
        let container = NSPersistentContainer(name: "NativeAudit", managedObjectModel: model)
        _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent("Probe.sqlite"))
        let graph = GraphID(), id = GraphNodeID(graphID: graph), missing = GraphNodeID(graphID: graph)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphTypedStoreAdapter.database.create(context, graph)
            try GraphNativeIdentityPrototype.backfill(context, graphID: graph)
            try GraphNativeIdentityPrototype.insert(context, GraphRecord(id: id, type: "poison", properties: ["body": .string("valid")]))
            let session = try GraphTypedStoreAdapter.Session(context, graph, database: true)
            let node = try #require(session.nodes[id])
            node[dynamicMember: "body"] = "native-audit-body-poison"
            try context.save(); context.reset(); transformer.reset()
            #expect(try GraphNativeIdentityPrototype.validateIdentityInventory(context, graphID: graph) == 1)
            #expect(try GraphNativeIdentityPrototype.record(context, id: missing) == nil)
            #expect(transformer.count == 0)
            #expect(throws: (any Error).self) { try GraphNativeIdentityPrototype.record(context, id: id) }
            #expect(transformer.count > 0)
        }
        try close(container)
    }

    @Test @MainActor func missingReadsAuditColumnsWithoutDecodingUnrelatedApplicationBodies() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root), destination = try await convert(root, fixture: fixture, indexed: true)
        let container = try open(destination, indexed: true)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b); try context.save(); context.reset()
            let owner = fixture.records[0].id, missing = GraphNodeID(graphID: fixture.a)
            let session = try GraphTypedStoreAdapter.Session(context, fixture.a, database: true)
            let node = try #require(session.nodes[owner])
            node[dynamicMember: "name"] = Data([0])
            #expect(try GraphNativeIdentityPrototype.validateIdentityInventory(context, graphID: fixture.a) == 5)
            #expect(try GraphNativeIdentityPrototype.record(context, id: missing) == nil)
            #expect(throws: (any Error).self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            #expect(throws: (any Error).self) { try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) }
            context.rollback()
            for key in [GraphNativeIdentityPrototype.graphAttribute, GraphNativeIdentityPrototype.nodeAttribute] {
                node.node.setValue(nil, forKey: key)
                #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
                #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: missing) }
                context.rollback()
            }
            try node.setPrototypeIdentity(GraphNodeID(graphID: fixture.b))
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            context.rollback()
            node.node.setValue(GraphNodeID(graphID: fixture.a).rawValue.uuidString, forKey: GraphNativeIdentityPrototype.nodeAttribute)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            context.rollback()
            #expect(try GraphNativeIdentityPrototype.record(context, id: missing) == nil)
            #expect(!context.hasChanges)
        }
        try close(container)
    }

    @Test @MainActor func unassignedStagedRowsPreventAbsenceWithoutAutomaticRepairOrActivation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root), destination = try await convert(root, fixture: fixture, indexed: true)
        let container = try open(destination, indexed: true)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b); try context.save()
            let facade = GraphTypedStoreAdapter.facade(context), id = GraphNodeID(graphID: fixture.a)
            let staged = Entity("partial", graph: facade)
            staged[dynamicMember: GraphTypedStoreAdapter.idKey] = id.rawValue.uuidString
            staged[dynamicMember: GraphTypedStoreAdapter.graphKey] = id.graphID.rawValue.uuidString
            staged[dynamicMember: GraphTypedStoreAdapter.stageKey] = UUID().uuidString
            staged[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
            let session = try GraphTypedStoreAdapter.Session(context, fixture.a, database: true)
            #expect(session.stagedNodeIDs == [id])
            do {
                _ = try GraphNativeIdentityPrototype.record(context, id: id)
                Issue.record("A staged logical row must not be reported as absent.")
            } catch GraphStoreError.pendingNativeOperation {}
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.validateIdentityInventory(context, graphID: fixture.a) }
            #expect(staged.node.value(forKey: GraphNativeIdentityPrototype.nodeAttribute) == nil)
            #expect(context.hasChanges)
            context.rollback()
            #expect(try GraphNativeIdentityPrototype.record(context, id: id) == nil)
            #expect(!context.hasChanges)
            let unrouted = Entity("unrouted", graph: facade)
            unrouted[dynamicMember: GraphTypedStoreAdapter.idKey] = id.rawValue.uuidString
            unrouted[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
            // Both routing projections are absent, so a per-graph-only audit would miss this row.
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: id) }
            #expect(unrouted[dynamicMember: GraphTypedStoreAdapter.graphKey] == nil)
            #expect(unrouted.node.value(forKey: GraphNativeIdentityPrototype.graphAttribute) == nil)
            context.rollback()
            #expect(try GraphNativeIdentityPrototype.record(context, id: id) == nil)
            #expect(!context.hasChanges)
        }
        try close(container)
    }

    @Test @MainActor func duplicateColumnsMissingColumnsForeignEndpointsAndGlobalValidationAreVisible() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await seed(root), destination = try await convert(root, fixture: fixture, indexed: true)
        let container = try open(destination, indexed: true)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.a)
            try GraphNativeIdentityPrototype.backfill(context, graphID: fixture.b); try context.save()
            let owner = fixture.records[0].id, edgeID = fixture.records[2].id
            let facade = GraphTypedStoreAdapter.facade(context)
            let foreign = try #require(Search<Entity>(graph: facade).where(.type("foreign")).sync().first)
            let edge = try #require(Search<Relationship>(graph: facade).where(.type("edge")).sync().first)
            edge.object = foreign
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: edgeID) }
            context.rollback()
            let session = try GraphTypedStoreAdapter.Session(context, fixture.a, database: true)
            let node = try #require(session.nodes[owner])
            let action = try #require(session.nodes[fixture.records[3].id])
            try action.setPrototypeIdentity(owner)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            context.rollback()
            try node.setPrototypeIdentity(nil)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) }
            context.rollback()
            node[dynamicMember: GraphTypedStoreAdapter.idKey] = UUID().uuidString
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.record(context, id: owner) }
            // The file's missing owner or the mismatched column may be visited first.
            #expect(throws: (any Error).self) { try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) }
            context.rollback()
            // Unrelated raw identity damage remains an explicit full-validation responsibility.
            let other = try #require(GraphTypedStoreAdapter.Session(context, fixture.a, database: true).nodes[fixture.records[1].id])
            other[dynamicMember: GraphTypedStoreAdapter.idKey] = owner.rawValue.uuidString
            #expect(try GraphNativeIdentityPrototype.record(context, id: owner)?.id == owner)
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityPrototype.validateAll(context, graphID: fixture.a) }
        }
        try close(container)
    }
}

extension GraphNativeIdentityPrototypeTests {
    @Test func laboratoryAdapterRetainsRuntimeLeasesSerializedWritesAndRollback() async throws {
        struct Abort: Error {}
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try await GraphNativeIdentityPrototype.openLab(at: root.appendingPathComponent("Graph.sqlite"), indexed: true)
        let graph = try await database.createGraph(), sibling = try await database.openGraph(graph.id), id = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: id, type: "live", properties: ["counter": .integer(0), "unknown": .string("retain")]))
            #expect(try scope.record(for: id)?.id == id)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await sibling.transaction { scope in
                        guard let record = try scope.record(for: id), case .integer(let count) = record.properties["counter"] else { throw Abort() }
                        _ = try scope.patch(GraphRecordPatch(id: id, properties: ["counter": .set(.integer(count + 1))]))
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await graph.read { try $0.record(for: id)?.properties["counter"] } == .integer(8))
        await #expect(throws: Abort.self) {
            try await graph.transaction { scope throws -> Void in
                _ = try scope.patch(GraphRecordPatch(id: id, properties: ["unknown": .remove])); throw Abort()
            }
        }
        #expect(try await graph.read { try $0.record(for: id)?.properties["unknown"] } == .string("retain"))
        try await graph.close(); try await database.close()
        #expect(try await sibling.read { try $0.record(for: id)?.id } == id)
        await #expect(throws: (any Error).self) { try await GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite")) }
        try await sibling.close()
        await #expect(throws: GraphStoreError.self) { try await GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite")) }
    }
}

extension GraphNativeIdentityPrototypeTests {
    @Test func commonWriterMaintainsEveryKindFilesRollbackCascadeAndReopen() async throws {
        struct Abort: Error {}
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Writer.sqlite")
        let database = try await GraphNativeIdentityPrototype.openLab(at: url, indexed: true, fullAdapter: true)
        let graph = try await database.createGraph(), other = try await database.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID(), edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "item", properties: ["value": .null]))
            try scope.insert(GraphRecord(id: b, type: "item"))
            try scope.insert(GraphRecord(id: edge, type: "edge", endpoints: .relationship(subject: a, object: b)))
            try scope.insert(GraphRecord(id: action, type: "action", endpoints: .action(subjects: [a], objects: [b])))
            #expect(try scope.record(for: edge)?.endpoints == .relationship(subject: a, object: b))
        }
        let input = root.appendingPathComponent("input.bin"); try Data([1,2,3]).write(to: input)
        let file = try await graph.importAttachment(from: input, ownedBy: edge)
        try Data([4,5,6,7]).write(to: input)
        let replaced = try await graph.replaceAttachment(file.id, from: input)
        #expect(replaced.id == file.id && replaced.ownerID == edge)
        #expect(try await graph.attachment(file.id)?.data == Data([4,5,6,7]))
        _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: a, properties: ["value": .set(.integer(9))])) }
        try await database.contextRead { context throws -> Void in
            #expect(try GraphNativeIdentityPrototype.validateAll(context, graphID: graph.id) == 5)
            #expect(try GraphNativeIdentityPrototype.validateIdentityInventory(context, graphID: other.id) == 0)
        }
        let aborted = graph.makeNodeID()
        await #expect(throws: Abort.self) {
            try await graph.transaction { scope throws -> Void in
                try scope.insert(GraphRecord(id: aborted, type: "abort"))
                #expect(try scope.record(for: aborted)?.id == aborted)
                throw Abort()
            }
        }
        #expect(try await graph.read { try $0.record(for: aborted) } == nil)
        try await graph.delete(a)
        #expect(try await graph.attachment(file.id) == nil)
        #expect(try await graph.read { try $0.record(for: edge) } == nil)
        #expect(try await graph.read { try $0.record(for: action)?.endpoints } == .action(subjects: [], objects: [b]))
        try await graph.close(); try await other.close(); try await database.close()
        let reopened = try await GraphNativeIdentityPrototype.openLab(at: url, indexed: true, fullAdapter: true)
        let reader = try await reopened.openGraph(graph.id)
        #expect(try await reader.read { try $0.record(for: b)?.id } == b)
        try await reopened.contextRead { context throws -> Void in
            #expect(try GraphNativeIdentityPrototype.validateAll(context, graphID: graph.id) == 2)
            #expect(try GraphNativeIdentityPrototype.record(context, id: file.id) == nil)
        }
        try await reader.close(); try await reopened.close()
    }

    @Test func commonWriterRejectsDamagedExistingProjectionWithoutRepairingOrEditingPayload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try await GraphNativeIdentityPrototype.openLab(at: root.appendingPathComponent("Writer.sqlite"), indexed: true, fullAdapter: true)
        let graph = try await database.createGraph(), id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "item", properties: ["name": .string("keep")])) }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(session.nodes[id])
                node.node.setValue(nil, forKey: GraphNativeIdentityPrototype.nodeAttribute)
                #expect(throws: GraphStoreError.self) { try GraphNativeIdentityColumns.stamp(node, graphID: graph.id, nodeID: id.rawValue) }
                #expect(throws: GraphStoreError.self) { try session.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("bad"))])) }
                #expect(throws: GraphStoreError.self) { try session.delete(id) }
                #expect(node.node.value(forKey: GraphNativeIdentityPrototype.nodeAttribute) == nil)
                let bytes = try #require(node[dynamicMember: "name"] as? Data)
                #expect(try GraphValueCodec.decode(bytes) == .string("keep"))
            }
        }
        #expect(try await graph.read { try $0.record(for: id)?.properties["name"] } == .string("keep"))
        let stagedID = graph.makeNodeID()
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                // Simulate a framework import with logical staging metadata but incomplete native columns.
                let staged = Entity("writer.partialImport", graph: GraphTypedStoreAdapter.facade(context))
                staged[dynamicMember: GraphTypedStoreAdapter.graphKey] = graph.id.rawValue.uuidString
                staged[dynamicMember: GraphTypedStoreAdapter.idKey] = stagedID.rawValue.uuidString
                staged[dynamicMember: GraphTypedStoreAdapter.stageKey] = UUID().uuidString
                staged[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
                try context.save()
            }
        }
        await #expect(throws: GraphStoreError.self) { try await graph.read { try $0.record(for: stagedID) } }
        await #expect(throws: GraphStoreError.self) {
            try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("bad"))])) }
        }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.reset() }
                let graph = GraphTypedStoreAdapter.facade(context)
                for node in Search<Entity>(graph: graph).where(.type("writer.partialImport")).sync() { node.delete() }
                try context.save()
            }
        }
        #expect(try await graph.read { try $0.record(for: stagedID) } == nil)
        #expect(try await graph.read { try $0.record(for: id)?.properties["name"] } == .string("keep"))
        try await graph.close(); try await database.close()
    }

    @Test @MainActor func partialProjectionModelIsRejectedBeforeControlCreationOrLogicalStamping() async throws {
        let model = Model.makeModel()
        let attribute = NSAttributeDescription()
        attribute.name = GraphNativeIdentityPrototype.graphAttribute
        attribute.attributeType = .stringAttributeType; attribute.isOptional = true
        model.entitiesByName[ModelIdentifier.entityName]!.properties.append(attribute)
        let container = NSPersistentContainer(name: "IncompleteProjection", managedObjectModel: model)
        _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let graph = GraphID(), id = GraphNodeID(graphID: graph)
        try await container.performBackgroundTask { @Sendable context in
            defer { context.rollback(); context.reset() }
            #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.database.create(context, graph) }
            #expect(!context.hasChanges)
            let node = Entity("item", graph: GraphTypedStoreAdapter.facade(context))
            #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.stamp(node, id: id) }
            #expect(node[dynamicMember: GraphTypedStoreAdapter.idKey] == nil)
            #expect(node[dynamicMember: GraphTypedStoreAdapter.graphKey] == nil)
        }
        try close(container)
    }
}
