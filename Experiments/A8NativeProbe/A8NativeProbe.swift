import Combine
import Foundation
import GraphEvo
import UIKit

private struct A8Entity: GraphModel {
    static let graphType = "A8.entity"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

/// One-use stages on the retained A6 share. Sensitive fixture values never enter diagnostics.
@MainActor final class A8NativeProbeViewController: UIViewController {
    private struct OriginalFixture: Codable { let a: GraphID; let b: GraphID; let control: GraphAttachmentMetadata }
    private struct Fixture: Codable { let a: GraphID; let b: GraphID; let first: GraphNodeID; let second: GraphNodeID; let edge: GraphNodeID }
    private struct Transport<Value: Codable>: Codable { let runID: UUID; let value: Value }
    private enum Failure: Error { case arguments, replay, fixture, deadline }
    private let arguments: [String]
    private let output = UITextView()
    private var report: URL?
    private var database: GraphDatabase?
    private var graphs: [GraphStore] = []
    private var observations: [GraphObservation<GraphQueryState<A8Entity>>] = []
    private var tasks: [Task<Void, Never>] = []
    private var cancellable: AnyCancellable?
    private var firstID: GraphNodeID?
    private var ready = Set<String>(), present = Set<String>(), absent = Set<String>()
    private var passed = false
    private var invalid = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        tasks.append(Task { await run() })
    }
    private func log(_ value: String) {
        output.text += value + "\n"; print("A8: " + value)
        if let report { try? output.text.write(to: report, atomically: true, encoding: .utf8) }
    }
    private func received(_ state: GraphQueryState<A8Entity>, source: String) {
        switch state {
        case .failure(let error):
            let error = error as NSError
            log("Transient refresh failure source=\(source) domain=\(error.domain) code=\(error.code).")
        case .value(let result):
            let ids = result.items.map(\.id)
            guard ids.isEmpty || ids == firstID.map({ [$0] }) else { invalid = true; log("FAIL unexpected related result."); return }
            if ids.isEmpty, !present.contains(source) { ready.insert(source) }
            if !ids.isEmpty { present.insert(source) }
            if ids.isEmpty, present.contains(source) { absent.insert(source) }
            if ready == ["async", "combine", "fixture"] { log("READY both live adapters initial-empty; fixture recovered."); ready.insert("reported") }
            if present == ["async", "combine"] { log("ON-BOTH related membership recovered without polling."); present.insert("reported") }
            if absent == ["async", "combine"], !passed, !invalid {
                passed = true; log("PASS both live adapters recovered related deletion without polling or resubscription.")
            }
        }
    }
    private func run() async {
        do {
            guard let flag = arguments.firstIndex(of: "--a8"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { throw Failure.arguments }
            let stage = arguments[flag + 1], files = FileManager.default
            let base = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GraphEvoLaboratory")
            let root = base.appendingPathComponent("A8/\(run.uuidString)")
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            let ticket = root.appendingPathComponent(stage + ".txt")
            guard !files.fileExists(atPath: ticket.path) else { throw Failure.replay }
            try "reserved\n".write(to: ticket, atomically: true, encoding: .utf8); report = ticket
            let a6run = UUID(uuidString: "291F43CA-76F3-4B93-B780-B6CFC8DD5F7D")!
            let original = base.appendingPathComponent("A6/\(a6run.uuidString)")
            let envelope = try JSONDecoder().decode(Transport<OriginalFixture>.self, from: Data(contentsOf: original.appendingPathComponent("fixture.json")))
            guard envelope.runID == a6run else { throw Failure.fixture }
            let db = try await GraphDatabase.openMirrored(privateStoreAt: original.appendingPathComponent("private.sqlite"),
                sharedStoreAt: original.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier)
            database = db
            guard try await db.pendingSharedOperations().isEmpty else { throw Failure.fixture }
            let fixtureURL = root.appendingPathComponent("fixture.json")
            let fixture: Fixture
            if stage == "seed" {
                fixture = Fixture(a: envelope.value.a, b: envelope.value.b,
                    first: GraphNodeID(graphID: envelope.value.a), second: GraphNodeID(graphID: envelope.value.a), edge: GraphNodeID(graphID: envelope.value.a))
                try JSONEncoder().encode(Transport(runID: run, value: fixture)).write(to: fixtureURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                let transport = try JSONDecoder().decode(Transport<Fixture>.self, from: Data(contentsOf: fixtureURL))
                guard transport.runID == run else { throw Failure.fixture }; fixture = transport.value
            }
            guard fixture.a == envelope.value.a, fixture.b == envelope.value.b else { throw Failure.fixture }
            let graph = try await db.openGraph(fixture.a); graphs.append(graph); firstID = fixture.first
            let query = GraphQuery<A8Entity>(budget: try GraphQueryBudget(maximumCandidates: 5000))
            if stage == "watch" {
                guard !(try await db.graphIDs()).contains(fixture.b) else { throw Failure.fixture }
                let related = query.where(.related(.outgoing("A8.edge"), matching: .property("state", .equal, .string("on"))))
                let observation = try await graph.observe(related); observations.append(observation)
                tasks.append(Task { for await value in observation { received(value, source: "async") } })
                cancellable = graph.publisher(for: related).receive(on: DispatchQueue.main).sink(receiveCompletion: { completion in
                    if case .failure = completion { self.invalid = true; self.log("FAIL Combine subscription terminated.") }
                }, receiveValue: { self.received($0, source: "combine") })
                let initial = try await graph.observe(query); observations.append(initial)
                tasks.append(Task {
                    for await value in initial {
                        if case .value(let result) = value, Set(result.items.map(\.id)) == [fixture.first, fixture.second] {
                            ready.insert("fixture")
                            // A manual first-state check does not refresh either related observer.
                            log("Initial fixture recovered; waiting for both related observers.")
                            if ready == ["async", "combine", "fixture"] { log("READY both live adapters initial-empty; fixture recovered."); ready.insert("reported") }
                            initial.cancel(); break
                        }
                    }
                })
                tasks.append(Task { try? await Task.sleep(for: .seconds(240)); if !passed { log("FAIL bounded live observation deadline.") } })
                return
            }
            let b = try await db.openGraph(fixture.b); graphs.append(b)
            let control = try await b.attachment(envelope.value.control.id)
            guard control?.metadata == envelope.value.control, control?.data == Data(repeating: 47, count: 512) else { throw Failure.fixture }
            if stage == "seed" {
                guard try await graph.count(query).value == 0 else { throw Failure.fixture }
                try await graph.transaction { scope in
                    try scope.insert(GraphRecord(id: fixture.first, type: A8Entity.graphType))
                    try scope.insert(GraphRecord(id: fixture.second, type: A8Entity.graphType, properties: ["state": .string("off")]))
                    try scope.insert(GraphRecord(id: fixture.edge, type: "A8.edge", endpoints: .relationship(subject: fixture.first, object: fixture.second)))
                }
                log("PASS seed; two entities and one edge saved in retained A; B unchanged. Owner retained.")
            } else if stage == "on" {
                let before = try await graph.read { try $0.record(for: fixture.second) }
                guard before?.properties["state"] == .string("off") else { throw Failure.fixture }
                try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: fixture.second, properties: ["state": .set(.string("on"))])) }
                log("PASS local child-property edit; queried parent untouched; B unchanged. Owner retained.")
            } else if stage == "delete" {
                let before = try await graph.read { try $0.record(for: fixture.second) }
                guard before?.properties["state"] == .string("on") else { throw Failure.fixture }
                try await graph.delete(fixture.second)
                log("PASS local child/edge deletion; queried parent retained; B unchanged. Owner retained.")
            } else { throw Failure.arguments }
            guard try await b.attachment(envelope.value.control.id) == control else { throw Failure.fixture }
        } catch {
            let error = error as NSError; log("FAIL domain=\(error.domain) code=\(error.code)")
        }
    }
}
