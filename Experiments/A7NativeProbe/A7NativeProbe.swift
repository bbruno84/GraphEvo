import Foundation
import GraphEvo
import UIKit

private struct A7Entity: GraphModel {
    static let graphType = "A5.entity"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}
private struct A7Edge: GraphModel {
    static let graphType = "A5.edge"
    static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}
private struct A7Action: GraphModel {
    static let graphType = "A5.action"
    static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

/// Read-only application queries on the retained A5 owner fixture. Never reseeds or changes sharing.
@MainActor final class A7NativeProbeViewController: UIViewController {
    private struct Fixture: Codable { let a: GraphID; let b: GraphID; let members: [GraphNodeID] }
    private struct Transport: Codable { let runID: UUID; let value: Fixture }
    private enum Failure: Error { case arguments, replay, fixture }
    private let arguments: [String]
    private let output = UITextView()
    private var report: URL?
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await run() }
    }
    private func log(_ text: String) {
        output.text += text + "\n"; print("A7: " + text)
        if let report { try? output.text.write(to: report, atomically: true, encoding: .utf8) }
    }
    private func run() async {
        do {
            guard let flag = arguments.firstIndex(of: "--a7"), arguments.count > flag + 1,
                  let runID = UUID(uuidString: arguments[flag + 1]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { throw Failure.arguments }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/A5/\(runID.uuidString)")
            let ticket = root.appendingPathComponent("a7-queries.txt")
            guard !FileManager.default.fileExists(atPath: ticket.path) else { throw Failure.replay }
            let transport = try JSONDecoder().decode(Transport.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            guard transport.runID == runID else { throw Failure.fixture }
            try "reserved\n".write(to: ticket, atomically: true, encoding: .utf8); report = ticket
            let fixture = transport.value
            let db = try await GraphDatabase.openMirrored(privateStoreAt: root.appendingPathComponent("private.sqlite"),
                sharedStoreAt: root.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier)
            let a = try await db.openGraph(fixture.a), b = try await db.openGraph(fixture.b)
            let budget = try GraphQueryBudget(maximumCandidates: 5000, maximumSteps: 100_000)
            let entities = GraphQuery<A7Entity>(budget: budget)
            let filtered = try await a.query(entities.where(.tag("original")).where(.property("label", .beginsWith, .string("participant"))))
            guard filtered.items.map(\.id) == [fixture.members[0]], try await a.count(entities).value == 3,
                  try await b.count(entities).value == 2 else { throw Failure.fixture }
            log("Typed filters use AND and separate A/B despite the shared model type.")
            let edges = GraphQuery<A7Edge>(budget: budget).where(.subject(fixture.members[0]))
            let actions = GraphQuery<A7Action>(budget: budget).where(.object(fixture.members[1]))
            guard try await a.count(edges).value == 2, try await a.count(actions).value == 2,
                  try await a.count(entities.where(.related(.outgoing("A5.edge"), matching: .tag("original")))).value == 2 else { throw Failure.fixture }
            log("Relationship/action endpoint and related-node predicates match the retained graph.")
            let projection = try await a.project(entities, properties: ["label"])
            let sum = try await a.aggregate(entities, .sum("count"))
            guard projection.rows.count == 3, projection.rows.allSatisfy({ $0.values.count == 1 }),
                  sum.value == .integer(7), sum.contributingCount == 1 else { throw Failure.fixture }
            let page = entities.sorted(by: [GraphQuerySort(.property("label"))]).limit(1)
            let first = try await a.query(page)
            guard let cursor = first.nextCursor else { throw Failure.fixture }
            let next = try await a.query(page.limit(2).after(cursor))
            guard first.items.count == 1, next.items.count == 2,
                  Set((first.items + next.items).map(\.id)).count == 3, next.nextCursor == nil else { throw Failure.fixture }
            log("Projection, integer sum and current-state keyset pages verified.")
            let traversal = try GraphTraversal(from: [fixture.members[0]], via: .outgoing("A5.edge"), maximumDepth: 5, budget: budget)
            let visits = try await a.traverse(traversal)
            let added = GraphNodeID(graphID: fixture.a, rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
            guard Set(visits.visits.map(\.id)) == [fixture.members[1], added], visits.visits.allSatisfy({ $0.depth == 1 }) else { throw Failure.fixture }
            do { _ = try await a.query(entities.where(.id(fixture.members[5]))); throw Failure.fixture }
            catch GraphQueryError.foreignGraph { }
            do { _ = try await a.query(GraphQuery<A7Entity>(budget: GraphQueryBudget(maximumCandidates: 1))); throw Failure.fixture }
            catch GraphQueryError.budgetExceeded { }
            log("Cycle-safe traversal, cross-graph rejection and candidate-budget refusal verified.")
            log("Bounded read: native candidates=\(filtered.diagnostics.nativeCandidates), scoped nodes=\(filtered.diagnostics.scopedNodes), charged bytes=\(filtered.diagnostics.propertyBytesCharged), steps=\(filtered.diagnostics.evaluationSteps).")
            try await a.close(); try await b.close(); try await db.close()
            log("PASS read-only A7; no application mutations, invitations or share operations requested.")
        } catch {
            let error = error as NSError; log("FAIL domain=\(error.domain) code=\(error.code)")
        }
    }
}
