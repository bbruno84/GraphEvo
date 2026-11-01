import Darwin
import Foundation
import GraphEvo
import os

private struct CostNode: GraphModel {
    static let graphType = "consolidation.node"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}
private struct Configuration: Codable, Sendable {
    let name: String
    let graphs: Int
    let nodes: Int
    let files: Int
    let bytes: Int
    let fileGraph: Int
}
private struct Fixture: Codable {
    let configuration: Configuration
    let graphIDs: [GraphID]
    let firstIDs: [GraphNodeID]
    let attachments: [GraphAttachmentMetadata]
}
private struct Metrics: Codable {
    var name: String
    var operation: String
    var elapsedMS = 0.0
    var openMS = 0.0
    var baselineResident: UInt64 = 0
    var sampledPeakResident: UInt64 = 0
    var postOpenResident: UInt64?
    var propertyBudget: Int?
    var finalResident: UInt64 = 0
    var residentSamples = 0
    var processHighWater: Int64 = 0
    var directoryBytes: Int64 = 0
    var returned = 0
    var nativeCandidates: Int?
    var scopedNodes: Int?
    var propertyBytes: Int?
    var evaluationSteps: Int?
    var observerCount: Int?
    var error: String?
    mutating func diagnostics(_ value: GraphQueryDiagnostics) {
        nativeCandidates = value.nativeCandidates; scopedNodes = value.scopedNodes
        propertyBytes = value.propertyBytesCharged; evaluationSteps = value.evaluationSteps
    }
}
private enum Failure: Error { case arguments, existingFixture, unexpectedResult, expiredObservation }
private func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
private func resident() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
private final class ResidentSamples: Sendable {
    private struct State: Sendable { var peak: UInt64 = 0; var count = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func sample() {
        let bytes = resident()
        state.withLock { $0.peak = max($0.peak, bytes); $0.count += 1 }
    }
    func result() -> (UInt64, Int) { state.withLock { ($0.peak, $0.count) } }
}
private func directoryBytes(_ directory: URL) throws -> Int64 {
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
    var bytes: Int64 = 0
    for case let file as URL in files {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if info.isRegularFile == true { bytes += Int64(info.fileSize ?? 0) }
    }
    return bytes
}
/// Deterministic varied bytes avoid repeating one small compressible block; they are not real user media.
private func payload(_ count: Int) -> Data {
    var random: UInt64 = 0xF123AB4509876CDE
    var bytes = Data(count: count)
    bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        for index in stride(from: 0, to: count, by: 8) {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            for offset in 0..<min(8, count - index) { buffer[index + offset] = UInt8(truncatingIfNeeded: random >> (offset * 8)) }
        }
    }
    return bytes
}
private func seed(_ root: URL, configuration: Configuration) async throws -> Fixture {
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Graph.sqlite").path),
          configuration.graphs > 0, configuration.nodes > 0, (0..<configuration.graphs).contains(configuration.fileGraph),
          configuration.files >= 0, configuration.bytes >= 0, configuration.bytes <= GraphStore.maximumAttachmentByteCount else { throw Failure.existingFixture }
    let database = try await GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite"))
    var handles: [GraphStore] = [], firstIDs: [GraphNodeID] = []
    for _ in 0..<configuration.graphs {
        let graph = try await database.createGraph()
        handles.append(graph)
        let ids = (0..<configuration.nodes).map { _ in graph.makeNodeID() }
        firstIDs.append(ids[0])
        try await graph.transaction { scope in
            for index in 0..<configuration.nodes {
                try scope.insert(GraphRecord(id: ids[index], type: CostNode.graphType,
                    properties: ["index": .integer(Int64(index)), "name": .string(String(repeating: "v", count: 64)), "revision": .string("seed")],
                    tags: ["active"], groups: ["baseline"]))
            }
        }
    }
    var attachments: [GraphAttachmentMetadata] = []
    if configuration.files > 0 {
        let source = root.appendingPathComponent("source.bin")
        try payload(configuration.bytes).write(to: source)
        for _ in 0..<configuration.files {
            attachments.append(try await handles[configuration.fileGraph].importAttachment(from: source,
                ownedBy: firstIDs[configuration.fileGraph]))
        }
        try FileManager.default.removeItem(at: source)
    }
    let fixture = Fixture(configuration: configuration, graphIDs: handles.map(\.id), firstIDs: firstIDs, attachments: attachments)
    for graph in handles { try await graph.close() }
    try await database.close()
    return fixture
}
private func observeWave(_ graph: GraphStore, query: GraphQuery<CostNode>, id: GraphNodeID, count: Int) async throws -> (Int, GraphQueryDiagnostics) {
    var subscriptions: [GraphObservation<GraphQueryState<CostNode>>] = []
    defer { for subscription in subscriptions { subscription.cancel() } }
    for _ in 0..<count {
        let observation = try await graph.observe(query)
        subscriptions.append(observation)
        var iterator = observation.makeAsyncIterator()
        guard case .value(let result) = await iterator.next(), result.items.count == 1 else { throw Failure.unexpectedResult }
    }
    let revision = UUID().uuidString
    try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["revision": .set(.string(revision))])) }
    return try await withThrowingTaskGroup(of: GraphQueryDiagnostics.self) { group in
        for observation in subscriptions {
            group.addTask {
                for await state in observation {
                    switch state {
                    case .failure(let error): throw error
                    case .value(let result):
                        if result.items.first?.record.properties["revision"] == .string(revision) { return result.diagnostics }
                    }
                }
                throw Failure.expiredObservation
            }
        }
        var finished = 0, diagnostic: GraphQueryDiagnostics?
        for try await result in group { finished += 1; diagnostic = result }
        guard finished == count, let diagnostic else { throw Failure.unexpectedResult }
        return (finished, diagnostic)
    }
}

@main private struct CostProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { throw Failure.arguments }
        let operation = args[1], root = URL(fileURLWithPath: args[2], isDirectory: true)
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        var metric = Metrics(name: configuration.name, operation: operation)
        let samples = ResidentSamples()
        metric.baselineResident = resident(); samples.sample()
        let sampler = Task.detached {
            while !Task.isCancelled {
                samples.sample()
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        if operation == "seed" {
            let fixture = try await seed(root, configuration: configuration)
            try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
            metric.returned = configuration.nodes * configuration.graphs
        } else {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let database = try await GraphDatabase.open(at: root.appendingPathComponent("Graph.sqlite"))
            let graph = try await database.openGraph(fixture.graphIDs[0])
            metric.openMS = milliseconds(started)
            metric.postOpenResident = resident()
            // Opening has its own cost. Sampled peak/high-water still cover the whole process, including open.
            let operationStart = DispatchTime.now().uptimeNanoseconds
            let bytes = args.count > 4 ? Int(args[4]) ?? 32 * 1024 * 1024 : 32 * 1024 * 1024
            metric.propertyBudget = bytes
            let query = GraphQuery<CostNode>(budget: try GraphQueryBudget(maximumCandidates: 20_000, maximumPropertyBytes: bytes))
                .where(.property("index", .equal, .integer(0)))
            do {
                switch operation {
                case "query":
                    let result = try await graph.query(query); metric.returned = result.items.count; metric.diagnostics(result.diagnostics)
                    guard metric.returned == 1 else { throw Failure.unexpectedResult }
                case "count":
                    let result = try await graph.count(query); metric.returned = result.value; metric.diagnostics(result.diagnostics)
                    guard metric.returned == 1 else { throw Failure.unexpectedResult }
                case "project":
                    let result = try await graph.project(query, properties: ["name"]); metric.returned = result.rows.count; metric.diagnostics(result.diagnostics)
                    guard result.rows.first?.values.count == 1 else { throw Failure.unexpectedResult }
                case "fetch":
                    guard try await graph.fetch(fixture.firstIDs[0], as: CostNode.self) != nil else { throw Failure.unexpectedResult }
                    metric.returned = 1
                case "list":
                    let result = try await graph.attachments(ownedBy: fixture.firstIDs[0]); metric.returned = result.count
                    guard metric.returned == (configuration.fileGraph == 0 ? configuration.files : 0) else { throw Failure.unexpectedResult }
                case "read":
                    guard let first = fixture.attachments.first, configuration.fileGraph == 0,
                          let file = try await graph.attachment(first.id), file.metadata == first else { throw Failure.unexpectedResult }
                    metric.returned = file.data.count
                case "patch":
                    try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: fixture.firstIDs[0], properties: ["revision": .set(.string(UUID().uuidString))])) }
                    metric.returned = 1
                case "observe1", "observe8":
                    let count = operation == "observe1" ? 1 : 8
                    let (finished, diagnostic) = try await observeWave(graph, query: query, id: fixture.firstIDs[0], count: count)
                    metric.returned = finished; metric.observerCount = count; metric.diagnostics(diagnostic)
                default: throw Failure.arguments
                }
            } catch GraphQueryError.budgetExceeded(let dimension) {
                metric.error = "budgetExceeded(\(dimension))"
            }
            metric.elapsedMS = milliseconds(operationStart)
            try await graph.close(); try await database.close()
        }
        if operation == "seed" { metric.elapsedMS = milliseconds(started) }
        samples.sample(); sampler.cancel(); await sampler.value
        let (peak, count) = samples.result()
        metric.sampledPeakResident = peak; metric.residentSamples = count; metric.finalResident = resident()
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        metric.processHighWater = Int64(usage.ru_maxrss)
        metric.directoryBytes = try directoryBytes(root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("COST_JSON " + String(decoding: try encoder.encode(metric), as: UTF8.self))
    }
}
