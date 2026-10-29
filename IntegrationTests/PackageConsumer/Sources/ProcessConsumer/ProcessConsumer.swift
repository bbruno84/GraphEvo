import Foundation
import GraphEvo

private struct Item: GraphModel {
    static let graphType = "ProcessConsumer.Item"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let value: Int64
    init(id: GraphNodeID, value: Int64) { self.id = id; self.value = value }
    init(graphRecord: GraphRecord) throws { id = graphRecord.id; value = try graphRecord.value(for: "value") }
    func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType, properties: ["value": .integer(value)]) }
}

@main private struct ProcessConsumer {
    private enum Failure: Error { case arguments, mismatch, deadline, unexpectedWrite, childFailed }
    private struct Fixture: Codable { let graphID: GraphID; let nodeID: GraphNodeID; let native: Bool }

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "reader" { try await reader(URL(fileURLWithPath: args[2])); return }
        if args.count == 3, args[1] == "extension-refusal" { try await extensionRefusal(URL(fileURLWithPath: args[2])); return }
        guard args.count == 1 else { throw Failure.arguments }
        for native in [false, true] { try await writer(native: native) }
        try await packagedExtensionRefusal()
        print("PASS separate-process local readers: current/native schemas, committed reread, observation and write refusal. Not an iOS App Group or CloudKit certificate.")
    }

    private static func extensionRefusal(_ root: URL) async throws {
        let privateURL = root.appendingPathComponent("Stores/private.sqlite")
        let sharedURL = root.appendingPathComponent("Stores/shared.sqlite")
        for schema in [GraphDatabaseSchema.current, .nativeIdentity] {
            do {
                let db = try await GraphDatabase.openMirrored(at: privateURL, containerIdentifier: "iCloud.example.invalid", schema: schema)
                try await db.close(); throw Failure.unexpectedWrite
            } catch GraphStoreError.synchronizationUnavailableInExtension { }
            do {
                let db = try await GraphDatabase.openMirrored(privateStoreAt: privateURL, sharedStoreAt: sharedURL,
                    containerIdentifier: "iCloud.example.invalid", schema: schema)
                try await db.close(); throw Failure.unexpectedWrite
            } catch GraphStoreError.synchronizationUnavailableInExtension { }
        }
        guard !FileManager.default.fileExists(atPath: privateURL.deletingLastPathComponent().path) else { throw Failure.mismatch }
        print("PASS synthetic extension bundle: public mirrored overloads refused before native file creation.")
    }

    private static func packagedExtensionRefusal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-ExtensionConsumer-\(UUID())")
        let bundle = root.appendingPathComponent("Probe.appex/Contents")
        let binary = bundle.appendingPathComponent("MacOS/ProcessConsumer")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        var complete = false
        defer { if complete { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, to: binary)
        let info: [String: Any] = ["CFBundleExecutable": "ProcessConsumer", "CFBundleIdentifier": "GraphEvo.ProcessConsumer.Extension",
            "CFBundlePackageType": "XPC!", "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"), options: .atomic)
        let process = Process(); process.executableURL = binary; process.arguments = ["extension-refusal", root.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(30))
        while process.isRunning {
            if clock.now >= deadline { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard process.terminationStatus == 0 else { throw Failure.childFailed }
        complete = true
    }

    private static func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: url.path) {
            if clock.now >= deadline { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func marker(_ name: String, in root: URL) throws {
        try Data("ready".utf8).write(to: root.appendingPathComponent(name), options: .atomic)
    }

    private static func writer(native: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-ProcessConsumer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var complete = false
        defer { if complete { try? FileManager.default.removeItem(at: root) } }
        let schema: GraphDatabaseSchema = native ? .nativeIdentity : .current
        let database = try await GraphDatabase.open(at: root.appendingPathComponent("Main.sqlite"), schema: schema)
        let graph = try await database.createGraph(), id = graph.makeNodeID()
        try await graph.insert(Item(id: id, value: 0))
        try JSONEncoder().encode(Fixture(graphID: graph.id, nodeID: id, native: native))
            .write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["reader", root.path]
        // Output contains only payload-free pass/fail summaries; the fixture stays private.
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        try await waitForFile(root.appendingPathComponent("reader-ready"))
        _ = try await graph.patch(GraphRecordPatch(id: id, properties: ["value": .set(.integer(1))]), as: Item.self)
        try marker("writer-committed", in: root)
        try await waitForFile(root.appendingPathComponent("reader-finished"))
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(10))
        while child.isRunning {
            if clock.now >= deadline { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard child.terminationStatus == 0, try await graph.fetch(id, as: Item.self)?.value == 1,
              try await database.graphIDs() == [graph.id] else { throw Failure.childFailed }
        try await graph.close(); try await database.close()
        complete = true
    }

    private static func reader(_ root: URL) async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let schema: GraphDatabaseSchema = fixture.native ? .nativeIdentity : .current
        let database = try await GraphDatabase.openReadOnly(at: root.appendingPathComponent("Main.sqlite"), schema: schema)
        let graph = try await database.openGraph(fixture.graphID)
        guard try await graph.fetch(fixture.nodeID, as: Item.self)?.value == 0 else { throw Failure.mismatch }
        do { _ = try await database.createGraph(); throw Failure.unexpectedWrite }
        catch GraphStoreError.readOnly { }
        do {
            _ = try await graph.transaction { _ -> Int in throw Failure.unexpectedWrite }
            throw Failure.unexpectedWrite
        } catch GraphStoreError.readOnly { }
        let query = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 64)).where(.id(fixture.nodeID))
        let observed = try await graph.observe(query)
        defer { observed.cancel() }
        let watcher = Task {
            for await state in observed {
                switch state {
                case .value(let result):
                    if result.items.first?.value == 0 { try marker("reader-ready", in: root) }
                    if result.items.first?.value == 1 { return }
                case .failure: throw Failure.mismatch
                }
            }
            throw Failure.mismatch
        }
        defer { watcher.cancel() }
        try await waitForFile(root.appendingPathComponent("writer-committed"))
        // A fresh runtime read must see the commit even if an invalidation is delayed.
        guard try await graph.fetch(fixture.nodeID, as: Item.self)?.value == 1 else { throw Failure.mismatch }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await watcher.value }
            group.addTask { try await Task.sleep(for: .seconds(20)); watcher.cancel(); throw Failure.deadline }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        observed.cancel()
        try await graph.close(); try await database.close()
        try marker("reader-finished", in: root)
    }
}
