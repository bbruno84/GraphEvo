import Foundation
import GraphEvo
import UIKit

private struct PublicMirrorItem: GraphModel {
    static let graphType = "NativePublic.Item"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let name: String
    init(id: GraphNodeID, name: String) { self.id = id; self.name = name }
    init(graphRecord: GraphRecord) throws { id = graphRecord.id; name = try graphRecord.value(for: "name") }
    func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType, properties: ["name": .string(name)]) }
}

/// An external app consumer: no testable imports, package access or native contexts.
@MainActor final class PublicMirroredProbeViewController: UIViewController {
    private enum Failure: Error { case arguments, replay, deadline, mismatch }
    private let arguments: [String]
    private let output = UITextView()
    private var report: URL?
    private var retainedDatabase: GraphDatabase?
    private var startRequested = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        startProbe()
    }
    func startProbe() {
        guard !startRequested else { return }; startRequested = true
        Task { await run() }
    }
    private func log(_ text: String) {
        output.text += text + "\n"
        if let report { try? output.text.write(to: report, atomically: true, encoding: .utf8) }
    }
    private func run() async {
        var database: GraphDatabase?
        do {
            guard let flag = arguments.firstIndex(of: "--native-public"), arguments.count > flag + 1,
                  let run = UUID(uuidString: arguments[flag + 1]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  !identifier.isEmpty else { throw Failure.arguments }
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/NativePublicPrivate/\(run.uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ticket = folder.appendingPathComponent("private.txt")
            guard !FileManager.default.fileExists(atPath: ticket.path) else { throw Failure.replay }
            try "reserved\n".write(to: ticket, atomically: true, encoding: .utf8); report = ticket
            let url = folder.appendingPathComponent("private.sqlite")
            let db = try await GraphDatabase.openMirrored(at: url, containerIdentifier: identifier, schema: .nativeIdentity)
            database = db
            for attempt in 0..<150 {
                let setup = try await db.cloudSetupStatus()
                if setup.storeCount == 1 && setup.readyStoreCount == 1 { break }
                if attempt == 149 { throw Failure.deadline }
                try await Task.sleep(for: .seconds(2))
            }
            log("Single private native resource setup completed through the public opener.")
            let graph = try await db.createGraph()
            let item = PublicMirrorItem(id: graph.makeNodeID(), name: "public-consumer")
            try await graph.insert(item)
            let query = GraphQuery<PublicMirrorItem>(budget: try GraphQueryBudget(maximumCandidates: 512)).where(.id(item.id))
            guard try await graph.query(query).items.map(\.id) == [item.id],
                  try await db.validateIntegrity(of: graph.id) == 1 else { throw Failure.mismatch }
            let observed = try await graph.observe(query)
            var iterator = observed.makeAsyncIterator()
            guard case .value(let result) = await iterator.next(), result.items.map(\.id) == [item.id] else {
                observed.cancel(); throw Failure.mismatch
            }
            observed.cancel()
            for attempt in 0..<90 {
                do { _ = try await db.prepareMirroring(for: graph.id); break }
                catch GraphMirroringError.metadataUnavailable {
                    if attempt == 89 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2))
                }
            }
            for attempt in 0..<150 {
                let mapping = try await db.inspectMirroring(for: graph.id)
                if mapping.boundary != nil && mapping.nativeObjectCount > 0 && mapping.pendingMappingCount == 0 && mapping.unexpectedZoneCount == 0 { break }
                if attempt == 149 { throw Failure.deadline }
                try await Task.sleep(for: .seconds(2))
            }
            log("Typed insert/query/observation/integrity and complete owner boundary mappings verified.")
            try await graph.close(); try await db.close(); database = nil
            let reopened = try await GraphDatabase.openMirrored(at: url, containerIdentifier: identifier, schema: .nativeIdentity)
            database = reopened
            let reader = try await reopened.openGraph(graph.id)
            guard try await reader.fetch(item.id, as: PublicMirrorItem.self)?.name == item.name,
                  try await reopened.validateIntegrity(of: graph.id) == 1 else { throw Failure.mismatch }
            try await reader.close()
            retainedDatabase = reopened; database = nil
            log("PASS private public API reopen; native owner retained. This is not independent replica or export completion evidence.")
        } catch {
            let ns = error as NSError
            log("FAIL domain=\(ns.domain) code=\(ns.code)")
            if let database { try? await database.close() }
        }
    }
}
