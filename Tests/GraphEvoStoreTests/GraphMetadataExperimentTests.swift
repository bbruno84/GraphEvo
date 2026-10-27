import CoreData
import Foundation
import os
import Testing
@testable import GraphEvo

/// A unique test transformer records access to a foreign graph's poisoned metadata value.
/// Its only mutable state is locked; forwarding transformers are constructed per synchronous call.
private final class MetadataReadProbe: NSSecureUnarchiveFromDataTransformer, @unchecked Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    override func transformedValue(_ value: Any?) -> Any? {
        let result = GraphValueTransformer().transformedValue(value)
        if result as? String == "C02-poison" {
            reads.withLock { $0 += 1 }
            GraphValueDecodingDiagnostics.record(NSError(domain: "GraphMetadataExperiment.Poison", code: 7))
            return nil
        }
        return result
    }
    override func reverseTransformedValue(_ value: Any?) -> Any? {
        GraphValueTransformer().reverseTransformedValue(value)
    }
    var count: Int { reads.withLock { $0 } }
    func reset() { reads.withLock { $0 = 0 } }
}

@Suite(.timeLimit(.minutes(2))) struct GraphMetadataExperimentTests {
    @Test(arguments: [false, true]) func pendingChangesAcrossMetadataBatchesRetainEveryNodeKind(sqlite: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphMetadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await (sqlite ? GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite")) : GraphDatabase.inMemory())
        let graph = try await database.createGraph(), control = try await database.createGraph()
        let ids = (0..<129).map { _ in graph.makeNodeID() }, edge = graph.makeNodeID(), action = graph.makeNodeID()
        try await graph.transaction { scope in
            for id in ids { try scope.insert(GraphRecord(id: id, type: "metadata.item")) }
            try scope.insert(GraphRecord(id: edge, type: "metadata.edge", endpoints: .relationship(subject: ids[0], object: ids[128])))
            try scope.insert(GraphRecord(id: action, type: "metadata.action", endpoints: .action(subjects: [ids[0]], objects: [ids[128]])))
            _ = try scope.patch(GraphRecordPatch(id: ids[128], properties: ["new": .set(.null)], addingTags: ["changed"], addingGroups: ["group"]))
            #expect(try scope.record(for: ids[128])?.properties["new"] == .null)
            #expect(try scope.record(for: edge)?.endpoints == .relationship(subject: ids[0], object: ids[128]))
            #expect(try scope.record(for: action)?.endpoints == .action(subjects: [ids[0]], objects: [ids[128]]))
        }
        // The owners are now persisted. A later mutation scope still exposes pending format/property edits.
        try await graph.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: ids[128], properties: ["later": .set(.string("pending"))]))
            #expect(try scope.record(for: ids[128])?.properties["later"] == .string("pending"))
        }
        let peer = try await database.openGraph(graph.id)
        #expect(try await peer.read { try $0.record(for: ids[128])?.tags } == ["changed"])
        try await peer.delete(ids[128])
        #expect(try await graph.read { try $0.record(for: edge) } == nil)
        #expect(try await graph.read { try $0.record(for: action)?.endpoints } == .action(subjects: [ids[0]], objects: []))
        #expect(try await control.read { try $0.record(for: GraphNodeID(graphID: control.id, rawValue: ids[0].rawValue)) } == nil)
        try await peer.close(); try await graph.close(); try await control.close(); try await database.close()
    }

    @Test func independentSQLiteResourcesKeepMetadataAndMembershipSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataResources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        GraphValueTransformer.register()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.makeModel())
        let first = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent("First.sqlite"))
        let second = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent("Second.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let ids = [GraphID(), GraphID()]
        try await context.perform {
            let facade = GraphTypedStoreAdapter.facade(context)
            for (store, id) in zip(context.persistentStoreCoordinator!.persistentStores, ids) {
                let root = Entity(GraphTypedStoreAdapter.rootType, graph: facade)
                root[dynamicMember: GraphTypedStoreAdapter.graphKey] = id.rawValue.uuidString
                root[dynamicMember: GraphTypedStoreAdapter.layoutKey] = GraphTypedStoreAdapter.databaseVersion
                let member = Entity("item", graph: facade)
                GraphTypedStoreAdapter.stamp(member, id: GraphNodeID(graphID: id))
                member[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
                let membership = Action(GraphTypedStoreAdapter.membersType, graph: facade)
                membership[dynamicMember: GraphTypedStoreAdapter.graphKey] = id.rawValue.uuidString
                membership.add(subjects: root).add(objects: member)
                for node in [root as Node, member, membership] { try node.runtimeAssignOwnedObjects(to: store, in: context) }
            }
            try context.save(); context.reset()
            for id in ids {
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                #expect(session.nodes.count == 1)
                let member = try #require(session.nodes.first)
                #expect(try session.record(member.key)?.id.graphID == id)
            }
            context.reset()
        }
        try coordinator.remove(first); try coordinator.remove(second)
    }

    @Test func metadataCorruptionStillRejectsDuplicateMissingAndCrossGraphIdentity() async throws {
        let database = try await GraphDatabase.inMemory(), graph = try await database.createGraph()
        let a = graph.makeNodeID(), b = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: a, type: "A")); try scope.insert(GraphRecord(id: b, type: "B"))
        }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let target = try #require(session.nodes[b])
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = a.rawValue.uuidString
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = nil
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
                target[dynamicMember: GraphTypedStoreAdapter.idKey] = b.rawValue.uuidString
                target[dynamicMember: GraphTypedStoreAdapter.graphKey] = GraphID().rawValue.uuidString
                #expect(throws: GraphStoreError.self) { try GraphTypedStoreAdapter.Session(context, graph.id, database: true) }
            }
        }
        #expect(try await graph.read { try $0.record(for: b)?.id } == b)
        try await graph.close(); try await database.close()
    }

    @Test @MainActor func foreignMetadataDecodingFailuresDoNotContaminateTheSelectedGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataDecoder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transformer = MetadataReadProbe(), name = NSValueTransformerName("C02-\(UUID())")
        ValueTransformer.setValueTransformer(transformer, forName: name)
        defer { ValueTransformer.setValueTransformer(nil, forName: name) }
        let model = Model.makeModel()
        for entity in model.entities {
            if let object = entity.attributesByName["object"] { object.valueTransformerName = name.rawValue }
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: root.appendingPathComponent("Graph.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let ids = [GraphID(), GraphID()]
        try await context.perform {
            let facade = GraphTypedStoreAdapter.facade(context)
            for (index, id) in ids.enumerated() {
                let root = Entity(GraphTypedStoreAdapter.rootType, graph: facade)
                root[dynamicMember: GraphTypedStoreAdapter.graphKey] = id.rawValue.uuidString
                root[dynamicMember: GraphTypedStoreAdapter.layoutKey] = GraphTypedStoreAdapter.databaseVersion
                let member = Entity("item", graph: facade)
                GraphTypedStoreAdapter.stamp(member, id: GraphNodeID(graphID: id))
                member[dynamicMember: GraphTypedStoreAdapter.formatsKey] = index == 0 ? [String]() as Any : "C02-poison"
                let membership = Action(GraphTypedStoreAdapter.membersType, graph: facade)
                membership[dynamicMember: GraphTypedStoreAdapter.graphKey] = id.rawValue.uuidString
                membership.add(subjects: root).add(objects: member)
            }
            try context.save(); context.reset(); transformer.reset()
            #expect(try GraphTypedStoreAdapter.Session(context, ids[0], database: true).nodes.count == 1)
            #expect(transformer.count == 0)
            #expect(throws: (any Error).self) { try GraphTypedStoreAdapter.Session(context, ids[1], database: true) }
            #expect(transformer.count > 0)
            context.reset()
        }
        try coordinator.remove(store)
    }

    @Test func unrelatedGraphMalformedFormatsRemainIsolatedAndFreshReadsSeeRepairs() async throws {
        let database = try await GraphDatabase.inMemory(), a = try await database.createGraph(), b = try await database.createGraph()
        let first = a.makeNodeID(), second = b.makeNodeID()
        _ = try await a.transaction { try $0.insert(GraphRecord(id: first, type: "good")) }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: second, type: "other")) }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let session = try GraphTypedStoreAdapter.Session(context, b.id, database: true)
                let node = try #require(session.nodes[second])
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = "invalid"
                try context.save()
            }
        }
        #expect(try await a.read { try $0.record(for: first)?.id } == first)
        await #expect(throws: GraphStoreError.self) { try await b.read { try $0.record(for: second) } }
        try await database.nativeOperation { native in
            try await native.performBackgroundTask { context in
                defer { context.rollback(); context.reset() }
                let facade = GraphTypedStoreAdapter.facade(context)
                let node = try #require(GraphTypedStoreAdapter.allNodes(facade).first { $0.runtimeTypeIfPresent == "other" })
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = [String]()
                try context.save()
            }
        }
        #expect(try await b.read { try $0.record(for: second)?.id } == second)
        try await a.close(); try await b.close(); try await database.close()
    }
}
