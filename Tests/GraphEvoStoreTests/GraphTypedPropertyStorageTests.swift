import Foundation
import CoreData
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime
import GraphEvoStore

@Suite(.timeLimit(.minutes(2))) struct GraphTypedPropertyStorageTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S04-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func manager() -> GraphContextManager {
        .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
    }
    private func corpus() -> [String: GraphValue] {
        ["null": .null, "bool": .boolean(true), "int": .integer(.min), "uint": .unsignedInteger(.max),
         "double": .floatingPoint(.leastNonzeroMagnitude), "negativeZero": .floatingPoint(-0.0),
         "decimal": .decimal(Decimal(string: "12345678901234567890.123456789012345678")!),
         "string": .string("e\u{301}🙂"), "nul": .string("a\u{0}b"), "literal\u{0}key": .integer(7),
         "bytes": .string(Data(repeating: 91, count: 2 * 1024 * 1024).base64EncodedString()), "date": .date(Date(timeIntervalSince1970: -123.25)),
         "uuid": .uuid(UUID()), "url": .url(URL(string: "https://example.invalid/a%20b")!),
         "relativeURL": .url(URL(string: "../relative%20path")!),
         "basedURL": .url(URL(string: "child", relativeTo: URL(string: "https://example.invalid/base/")!)!),
         "array": .array([.integer(4), .null]), "object": .object(["key": .boolean(false)]),
         "encoded": .object(["opaque": .string("AP8=")])]
    }
    @Test func allKindsReopenWithOneAuthoritativeSlotAndNativePH() async throws {
        let root = try directory(), m = manager(), id = GraphID(), url = root.appendingPathComponent("Store.sqlite")
        let graph = try await m.createGraph(id: id, at: url), node = graph.makeNodeID(), values = corpus()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "S04.Item", properties: values)) }
        #expect(try await graph.read { try $0.record(for: node)?.properties } == values)
        #expect(try await graph.collectSyncChanges() == 1)
        _ = try await graph.transaction { scope in
            try scope.patch(.init(id: node, properties: ["int": .set(.string("Changed")), "null": .remove]))
        }
        let result = try await graph.read { try $0.record(for: node)! }
        #expect(result.properties["int"] == .string("Changed")); #expect(result.properties["null"] == nil)
        try await graph.close()
        let opened = try await m.openGraph(id: id, at: url)
        #expect(try await opened.read { try $0.record(for: node) } == result)
        if case .floatingPoint(let zero) = result.properties["negativeZero"] { #expect(zero.sign == .minus) }
        else { Issue.record("Missing negative zero") }
        try await opened.close()
        let handle = try await StoreRegistry().open(.init(location: .sqlite(url), access: .readOnly), schema: GraphRuntimeSchema.attachmentProperties)
        try await handle.read { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
            request.predicate = NSPredicate(format: "ge2ValueKind != nil")
            let rows = try context.fetch(request)
            #expect(rows.count == values.count - 1)
            for row in rows { #expect(row.value(forKey: "object") == nil) }
            let changed = try #require(rows.first { $0.value(forKey: "name") as? String == "int" })
            #expect(changed.value(forKey: "ge2Int64") == nil)
            #expect(changed.value(forKey: "ge2String") as? String == "Changed")
        }
        try await handle.close(); try FileManager.default.removeItem(at: root)
    }
    @Test func longUnicodeAndEmbeddedNullStringsRetainTheirAuthoritativeRepresentation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Strings.sqlite"), context = GraphContext()
        let graph = try await context.createGraph(id: GraphID(), at: path), id = graph.makeNodeID()
        let text = String(repeating: "e\u{301}🙂", count: 20_000)
        let values: [String: GraphValue] = ["plain": .string(text), "nul": .string(text + "\0")]
        try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "Strings", properties: values)) }
        try await graph.close()
        let reopened = try await context.openGraph(id: graph.id, at: path)
        #expect(try await reopened.read { try $0.record(for: id)?.properties } == values)
        try await reopened.close()
    }

    @Test func schemaRemainsDistinctAndInvalidWriteRollsBack() async throws {
        #expect(GraphRuntimeSchema.attachmentProperties.identifier != GraphRuntimeSchema.nativeIdentity.identifier)
        let root = try directory(), m = manager(), id = GraphID(), url = root.appendingPathComponent("Store.sqlite")
        let graph = try await m.createGraph(id: id, at: url), node = graph.makeNodeID()
        await #expect(throws: (any Error).self) {
            try await graph.transaction { scope in
                try scope.insert(GraphRecord(id: node, type: "S04.Item", properties: ["ok": .integer(1), "invalid": .floatingPoint(.nan)]))
            }
        }
        #expect(try await graph.read { try $0.record(for: node) } == nil)
        try await graph.close()
        await #expect(throws: (any Error).self) { try await StoreRegistry().open(.init(location: .sqlite(url)), schema: GraphRuntimeSchema.nativeIdentity) }
        try FileManager.default.removeItem(at: root)
    }
    @Test func malformedNativeSlotIsRejectedWithoutSilentlyUsingAnotherRepresentation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await manager().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let node = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: node, type: "S04.Item", properties: ["value": .integer(1)])) }
        try await graph.nativeOperation { container in
            try container.testNativeContext { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
                request.predicate = NSPredicate(format: "name == %@", "value")
                let row = try #require(context.fetch(request).first)
                row.setValue("Unexpected second slot", forKey: "ge2String")
                try context.save()
            }
        }
        await #expect(throws: (any Error).self) { try await graph.read { try $0.record(for: node) } }
        await #expect(throws: (any Error).self) { try await graph.prepareSyncBatch(maximumRecords: 10) }
        try await graph.close()
    }

}


extension GraphTypedPropertyStorageTests {
    @Test func nativeStringRepresentationPreservesUnicodeAndRefusesInlineNull() async throws {
        let values: [(String, Int)] = [("", 0), ("\\0", 0), ("e\u{301}🙂", 0),
            ("\0", 1), ("\0prefix", 1), ("e\u{301}\0🙂", 1), ("suffix\0", 1)]
        for (value, encoding) in values {
            #expect(Int(try GraphNativePropertyStorage.prepare(.string(value)).encoding) == encoding)
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext().createGraph(id: GraphID(), at: root.appendingPathComponent("Strings.sqlite"))
        let id = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: id, type: "String", properties: ["text": .string("safe")])) }
        try await graph.transaction { scope in
            try scope.withContext { c, _ in
                let fetch = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityPropertyName)
                fetch.predicate = NSPredicate(format: "name == %@", "text")
                let row = try #require(try c.fetch(fetch).first)
                let original = row.value(forKey: "ge2String")
                defer { row.setValue(original, forKey: "ge2String") }
                row.setValue("e\u{301}\0🙂", forKey: "ge2String")
                #expect(throws: GraphStoreError.self) { try GraphNativePropertyStorage.read(row) }
            }
        }
        #expect(try await graph.read { try $0.record(for: id)?.properties["text"] } == .string("safe"))
        try await graph.close()
    }
}
