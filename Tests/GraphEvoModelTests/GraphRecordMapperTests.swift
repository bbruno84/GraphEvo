import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime

@Suite struct GraphRecordMapperTests {
    @Test func partialPatchRoundTripsOnCurrentSQLiteWithoutLosingUnknownProperties() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphModel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Main.sqlite")))
        let registry = StoreRegistry()
        let handle = try await registry.open(configuration, schema: GraphRuntimeSchema.current)
        let id = GraphNodeID(graphID: GraphID())
        let original = try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = Entity("person.v1", graph: graph)
            node[dynamicMember: "name"] = "Ada"
            node[dynamicMember: "future"] = Data([0, 255, 12])
            node[dynamicMember: "deleted"] = "remove me"
            node.add(tags: "active")
            return try GraphRecordMapper.snapshot(node, id: id) { _ in
                throw GraphModelError.invalidRecord("Unexpected reference.")
            }
        }
        let patch = try GraphRecordPatch(id: id, properties: ["name": .set(.string("Grace")), "deleted": .remove],
                                         addingGroups: ["authors"])
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("person.v1")).sync().first)
            try GraphRecordMapper.apply(patch, to: node, id: id)
        }
        try await handle.close()
        let reopened = try await registry.open(configuration, schema: GraphRuntimeSchema.current)
        let saved = try await reopened.read { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("person.v1")).sync().first)
            return try GraphRecordMapper.snapshot(node, id: id) { _ in throw GraphModelError.invalidValue }
        }
        #expect(try saved == patch.applying(to: original))
        #expect(saved.properties["future"] == .data(Data([0, 255, 12])))
        try await reopened.close()
    }

    @Test func scalarBridgeDistinguishesBooleansFromIntegersAndRetainsBoundaries() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let id = GraphNodeID(graphID: GraphID())
        let properties: [String: GraphPropertyChange] = [
            "bool": .set(.boolean(true)), "int": .set(.integer(1)),
            "min": .set(.integer(.min)), "max": .set(.unsignedInteger(.max)),
            "double": .set(.floatingPoint(1.5)), "decimal": .set(.decimal(Decimal(string: "1234.56789")!)),
            "url": .set(.url(URL(string: "https://example.com")!)),
            "container": .set(.array([.string("value"), .object(["flag": .boolean(false)])]))
        ]
        let patch = try GraphRecordPatch(id: id, properties: properties)
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = Entity("numbers", graph: graph)
            try GraphRecordMapper.apply(patch, to: node, id: id)
        }
        let result = try await handle.read { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = try #require(Search<Entity>(graph: graph).where(.type("numbers")).sync().first)
            return try GraphRecordMapper.snapshot(node, id: id) { _ in throw GraphModelError.invalidValue }
        }
        for (key, change) in properties {
            if case .set(let value) = change { #expect(result.properties[key] == value, "Property: \(key)") }
        }
        try await handle.close()
    }

    @Test func unsupportedPatchFailsBeforeAnyEditEvenWhenCallerCatchesIt() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let id = GraphNodeID(graphID: GraphID())
        let opaque = try GraphEncodedValue(codec: "future", version: 2, data: Data([1, 2]))
        let patch = try GraphRecordPatch(id: id, properties: ["name": .set(.string("wrong")), "opaque": .set(.encoded(opaque))],
                                         addingTags: ["wrong"])
        let record = try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = Entity("person", graph: graph)
            node[dynamicMember: "name"] = "Ada"
            #expect(throws: GraphModelError.self) { try GraphRecordMapper.apply(patch, to: node, id: id) }
            return try GraphRecordMapper.snapshot(node, id: id) { _ in throw GraphModelError.invalidValue }
        }
        #expect(record.properties == ["name": .string("Ada")])
        #expect(record.tags.isEmpty)
        try await handle.close()
    }

    @Test func snapshotMapsRelationshipAndActionReferencesWithoutTraversing() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let graphID = GraphID()
        let authorID = GraphNodeID(graphID: graphID), noteID = GraphNodeID(graphID: graphID)
        let relationshipID = GraphNodeID(graphID: graphID), actionID = GraphNodeID(graphID: graphID)
        let records = try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let author = Entity("author", graph: graph), note = Entity("note", graph: graph)
            author.is(relationship: "writes").of(note)
            author.will(action: "reviews").add(objects: note)
            let edge = try #require(Search<Relationship>(graph: graph).where(.type("writes")).sync().first)
            let action = try #require(Search<Action>(graph: graph).where(.type("reviews")).sync().first)
            let identify: (Entity) throws -> GraphNodeID = { node in
                if node == author { return authorID }
                if node == note { return noteID }
                throw GraphModelError.identityMismatch
            }
            return [try GraphRecordMapper.snapshot(edge, id: relationshipID, referenceID: identify),
                    try GraphRecordMapper.snapshot(action, id: actionID, referenceID: identify)]
        }
        #expect(records[0].endpoints == .relationship(subject: authorID, object: noteID))
        #expect(records[1].endpoints == .action(subjects: [authorID], objects: [noteID]))
        try await handle.close()
    }

    @Test func nativeDecoderDiagnosticsCannotBecomeASuccessfulPartialSnapshot() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let graphID = GraphID()
        await #expect(throws: GraphArchiverError.self) {
            try await handle.transaction { context in
                let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
                let author = Entity("author", graph: graph), note = Entity("note", graph: graph)
                author.is(relationship: "writes").of(note)
                let edge = try #require(Search<Relationship>(graph: graph).where(.type("writes")).sync().first)
                return try GraphRecordMapper.snapshot(edge, id: .init(graphID: graphID)) { _ in
                    // Injection verifies propagation separately from native archive corruption tests.
                    GraphValueDecodingDiagnostics.record(GraphArchiverError.unsupported("Injected decoder failure."))
                    return .init(graphID: graphID)
                }
            }
        }
        try await handle.close()
    }

    @Test func explicitNullIsRejectedBeforeTheCandidateSchemaCanCollapseIt() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let id = GraphNodeID(graphID: GraphID())
        let patch = try GraphRecordPatch(id: id, properties: ["name": .set(.string("wrong")), "nullable": .set(.null)])
        let record = try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = Entity("person", graph: graph)
            node[dynamicMember: "name"] = "Ada"
            #expect(throws: GraphModelError.self) { try GraphRecordMapper.apply(patch, to: node, id: id) }
            return try GraphRecordMapper.snapshot(node, id: id) { _ in throw GraphModelError.invalidValue }
        }
        #expect(record.properties == ["name": .string("Ada")])
        try await handle.close()
    }

    @Test func legacyNullReadCannotMasqueradeAsAnAbsentProperty() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: GraphRuntimeSchema.current)
        let id = GraphNodeID(graphID: GraphID())
        try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let node = Entity("legacy", graph: graph)
            node[dynamicMember: "nullable"] = NSNull()
        }
        await #expect(throws: GraphModelError.self) {
            try await handle.read { context in
                let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
                let node = try #require(Search<Entity>(graph: graph).where(.type("legacy")).sync().first)
                return try GraphRecordMapper.snapshot(node, id: id) { _ in throw GraphModelError.invalidValue }
            }
        }
        try await handle.close()
    }
}
