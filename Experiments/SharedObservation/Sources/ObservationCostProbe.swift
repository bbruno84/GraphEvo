import Darwin
import Foundation
import GraphEvo
import os

private struct Item: GraphModel {
    static let graphType = "c04.item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}
private struct Fixture: Codable { let marker: String; let graph: GraphID; let ids: [GraphNodeID] }
private enum Failure: Error { case arguments, mismatch }
private func ms(_ begin: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000 }
private func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}
private func rss() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    } }
    return code == KERN_SUCCESS ? info.resident_size : 0
}
private final class Samples: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (peak: UInt64(0), samples: 0))
    func sample() { let bytes = rss(); state.withLock { $0.peak = max($0.peak, bytes); $0.samples += 1 } }
    var result: (UInt64, Int) { state.withLock { ($0.peak, $0.samples) } }
}
private func next(_ stream: GraphObservation<GraphQueryState<Item>>, id: GraphNodeID,
                  after: UUID? = nil, revision: String? = nil) async throws -> GraphQueryResult<Item> {
    for await state in stream {
        switch state {
        case .failure(let error): throw error
        case .value(let value):
            guard value.items.count == 1, value.items.first?.id == id else { throw Failure.mismatch }
            if value.view.scopeID != after, revision == nil || value.items.first?.record.properties["revision"] == .string(revision!) { return value }
        }
    }
    throw Failure.mismatch
}
@main private struct ObservationCostProbe {
    static func main() async {
        do { try await run() } catch { print("OBSERVATION_FAILURE \(error)"); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { throw Failure.arguments }
        let operation = args[1], root = URL(fileURLWithPath: args[2])
        let url = root.appendingPathComponent("store/Graph.sqlite")
        if operation == "seed" {
            guard let nodes = Int(args[3]), nodes >= 32, let fileMiB = Int(args[4]), (0...10).contains(fileMiB),
                  !FileManager.default.fileExists(atPath: root.path) else { throw Failure.arguments }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try await GraphDatabase.open(at: url), graph = try await database.createGraph()
            let ids = (0..<nodes).map { _ in graph.makeNodeID() }
            try await graph.transaction { scope in
                for (index, id) in ids.enumerated() {
                    try scope.insert(GraphRecord(id: id, type: Item.graphType, properties: ["index": .integer(Int64(index)),
                        "name": .string(String(repeating: "v", count: 64)), "revision": .string("seed")], tags: ["active"], groups: ["baseline"]))
                }
            }
            if fileMiB > 0 {
                let source = root.appendingPathComponent("source.bin")
                try Data((0..<(fileMiB * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: source)
                for _ in 0..<4 { _ = try await graph.importAttachment(from: source, ownedBy: ids[0]) }
                try FileManager.default.removeItem(at: source)
            }
            let fixture = Fixture(marker: "c04.disposable.1", graph: graph.id, ids: ids)
            try await graph.close(); try await database.close()
            try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("fixture.json"))
            print("OBSERVATION_JSON {\"seed\":true}"); return
        }
        guard operation == "run", args.count == 6, ["independent","shared"].contains(args[3]),
              let count = Int(args[4]), [1,8,32].contains(count), ["equal","mixed"].contains(args[5]) else { throw Failure.arguments }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        guard fixture.marker == "c04.disposable.1", fixture.ids.count >= count else { throw Failure.mismatch }
        let samples = Samples(); samples.sample()
        let sampler = Task.detached { while !Task.isCancelled { samples.sample(); try? await Task.sleep(for: .milliseconds(2)) } }
        let open = DispatchTime.now().uptimeNanoseconds
        let database = try await GraphDatabase.open(at: url), graph = try await database.openGraph(fixture.graph)
        let openMS = ms(open), lab = args[3] == "shared" ? GraphSharedObservationLab(graph: graph) : nil
        let begin = DispatchTime.now().uptimeNanoseconds, initialCPU = cpu()
        var streams: [(GraphObservation<GraphQueryState<Item>>, GraphNodeID, UUID)] = []
        for index in 0..<count {
            let id = fixture.ids[args[5] == "mixed" ? index : 0]
            let query = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: fixture.ids.count * 2 + 100)).where(.id(id) && .tag("active"))
            let observation: GraphObservation<GraphQueryState<Item>>
            if let lab { observation = try await lab.observe(query) }
            else { observation = try await graph.observe(query) }
            let value = try await next(observation, id: id)
            streams.append((observation,id,value.view.scopeID))
        }
        let startupMS = ms(begin), startupCPU = cpu() - initialCPU
        let before = await lab?.diagnostics.executions
        let revision = UUID().uuidString, wave = DispatchTime.now().uptimeNanoseconds, waveCPU = cpu()
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: fixture.ids[0], properties: ["revision": .set(.string(revision))])) }
        let writeMS = ms(wave), tail = DispatchTime.now().uptimeNanoseconds
        let scopes = try await withThrowingTaskGroup(of: UUID.self, returning: Set<UUID>.self) { group in
            for (stream,id,previous) in streams {
                group.addTask { try await next(stream, id: id, after: previous, revision: id == fixture.ids[0] ? revision : "seed").view.scopeID }
            }
            var ids = Set<UUID>(); for try await scope in group { ids.insert(scope) }; return ids
        }
        let waveMS = ms(wave), tailMS = ms(tail), updateCPU = cpu() - waveCPU
        let after = await lab?.diagnostics.executions
        for (stream,_,_) in streams { stream.cancel() }
        if let lab { guard await lab.diagnostics.subscribers == 0, await lab.diagnostics.activeGroups == 0 else { throw Failure.mismatch } }
        try await graph.close(); try await database.close()
        sampler.cancel(); await sampler.value; samples.sample()
        let (peak, sampleCount) = samples.result
        var values: [String: Any] = ["variant":args[3],"count":count,"mode":args[5],"openMS":openMS,"startupMS":startupMS,
            "startupCPU":startupCPU,"waveMS":waveMS,"writeMS":writeMS,"tailMS":tailMS,"waveCPU":updateCPU,
            "sampledProcessPeakRSS":peak,"rssSamples":sampleCount,"delivered":streams.count,"executionScopes":scopes.count]
        if let before, let after { values["sharedExecutions"] = after - before }
        print("OBSERVATION_JSON " + String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self))
    }
}
