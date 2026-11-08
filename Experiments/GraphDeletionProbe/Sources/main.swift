import Darwin
import Foundation
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

@available(macOS 14, *)
@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let uuid = UUID(uuidString: args[3]) else { fatalError("Expected mode, directory and Graph UUID") }
        let root = URL(fileURLWithPath: args[2], isDirectory: true), id = GraphID(rawValue: uuid), url = root.appendingPathComponent("Graph.sqlite")
        if ["seed", "hold", "delete", "delete-normal"].contains(args[1]) {
            let context = GraphContext.localFiles()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if args[1] == "seed" {
                let graph = try await context.createGraph(id: id, at: url)
                let input = root.appendingPathComponent("Input.bin")
                try Data(repeating: 42, count: 32 * 1024).write(to: input)
                _ = try await graph.importFile(from: input)
                try await graph.close(); return
            }
            let graph = try await context.openGraph(id: id, at: url)
            if args[1] == "hold" {
                try Data().write(to: root.appendingPathComponent("ready"), options: .withoutOverwriting)
                for _ in 0..<300 {
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) { try await graph.close(); return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                fatalError("Hold deadline exceeded")
            }
            if args[1] == "delete-normal" {
                let status = try await context.deleteGraph(graph)
                guard status.phase == .completed else { fatalError("Expected completed deletion") }
                try await graph.close(); print("PASS normal process death registration recovered by exact deletion")
                return
            }
            do { _ = try await context.deleteGraph(graph); fatalError("Independent holder must defer deletion") }
            catch { try await graph.close(); print("PENDING exact store retained; deleting owner detached") }
            return
        }
        if args[1] == "resume" {
            let context = GraphContext.localFiles()
            let result = try await context.resumeGraphDeletion(id: id, at: url)
            guard result.phase == .completed, !FileManager.default.fileExists(atPath: url.path) else { fatalError("Incomplete deletion") }
            print("PASS exact interrupted destruction resumed")
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var hooks = StoreLifecycleHooks()
        let terminate: @Sendable () throws -> Void = { kill(getpid(), SIGKILL) }
        switch args[1] {
        case "before": hooks.beforeDestroy = terminate
        case "after": hooks.beforeDestroyedArtifactCleanup = terminate
        case "cleaned": hooks.didDestroy = terminate
        default: fatalError("Unknown crash boundary")
        }
        let manager = GraphContextManager(registry: StoreRegistry(hooks: hooks), schema: GraphRuntimeSchema.attachmentFiles,
            adapter: GraphCoordinatorFactory.makeAdapter(files: true))
        let graph = try await manager.createGraph(id: id, at: url)
        try await graph.transaction { try $0.insert(GraphRecord(id: graph.makeNodeID(), type: "Note", properties: ["title": .string("Crash fixture")])) }
        let input = root.appendingPathComponent("Input.bin")
        try Data(repeating: 42, count: 32 * 1024).write(to: input)
        _ = try await graph.importFile(from: input)
        _ = try await manager.deleteGraph(id, configuration: nil)
        fatalError("Expected process termination")
    }
}
