import CoreData
import CryptoKit
import Darwin
import Foundation
import GraphEvo

private struct Fixture: Codable, Sendable {
    let marker: String
    let graphIDs: [GraphID]
    let firstIDs: [GraphNodeID]
    let sampleIDs: [GraphNodeID]
    let fingerprints: [String]
    let attachment: GraphAttachmentMetadata?
}
private enum Failure: Error { case arguments, existing, mismatch }
private func fingerprint(_ record: GraphRecord) throws -> String {
    let endpoint: GraphValue
    switch record.endpoints {
    case .entity: endpoint = .string("entity")
    case .relationship(let subject, let object): endpoint = .array([subject.map { .uuid($0.rawValue) } ?? .null, object.map { .uuid($0.rawValue) } ?? .null])
    case .action(let subjects, let objects): endpoint = .array([.array(subjects.map { $0.rawValue.uuidString }.sorted().map(GraphValue.string)), .array(objects.map { $0.rawValue.uuidString }.sorted().map(GraphValue.string))])
    }
    let value: GraphValue = .object(["graph": .uuid(record.id.graphID.rawValue), "id": .uuid(record.id.rawValue), "type": .string(record.type),
        "endpoints": endpoint, "properties": .object(record.properties), "tags": .array(record.tags.sorted().map(GraphValue.string)),
        "groups": .array(record.groups.sorted().map(GraphValue.string)), "date": record.createdDate.map(GraphValue.date) ?? .null])
    return SHA256.hash(data: try GraphValueCodec.encode(value)).map { String(format: "%02x", $0) }.joined()
}
private func resident() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    } }
    return code == KERN_SUCCESS ? info.resident_size : 0
}
private func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

@main private struct IdentityLookupProbe {
    @MainActor static func open(_ url: URL, indexed: Bool) throws -> NSPersistentContainer {
        GraphValueTransformer.register()
        let container = NSPersistentContainer(name: "IdentityLab", managedObjectModel: GraphNativeIdentityPrototype.makeModel(indexed: indexed))
        _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: false, NSInferMappingModelAutomaticallyOption: false])
        return container
    }
    @MainActor static func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    @MainActor static func main() async {
        do { try await run() } catch { print("PROBE_FAILURE \(String(describing: error))"); exit(1) }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { throw Failure.arguments }
        let operation = args[1], root = URL(fileURLWithPath: args[2]), variant = args[3]
        guard ["seed", "convert", "read", "read-edge", "read-action", "missing", "patch", "validate", "audit"].contains(operation),
              ["plain", "files", "fanout", "full", "columns", "indexed"].contains(variant) else { throw Failure.arguments }
        let started = DispatchTime.now().uptimeNanoseconds
        var ms: Double = 0, returned = 0, sourceUnchanged = true
        if operation == "seed" {
            guard args.count == 6, let nodes = Int(args[4]), let graphs = Int(args[5]), nodes >= 2, graphs > 0,
                  !FileManager.default.fileExists(atPath: root.path) else { throw Failure.arguments }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try await GraphDatabase.open(at: root.appendingPathComponent("source/Graph.sqlite"))
            var graphIDs: [GraphID] = [], firstIDs: [GraphNodeID] = [], sampleIDs: [GraphNodeID] = [], prints: [String] = []
            var file: GraphAttachmentMetadata?
            for number in 0..<graphs {
                let graph = try await database.createGraph(), ids = (0..<nodes).map { _ in graph.makeNodeID() }
                let edge = graph.makeNodeID(), action = graph.makeNodeID()
                graphIDs.append(graph.id); firstIDs.append(ids[0])
                try await graph.transaction { scope in
                    for (index, id) in ids.enumerated() {
                        try scope.insert(GraphRecord(id: id, type: "identity.item", properties: ["index": .integer(Int64(index)),
                            "name": .string(String(repeating: "v", count: 64)), "revision": .string("seed"), "nil": .null,
                            "unknown": .encoded(GraphEncodedValue(codec: "future", version: 7, data: Data([0, 255])))],
                            tags: ["active"], groups: ["baseline"], createdDate: Date(timeIntervalSince1970: 1_700_000_000)))
                    }
                    try scope.insert(GraphRecord(id: edge, type: "identity.edge", endpoints: .relationship(subject: ids[0], object: ids[1])))
                    try scope.insert(GraphRecord(id: action, type: "identity.action", endpoints: .action(subjects: variant == "fanout" ? Set(ids) : [ids[0]], objects: variant == "fanout" ? Set(ids) : [ids[1]])))
                }
                if variant == "files" && number == 0 {
                    let input = root.appendingPathComponent("input.bin")
                    try Data((0..<(10 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: input)
                    file = try await graph.importAttachment(from: input, ownedBy: ids[0])
                    try FileManager.default.removeItem(at: input)
                }
                let selected = [ids[0], ids[1], edge, action] + (number == 0 ? file.map { [$0.id] } ?? [] : [])
                let records = try await graph.read { scope in try selected.map { id -> GraphRecord in
                    guard let record = try scope.record(for: id) else { throw Failure.mismatch }; return record
                } }
                sampleIDs += selected; prints += try records.map(fingerprint)
                try await graph.close()
            }
            try await database.close()
            try JSONEncoder().encode(Fixture(marker: "c02b-disposable.1", graphIDs: graphIDs, firstIDs: firstIDs, sampleIDs: sampleIDs, fingerprints: prints, attachment: file))
                .write(to: root.appendingPathComponent("fixture.json"))
            ms = elapsed(started); returned = nodes * graphs
        } else {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            guard fixture.marker == "c02b-disposable.1", !fixture.graphIDs.isEmpty, fixture.sampleIDs.count == fixture.fingerprints.count else { throw Failure.mismatch }
            if operation == "convert" {
                let indexed = variant == "indexed"
                let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent(variant)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.existing }
                let before = SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent("Graph.sqlite")))
                let copy = root.appendingPathComponent(variant + "-source-copy")
                try await GraphStoreBackup.copyClosedDirectory(from: source, to: copy)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let target = destination.appendingPathComponent("Graph.sqlite")
                try await Task.detached { try GraphNativeIdentityPrototype.migrateCopy(from: copy.appendingPathComponent("Graph.sqlite"), to: target, indexed: indexed) }.value
                let container = try open(target, indexed: indexed)
                returned = try await container.performBackgroundTask { @Sendable context in
                    defer { context.rollback(); context.reset() }
                    for graph in fixture.graphIDs { try GraphNativeIdentityPrototype.backfill(context, graphID: graph) }
                    try context.save(); context.reset()
                    var count = 0
                    for graph in fixture.graphIDs { count += try GraphNativeIdentityPrototype.validateAll(context, graphID: graph) }
                    for (id, expected) in zip(fixture.sampleIDs, fixture.fingerprints) {
                        guard let record = try GraphNativeIdentityPrototype.record(context, id: id), try fingerprint(record) == expected else { throw Failure.mismatch }
                    }
                    return count
                }
                try close(container)
                sourceUnchanged = SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent("Graph.sqlite"))) == before
                guard sourceUnchanged else { throw Failure.mismatch }; ms = elapsed(started)
            } else if variant == "full" {
                let database = try await GraphDatabase.open(at: root.appendingPathComponent("source/Graph.sqlite")), graph = try await database.openGraph(fixture.graphIDs[0])
                let begin = DispatchTime.now().uptimeNanoseconds
                switch operation {
                case "read": guard try await graph.read({ try $0.record(for: fixture.firstIDs[0])?.id }) == fixture.firstIDs[0] else { throw Failure.mismatch }; returned = 1
                case "read-edge", "read-action":
                    let id = fixture.sampleIDs[operation == "read-edge" ? 2 : 3]
                    guard try await graph.read({ try $0.record(for: id)?.id }) == id else { throw Failure.mismatch }; returned = 1
                case "missing": guard try await graph.read({ try $0.record(for: GraphNodeID(graphID: graph.id)) }) == nil else { throw Failure.mismatch }
                case "patch": _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: fixture.firstIDs[0], properties: ["revision": .set(.string(UUID().uuidString))])) }; returned = 1
                default: throw Failure.arguments
                }
                ms = elapsed(begin); try await graph.close(); try await database.close()
            } else {
                let database = try await GraphNativeIdentityPrototype.openLab(at: root.appendingPathComponent(variant + "/Graph.sqlite"), indexed: variant == "indexed")
                let graph = try await database.openGraph(fixture.graphIDs[0])
                let begin = DispatchTime.now().uptimeNanoseconds
                switch operation {
                case "read": guard try await graph.read({ try $0.record(for: fixture.firstIDs[0])?.id }) == fixture.firstIDs[0] else { throw Failure.mismatch }; returned = 1
                case "read-edge", "read-action":
                    let id = fixture.sampleIDs[operation == "read-edge" ? 2 : 3]
                    guard try await graph.read({ try $0.record(for: id)?.id }) == id else { throw Failure.mismatch }; returned = 1
                case "missing": guard try await graph.read({ try $0.record(for: GraphNodeID(graphID: graph.id)) }) == nil else { throw Failure.mismatch }
                case "patch": _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: fixture.firstIDs[0], properties: ["revision": .set(.string(UUID().uuidString))])) }; returned = 1
                case "validate": returned = try await database.contextRead { try GraphNativeIdentityPrototype.validateAll($0, graphID: fixture.graphIDs[0]) }
                case "audit": returned = try await database.contextRead { try GraphNativeIdentityPrototype.validateIdentityInventory($0, graphID: fixture.graphIDs[0]) }
                default: throw Failure.arguments
                }
                ms = elapsed(begin); try await graph.close(); try await database.close()
            }
        }
        var output: [String: Any] = ["operation": operation, "variant": variant, "elapsedMS": ms, "processMS": elapsed(started),
            "residentAtEnd": resident(), "returned": returned]
        if operation == "convert" { output["sourceUnchanged"] = sourceUnchanged }
        print("IDENTITY_JSON " + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
