import Foundation
import GraphEvo
import UIKit

private struct C02Item: GraphModel {
    static let graphType = "A8.entity"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

/// Read-only application API checks against retained A6/A8 stores; no stage or mutation is replayed.
@MainActor final class C02NativeProbeViewController: UIViewController {
    private struct Fixture: Codable { let a: GraphID; let b: GraphID; let control: GraphAttachmentMetadata }
    private struct Envelope: Codable { let runID: UUID; let value: Fixture }
    private enum Failure: Error { case arguments, replay, fixture }
    private let arguments: [String]
    private let output = UITextView()
    private var report: URL?
    private var database: GraphDatabase?
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await run() }
    }
    private func log(_ value: String) {
        output.text += value + "\n"; print("C02: " + value)
        if let report { try? output.text.write(to: report, atomically: true, encoding: .utf8) }
    }
    private func run() async {
        do {
            guard let flag = arguments.firstIndex(of: "--c02"), arguments.count > flag + 2,
                  let ticket = UUID(uuidString: arguments[flag + 2]),
                  ["owner", "participant"].contains(arguments[flag + 1]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { throw Failure.arguments }
            let owner = arguments[flag + 1] == "owner"
            let run = UUID(uuidString: "291F43CA-76F3-4B93-B780-B6CFC8DD5F7D")!
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/A6/\(run.uuidString)")
            let reportURL = root.appendingPathComponent("c02-read-\(ticket.uuidString).txt")
            guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw Failure.replay }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            guard envelope.runID == run else { throw Failure.fixture }
            try "reserved\n".write(to: reportURL, atomically: true, encoding: .utf8); report = reportURL
            let db = try await GraphDatabase.openMirrored(privateStoreAt: root.appendingPathComponent("private.sqlite"),
                sharedStoreAt: root.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier)
            database = db
            let fixture = envelope.value, graph = try await db.openGraph(fixture.a)
            guard try await db.pendingSharedOperations().isEmpty else { throw Failure.fixture }
            let query = GraphQuery<C02Item>(budget: try GraphQueryBudget(maximumCandidates: 5000))
            let result = try await graph.query(query)
            guard result.items.count == 1, result.items[0].id.graphID == fixture.a,
                  try await graph.fetch(result.items[0].id, as: C02Item.self)?.record == result.items[0].record,
                  try await graph.count(query).value == 1 else { throw Failure.fixture }
            log("Retained A8 parent identity, typed query, count and ID fetch agree.")
            if owner {
                let control = try await db.openGraph(fixture.b)
                let file = try await control.attachment(fixture.control.id)
                guard file?.metadata == fixture.control, file?.data == Data(repeating: 47, count: 512) else { throw Failure.fixture }
                try await control.close()
                log("Owner B control retains exact metadata and bytes.")
            } else {
                guard !(try await db.graphIDs()).contains(fixture.b) else { throw Failure.fixture }
                log("Participant catalog excludes owner-only B.")
            }
            try await graph.close(); try await db.close()
            log("PASS read-only C02 metadata access on existing native private/shared resources.")
        } catch {
            let error = error as NSError; log("FAIL domain=\(error.domain) code=\(error.code)")
        }
    }
}
