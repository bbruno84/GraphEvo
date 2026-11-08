import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore
import os

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
private final class FootprintSampler: @unchecked Sendable {
    private struct State { var peak: UInt64 = 0; var samples = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "GraphEvo.Capacity.samples"))
    init() {
        sample()
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(25)); timer.resume()
    }
    func sample() { let bytes = footprint(); state.withLock { $0.peak = max($0.peak, bytes); $0.samples += 1 } }
    func stop() -> (UInt64, Int) { timer.cancel(); sample(); return state.withLock { ($0.peak, $0.samples) } }
}

/// External signed-host laboratory only. No production target includes this source.
@available(iOS 17, macOS 14, *)
public actor GraphCloudActivationDeviceProbe {
    private enum Failure: Error { case assertion, unknownStage, existingSource }
    private struct Metric: Codable {
        let operation: String
        let seconds: Double
        let footprintBefore: UInt64
        let sampledPeakFootprint: UInt64
        let footprintAfter: UInt64
        let samples: Int
        let thermalBefore: Int
        let thermalAfter: Int
        let passed: Bool
    }
    private struct Item: GraphModel {
        static let graphType = "Capacity.Item"
        static let graphKind: GraphNodeKind = .entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) { record = graphRecord }
        func graphRecord(in graphID: GraphID) -> GraphRecord { record }
    }
    private var metrics: [Metric] = []
    private var root: URL!
    public init() {}
    private func write<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    private func measure<T: Sendable>(_ name: String, _ body: () async throws -> T) async throws -> T {
        try Data(name.utf8).write(to: root.appendingPathComponent("phase.txt"), options: .atomic)
        let start = DispatchTime.now().uptimeNanoseconds, before = footprint()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue, sampler = FootprintSampler()
        let result: Result<T, any Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        let (peak, count) = sampler.stop()
        let passed: Bool = if case .success = result { true } else { false }
        metrics.append(Metric(operation: name, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9,
            footprintBefore: before, sampledPeakFootprint: peak, footprintAfter: footprint(), samples: count,
            thermalBefore: thermal, thermalAfter: ProcessInfo.processInfo.thermalState.rawValue, passed: passed))
        try write(metrics, name: "metrics.json")
        return try result.get()
    }
    private static func require(_ value: Bool) throws { if !value { throw Failure.assertion } }
    private static func digestFile(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
            digest.update(data: bytes)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func generateFile(_ url: URL, bytes: Int) throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure.assertion }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        // One deterministic varied 1-MiB block; no whole-file Data allocation.
        var state: UInt64 = 0x7AC349B102D8E6F5
        var block = Data(count: 1024 * 1024)
        block.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices { state ^= state << 13; state ^= state >> 7; state ^= state << 17; buffer[index] = UInt8(truncatingIfNeeded: state) }
        }
        var digest = SHA256(), remaining = bytes
        while remaining > 0 { let piece = Data(block.prefix(min(block.count, remaining))); try output.write(contentsOf: piece); digest.update(data: piece); remaining -= piece.count }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @MainActor private static func seed(_ url: URL) throws {
        var configuration = GraphStoreConfiguration(); configuration.location = url; configuration.disablesCloudKit = true
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        guard graph.isReady else { throw Failure.assertion }
        let node = Entity("Capacity.Legacy", graph: graph); node[dynamicMember: "binary"] = Data([1,2,3])
        var failure: Error?
        graph.sync { success, error in if !success { failure = error ?? Failure.assertion } }
        if let failure { throw failure }
        guard let container = graph.persistentContainer else { throw Failure.assertion }
        graph.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
    }
    private func synthetic() async throws {
        let server = DeviceCapacityTransport(), manager = GraphContextManager(schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
        await server.configure(manager)
        let source = root.appendingPathComponent("Legacy.sqlite")
        try await Self.seed(source)
        let conversion = try await measure("strings.convert-small-v1") {
            try await manager.openGraph(convertingLocalV1: .init(sourceURL: source, destinationURL: root.appendingPathComponent("Store.sqlite"), graphID: GraphID(), operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Physical capacity synthetic conversion"))
        }
        let graph = try conversion.opening.get(), id = graph.id
        let ids = (0..<36).map { _ in graph.makeNodeID() }, value = String(repeating: "x", count: 720_000)
        try await measure("strings.insert-25.92MB") {
            try await graph.transaction { scope in
                for nodeID in ids { try scope.insert(GraphRecord(id: nodeID, type: "Seed.Large", properties: ["value": .string(value)])) }
            }
        }
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.synthetic.capacity", environment: .development, directory: root.appendingPathComponent("Cloud"))
        let zone = GraphCloudZone(scope: .private, owner: "fixture", name: "capacity")
        try await server.start(manager, configuration: config)
        _ = try await measure("strings.prepare") {
            try await manager.prepareCloudActivation(for: id, activationID: UUID(), zone: zone, configuration: config,
                declaration: .init(sourceSelection: "Synthetic source", completeness: "All fixture nodes", stoppedWriters: "Source detached", returningClients: "No old writers"))
        }
        let advances = try await measure("strings.publish-simulated") { () async throws -> Int in
            for index in 1...45 {
                let result = try await manager.advanceCloudActivation(for: id, configuration: config)
                if let error = result.operationError { throw error }
                if result.status.phase == .published { return index }
            }
            throw Failure.assertion
        }
        let sends = await server.sends
        try await graph.close(); try await manager.stopCloudSession(config)
        let peer = GraphContextManager(schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
        let peerConfig = GraphCloudConfiguration(containerIdentifier: config.containerIdentifier, environment: .development, directory: root.appendingPathComponent("PeerCloud"))
        try await server.start(peer, configuration: peerConfig)
        let reopened = try await measure("strings.recover-empty-replica") {
            try await peer.openCloudReplica(id: id, at: root.appendingPathComponent("Peer.sqlite"), zone: zone, configuration: peerConfig)
        }
        let replica = try reopened.opening.get()
        try await measure("strings.verify-values") {
            try await Self.require(replica.read { scope in try ids.allSatisfy { try scope.record(for: $0)?.properties["value"] == .string(value) } })
        }
        try await Self.require(replica.collectSyncChanges() == 0)
        try Self.require(await server.sends == sends)
        try write(["advances": advances, "sends": sends, "rawStringBytes": 25_920_000], name: "strings-summary.json")
        try await replica.close(); try await peer.stopCloudSession(peerConfig)
    }
    private func attachmentsAndFiles() async throws {
        let context = GraphContext.localFiles(), path = root.appendingPathComponent("Files.sqlite"), id = GraphID()
        var graph = try await context.createGraph(id: id, at: path)
        let ids = (0..<32).map { _ in graph.makeNodeID() }, bytes = Data(repeating: 57, count: 2 * 1024 * 1024)
        try await measure("attachments.insert-32x2MiB") {
            try await graph.transaction { scope in
                for nodeID in ids { try scope.insert(GraphRecord(id: nodeID, type: Item.graphType, properties: ["rank": .integer(1)], attachments: ["body": .init(data: bytes)])) }
            }
        }
        try await measure("attachments.reject-2MiB-plus1") {
            do {
                try await graph.transaction { try $0.patch(GraphRecordPatch(id: ids[0], properties: ["rank": .set(.integer(999))], attachments: ["body": .set(.init(data: Data(count: 2 * 1024 * 1024 + 1)))])) }
                throw Failure.assertion
            } catch is GraphAttachmentError {}
            try await Self.require(graph.read { try $0.record(for: ids[0])?.properties["rank"] == .integer(1) })
        }
        try await graph.close()
        graph = try await measure("attachments.reopen") { try await context.openGraph(id: id, at: path) }
        let budget = try GraphQueryBudget(maximumCandidates: 1000, maximumPropertyBytes: 4096)
        let query = GraphQuery<Item>(budget: budget)
        for index in 0..<3 {
            try await measure("attachments.count.\(index)") { try await Self.require(graph.count(query).value == 32) }
            try await measure("attachments.projection.\(index)") { try await Self.require(graph.project(query, properties: ["rank"]).rows.count == 32) }
            try await measure("attachments.metadata.\(index)") {
                try await graph.read { scope in
                    for nodeID in ids { try Self.require(scope.attachments(ownedBy: nodeID).count == 1) }
                }
            }
            try await measure("attachments.read-all-bounded.\(index)") {
                for nodeID in ids {
                    try await Self.require(graph.read { try $0.record(for: nodeID)?.attachmentData(for: "body") == bytes })
                }
            }
        }
        try await measure("attachments.full-query-budget-refused") {
            do { _ = try await graph.query(query); throw Failure.assertion } catch is GraphQueryError {}
        }
        try await measure("attachments.full-query-64MiB") {
            let full = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 1000, maximumPropertyBytes: 96 * 1024 * 1024))
            let result = try await graph.query(full)
            try Self.require(result.items.count == 32)
            for item in result.items { try Self.require(item.record.attachments["body"]?.data == bytes) }
        }
        try await measure("attachments.replace-one-2MiB") {
            try await graph.transaction { try $0.patch(GraphRecordPatch(id: ids[0], attachments: ["body": .set(.init(data: bytes))])) }
        }
        for size in [25, 128] {
            let input = root.appendingPathComponent("input-\(size).bin")
            let digest = try Self.generateFile(input, bytes: size * 1024 * 1024)
            let file = try await measure("file.import-\(size)MiB") { try await graph.importFile(from: input) }
            try Self.require(file.sha256 == digest)
            for index in 0..<3 {
                try await measure("file.digest-\(size)MiB.\(index)") {
                    try await Self.require(graph.withFileURL(file.id) { try Self.digestFile($0) } == digest)
                }
            }
            try await measure("file.replace-\(size)MiB") { _ = try await graph.replaceFile(file, from: input) }
            try await measure("file.delete-reclaim-\(size)MiB") { try await graph.deleteFile(file.id); _ = try await graph.reclaimFiles() }
            try FileManager.default.removeItem(at: input)
        }
        try await graph.close()
    }
    private func deletionControl() async throws {
        let input = root.appendingPathComponent("empty.bin")
        try Data().write(to: input, options: .withoutOverwriting)
        let bytes = Data(repeating: 39, count: 2 * 1024 * 1024)
        for count in [0, 32] {
            let context = GraphContext.localFiles(), id = GraphID()
            let path = root.appendingPathComponent("DeleteControl-\(count).sqlite")
            var graph = try await context.createGraph(id: id, at: path)
            try await graph.transaction { scope in
                for _ in 0..<count { try scope.insert(GraphRecord(id: graph.makeNodeID(), type: Item.graphType, attachments: ["body": .init(data: bytes)])) }
            }
            let file = try await graph.importFile(from: input)
            try await graph.close()
            graph = try await context.openGraph(id: id, at: path)
            try await measure("delete.empty-file-with-\(count)-unrelated-attachments") { try await graph.deleteFile(file.id) }
            let query = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 1000, maximumPropertyBytes: 4096))
            try await Self.require(graph.count(query).value == count)
            try await graph.close()
        }
    }
    private func representative() async throws {
        let source = root.appendingPathComponent("Legacy.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.existingSource }
        let names = ["", "-wal", "-shm"]
        let before = try names.map { try Self.digestFile(URL(fileURLWithPath: source.path + $0)) }
        let context = GraphContext(), graphID = GraphID(), target = root.appendingPathComponent("Converted.sqlite")
        let result = try await measure("mhb.convert-with-backup") {
            try await context.openGraph(convertingLocalV1: .init(sourceURL: source, destinationURL: target, graphID: graphID, operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Representative physical capacity measurement"))
        }
        let graph = try result.opening.get(), ids = Array(result.conversion.receipt.nodeIDs.values)
        try Self.require(ids.count == 1577)
        let summary = try await measure("mhb.materialize-every-owner-separately") { () async throws -> [String: Int] in
            var count = 0, bytes = 0, largest = 0, properties = 0
            for nodeID in ids {
                let stats = try await graph.read { scope -> [Int] in
                    guard let record = try scope.record(for: nodeID) else { throw Failure.assertion }
                    return [record.attachments.count, record.attachments.values.reduce(0) { $0 + $1.data.count }, record.attachments.values.map { $0.data.count }.max() ?? 0, record.properties.count]
                }
                count += stats[0]; bytes += stats[1]; largest = max(largest, stats[2]); properties += stats[3]
            }
            return ["owners": ids.count, "attachments": count, "attachmentBytes": bytes, "largestAttachment": largest, "propertyCount": properties]
        }
        try write(summary, name: "mhb-summary.json")
        try await measure("mhb.validate-integrity") { _ = try await graph.validateIntegrity() }
        try await graph.close()
        let reopened = try await measure("mhb.reopen") { try await context.openGraph(id: graphID, at: target) }
        try await measure("mhb.metadata-list-all-owners") {
            try await reopened.read { scope in
                let count = try scope.withContext { native, adapter in
                    guard let list = adapter.attachmentMetadata else { throw Failure.assertion }
                    return try list(native, graphID, nil).count
                }
                try Self.require(count == summary["attachments"])
            }
        }
        try await reopened.close()
        try Self.require(try names.map { try Self.digestFile(URL(fileURLWithPath: source.path + $0)) } == before)
    }
    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        try write(["os": ProcessInfo.processInfo.operatingSystemVersionString, "sourceCommit": "30c01ab6", "harness": "3-deletion-control", "sampling": "25ms physical footprint; process caches uncontrolled; Release"], name: "environment.json")
        switch stage {
        case "strings": try await synthetic()
        case "binaries": try await attachmentsAndFiles()
        case "representative": try await representative()
        case "delete-control": try await deletionControl()
        default: throw Failure.unknownStage
        }
        return ["Measured stage passed exact content and boundary assertions.", "Metrics are local physical-device costs; no Apple network in this stage.", "Sampled physical footprint is not a certified instantaneous peak."]
    }
}
