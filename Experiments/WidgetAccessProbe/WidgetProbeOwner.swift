import Foundation
import GraphEvo

/// One application-side owner, kept alive while WidgetKit opens independent local readers.
actor WidgetProbeOwner {
    private let rootOverride: URL?
    init(root: URL? = nil) { rootOverride = root }
    private func storageRoot() throws -> URL { try rootOverride ?? WidgetProbeStorage.root() }
    private var database: GraphDatabase?
    private var graph: GraphStore?
    private var manifest: WidgetProbeManifest?

    func prepare(run: UUID, mirrored: Bool) async throws -> Int64 {
        let root = try storageRoot(), folder = root.appendingPathComponent(run.uuidString)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw WidgetProbeStorage.Failure.replay }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await close()
        let urls = WidgetProbeStorage.urls(in: folder)
        let db = try await open(urls: urls, mirrored: mirrored); database = db
        if mirrored {
            for attempt in 0..<150 {
                let setup = try await db.cloudSetupStatus()
                if setup.readyStoreCount == 2 { break }
                if attempt == 149 { throw WidgetProbeStorage.Failure.deadline }
                try await Task.sleep(for: .seconds(2))
            }
        }
        let graph = try await db.createGraph(); self.graph = graph
        let node = graph.makeNodeID(); try await graph.insert(WidgetProbeItem(id: node, value: 0))
        let manifest = WidgetProbeManifest(runID: run, graphID: graph.id, nodeID: node,
            mirrored: mirrored, ownerPID: ProcessInfo.processInfo.processIdentifier)
        self.manifest = manifest
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        return 0
    }

    func increment(expectedRun: UUID? = nil) async throws -> Int64 {
        if graph == nil {
            let root = try storageRoot(), active = try WidgetProbeStorage.manifest(in: root)
            if let expectedRun, expectedRun != active.runID { throw WidgetProbeStorage.Failure.mismatch }
            let db = try await open(urls: WidgetProbeStorage.urls(in: WidgetProbeStorage.folder(active, root: root)), mirrored: active.mirrored)
            database = db; graph = try await db.openGraph(active.graphID)
            manifest = WidgetProbeManifest(runID: active.runID, graphID: active.graphID, nodeID: active.nodeID,
                mirrored: active.mirrored, ownerPID: ProcessInfo.processInfo.processIdentifier)
        }
        guard let graph, let manifest, expectedRun == nil || expectedRun == manifest.runID,
              let current = try await graph.fetch(manifest.nodeID, as: WidgetProbeItem.self) else { throw WidgetProbeStorage.Failure.mismatch }
        let result = try await graph.patch(GraphRecordPatch(id: current.id, properties: ["value": .set(.integer(current.value + 1))]), as: WidgetProbeItem.self)
        try JSONEncoder().encode(manifest).write(to: storageRoot().appendingPathComponent("active.json"), options: .atomic)
        return result.value
    }

    func close() async throws {
        try await graph?.close(); graph = nil
        try await database?.close(); database = nil; manifest = nil
    }

    private func open(urls: (URL, URL), mirrored: Bool) async throws -> GraphDatabase {
        if mirrored {
            guard let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  !identifier.isEmpty else { throw WidgetProbeStorage.Failure.mismatch }
            return try await GraphDatabase.openMirrored(privateStoreAt: urls.0, sharedStoreAt: urls.1,
                containerIdentifier: identifier, schema: .nativeIdentity)
        }
        return try await GraphDatabase.open(at: urls.0, schema: .nativeIdentity)
    }
}
