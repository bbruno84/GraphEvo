import Foundation
import GraphEvo

nonisolated struct WidgetProbeItem: GraphModel {
    static let graphType = "WidgetProbe.Counter"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let value: Int64
    init(id: GraphNodeID, value: Int64) { self.id = id; self.value = value }
    init(graphRecord: GraphRecord) throws { id = graphRecord.id; value = try graphRecord.value(for: "value") }
    func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType, properties: ["value": .integer(value)]) }
}

nonisolated struct WidgetProbeManifest: Codable, Sendable {
    let runID: UUID
    let graphID: GraphID
    let nodeID: GraphNodeID
    let mirrored: Bool
    let ownerPID: Int32
}

nonisolated struct WidgetProbeEvidence: Codable, Sendable {
    let date: Date
    let processID: Int32
    let runID: UUID?
    let status: String
    let value: Int64?
    let mirrorRefused: Bool
    let mutationRefused: Bool
    let ownerPID: Int32?
}

nonisolated enum WidgetProbeStorage {
    static let kind = "GraphEvoReadOnlyLaboratory"
    enum Failure: Error { case groupUnavailable, missingManifest, mismatch, replay, deadline, unsafeMutation }
    static func root() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GraphEvoWidgetAppGroup") as? String,
              !group.isEmpty, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw Failure.groupUnavailable
        }
        return root.appendingPathComponent("Library/Application Support/GraphEvoLaboratory/WidgetAccess")
    }
    static func manifest(in root: URL) throws -> WidgetProbeManifest {
        try JSONDecoder().decode(WidgetProbeManifest.self, from: Data(contentsOf: root.appendingPathComponent("active.json")))
    }
    static func folder(_ manifest: WidgetProbeManifest, root: URL) -> URL { root.appendingPathComponent(manifest.runID.uuidString) }
    static func urls(in folder: URL) -> (URL, URL) { (folder.appendingPathComponent("private.sqlite"), folder.appendingPathComponent("shared.sqlite")) }
    static func record(_ evidence: WidgetProbeEvidence, root: URL) throws {
        let reports = root.appendingPathComponent("WidgetReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(evidence)
        try data.write(to: reports.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        try data.write(to: root.appendingPathComponent("widget-latest.json"), options: .atomic)
    }
}

/// A real extension consumer; values come from Graph queries, never from the manifest.
nonisolated enum WidgetProbeReader {
    static func load() async -> WidgetProbeEvidence {
        var root: URL?
        var manifest: WidgetProbeManifest?
        var mirrorRefused = false
        var mutationRefused = false
        var database: GraphDatabase?
        var graph: GraphStore?
        var value: Int64?
        var status = "unavailable"
        do {
            let sharedRoot = try WidgetProbeStorage.root(); root = sharedRoot
            do {
                let forbidden = sharedRoot.appendingPathComponent("Forbidden/private.sqlite")
                let unexpected = try await GraphDatabase.openMirrored(at: forbidden, containerIdentifier: "iCloud.example.invalid", schema: .nativeIdentity)
                try await unexpected.close(); throw WidgetProbeStorage.Failure.unsafeMutation
            } catch GraphStoreError.synchronizationUnavailableInExtension { mirrorRefused = true }
            guard FileManager.default.fileExists(atPath: sharedRoot.appendingPathComponent("active.json").path) else {
                let missing = sharedRoot.appendingPathComponent("NotInitialized/private.sqlite")
                do {
                    let unexpected = try await GraphDatabase.openReadOnly(at: missing, schema: .nativeIdentity)
                    try await unexpected.close(); throw WidgetProbeStorage.Failure.unsafeMutation
                } catch GraphStoreError.missingStore {
                    guard !FileManager.default.fileExists(atPath: missing.path) else { throw WidgetProbeStorage.Failure.unsafeMutation }
                    throw WidgetProbeStorage.Failure.missingManifest
                }
            }
            let active = try WidgetProbeStorage.manifest(in: sharedRoot); manifest = active
            let urls = WidgetProbeStorage.urls(in: WidgetProbeStorage.folder(active, root: sharedRoot))
            let reader: GraphDatabase
            if active.mirrored {
                reader = try await GraphDatabase.openReadOnly(privateStoreAt: urls.0, sharedStoreAt: urls.1, schema: .nativeIdentity)
            } else { reader = try await GraphDatabase.openReadOnly(at: urls.0, schema: .nativeIdentity) }
            database = reader
            let view = try await reader.openGraph(active.graphID); graph = view
            let query = GraphQuery<WidgetProbeItem>(budget: try GraphQueryBudget(maximumCandidates: 4096)).where(.id(active.nodeID))
            guard let item = try await view.query(query).items.first else { throw WidgetProbeStorage.Failure.mismatch }
            value = item.value
            do {
                _ = try await view.transaction { _ -> Int in throw WidgetProbeStorage.Failure.unsafeMutation }
                throw WidgetProbeStorage.Failure.unsafeMutation
            } catch GraphStoreError.readOnly { mutationRefused = true }
            guard ProcessInfo.processInfo.processIdentifier != active.ownerPID else { throw WidgetProbeStorage.Failure.mismatch }
            status = "ready"
        } catch WidgetProbeStorage.Failure.missingManifest { status = "open-app-first" }
        catch GraphStoreError.missingStore { status = "store-not-ready" }
        catch { let error = error as NSError; status = "error:\(error.domain):\(error.code)" }
        do { try await graph?.close(); try await database?.close() }
        catch { status = "close-failed" }
        let evidence = WidgetProbeEvidence(date: Date(), processID: ProcessInfo.processInfo.processIdentifier,
            runID: manifest?.runID, status: status, value: value, mirrorRefused: mirrorRefused,
            mutationRefused: mutationRefused, ownerPID: manifest?.ownerPID)
        if let root {
            do { try WidgetProbeStorage.record(evidence, root: root) }
            catch { return WidgetProbeEvidence(date: Date(), processID: evidence.processID, runID: evidence.runID,
                status: "evidence-write-failed", value: value, mirrorRefused: mirrorRefused,
                mutationRefused: mutationRefused, ownerPID: evidence.ownerPID) }
        }
        return evidence
    }
}
