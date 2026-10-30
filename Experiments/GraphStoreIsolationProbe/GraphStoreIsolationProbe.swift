import Foundation
import GraphEvo
import UIKit

/// GI01 observes native import scope; it does not implement a production controller.
@MainActor final class GraphStoreIsolationProbeViewController: UIViewController {
    private struct Fixture: Codable {
        let a: GraphID; let b: GraphID
        let rootA: GraphNodeID; let childA: GraphNodeID; let edgeA: GraphNodeID; let actionA: GraphNodeID
        let rootB: GraphNodeID; let childB: GraphNodeID; let edgeB: GraphNodeID; let actionB: GraphNodeID
        let marker: String
    }
    private struct Envelope<Value: Codable>: Codable { let run: UUID; let value: Value }
    private struct Sample: Codable {
        let resource: String; let intendedGraph: String
        let catalogHasA: Bool; let catalogHasB: Bool
        let completeA: Bool; let completeB: Bool; let unrelatedGraphCount: Int
        var containsOtherGraph: Bool { intendedGraph == "A" ? completeB : completeA }
    }
    private struct Report: Codable {
        let stage: String; let processID: Int32; let launchTicket: String?
        var succeeded = false
        var physicalIsolationCounterexample = false
        var distinctNativeBoundaries: Bool?
        var openedNativeOwnerCount: Int?
        var inspectionDeferredUntilClosed: Bool?
        var samples: [Sample] = []
        var checks: [String] = []
        var errorDomain: String?; var errorCode: Int?
    }
    private enum Failure: Error { case arguments, replay, fixture, deadline }
    private let arguments: [String]
    private let output = UITextView()
    private var owners: [GraphDatabase] = []
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    func startProbe() { loadViewIfNeeded(); Task { await run() } }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func log(_ message: String) { output.text += message + "\n"; print("GI01: " + message) }
    private func write<Value: Codable>(_ value: Value, at url: URL, run: UUID) throws {
        try JSONEncoder().encode(Envelope(run: run, value: value)).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<Value: Codable>(_ type: Value.Type, at url: URL, run: UUID) throws -> Value {
        let value = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: url))
        guard value.run == run else { throw Failure.fixture }; return value.value
    }
    private func open(_ directory: URL, container: String, paired: Bool) async throws -> GraphDatabase {
        let db: GraphDatabase
        if paired {
            db = try await GraphDatabase.openMirrored(privateStoreAt: directory.appendingPathComponent("private.sqlite"),
                sharedStoreAt: directory.appendingPathComponent("shared.sqlite"), containerIdentifier: container, schema: .nativeIdentity)
        } else {
            db = try await GraphDatabase.openMirrored(at: directory.appendingPathComponent("private.sqlite"),
                containerIdentifier: container, schema: .nativeIdentity)
        }
        owners.append(db)
        for _ in 0..<120 {
            let status = try await db.cloudSetupStatus()
            if status.storeCount == status.readyStoreCount { return db }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.deadline
    }
    private func seedGraph(_ graph: GraphStore, root: GraphNodeID, child: GraphNodeID,
                           edge: GraphNodeID, action: GraphNodeID, label: String, marker: String) async throws {
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: root, type: "GI01.root", properties: ["graph": .string(label), "marker": .string(marker)]))
            try scope.insert(GraphRecord(id: child, type: "GI01.child", properties: ["value": .integer(label == "A" ? 101 : 202)]))
            try scope.insert(GraphRecord(id: edge, type: "GI01.edge", endpoints: .relationship(subject: root, object: child)))
            try scope.insert(GraphRecord(id: action, type: "GI01.action", endpoints: .action(subjects: [root], objects: [child])))
        }
    }
    private func prepare(_ db: GraphDatabase, graph: GraphID) async throws -> GraphMirrorBoundary {
        for _ in 0..<90 {
            do { return try await db.prepareMirroring(for: graph) }
            catch GraphMirroringError.metadataUnavailable { try await Task.sleep(for: .seconds(2)) }
        }
        throw Failure.deadline
    }
    private func complete(_ db: GraphDatabase, fixture f: Fixture, a: Bool) async -> Bool {
        do {
            let graph = try await db.openGraph(a ? f.a : f.b)
            do {
                let root = a ? f.rootA : f.rootB, child = a ? f.childA : f.childB
                let edge = a ? f.edgeA : f.edgeB, action = a ? f.actionA : f.actionB
                let label = a ? "A" : "B"
                let valid = try await graph.read { scope in
                    try scope.record(for: root)?.properties == ["graph": .string(label), "marker": .string(f.marker)]
                    && scope.record(for: child)?.properties == ["value": .integer(a ? 101 : 202)]
                    && scope.record(for: edge)?.endpoints == .relationship(subject: root, object: child)
                    && scope.record(for: action)?.endpoints == .action(subjects: [root], objects: [child])
                }
                let count = try await db.validateIntegrity(of: graph.id)
                try await graph.close()
                return valid && count == 4
            } catch { try? await graph.close(); throw error }
        } catch { return false }
    }
    private func sample(_ db: GraphDatabase, label: String, intended: String, fixture: Fixture) async throws -> Sample {
        let ids = try await db.graphIDs()
        return Sample(resource: label, intendedGraph: intended, catalogHasA: ids.contains(fixture.a),
            catalogHasB: ids.contains(fixture.b), completeA: await complete(db, fixture: fixture, a: true),
            completeB: await complete(db, fixture: fixture, a: false), unrelatedGraphCount: ids.filter { $0 != fixture.a && $0 != fixture.b }.count)
    }
    /// A positive foreign-graph observation is decisive. Timeout never certifies isolation.
    private func observe(_ a: GraphDatabase, _ b: GraphDatabase, prefix: String, fixture: Fixture) async throws -> [Sample] {
        var samples: [Sample] = []
        for attempt in 0..<150 {
            do {
                samples = [try await sample(a, label: prefix + "-A", intended: "A", fixture: fixture),
                           try await sample(b, label: prefix + "-B", intended: "B", fixture: fixture)]
                if samples.allSatisfy({ $0.completeA && $0.completeB }) { return samples }
            } catch {
                if attempt == 149 { throw error }
            }
            if attempt % 20 == 0 { log("Observing native import scope; no writes or reassignments.") }
            try await Task.sleep(for: .seconds(2))
        }
        return samples
    }
    private func run() async {
        var reportURL: URL?, runID: UUID?
        let ticket = arguments.firstIndex(of: "--launch-ticket").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        var report = Report(stage: "invalid", processID: ProcessInfo.processInfo.processIdentifier, launchTicket: ticket)
        do {
            guard let flag = arguments.firstIndex(of: "--graph-isolation"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 2]),
                  let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  container == "iCloud.com.valerioburiani.GraphCKDemo" else { throw Failure.arguments }
            let stage = arguments[flag + 1]; runID = run
            guard ["prepare", "identity", "seed-recover", "accept-separate", "recover-shared", "recover-A-only"].contains(stage) else { throw Failure.arguments }
            report = Report(stage: stage, processID: report.processID, launchTicket: ticket)
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/GraphStoreIsolation/" + run.uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let output = root.appendingPathComponent(stage + ".report.json")
            guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.replay }
            try Data("reserved".utf8).write(to: output, options: .withoutOverwriting); reportURL = output
            if stage == "prepare" {
                // Prepare transport destination without creating any graph or claiming cloud emptiness.
                report.checks.append("owner-case-directory-prepared")
            } else if stage == "identity" {
                let db = try await open(root.appendingPathComponent("recipient-identity"), container: container, paired: true)
                try write(try await db.sharingIdentity(), at: root.appendingPathComponent("identity.json"), run: run)
                report.checks.append("recipient-identity-transport")
            } else if stage == "seed-recover" {
                let dbA = try await open(root.appendingPathComponent("original-A"), container: container, paired: false)
                let dbB = try await open(root.appendingPathComponent("original-B"), container: container, paired: false)
                let a = try await dbA.createGraph(), b = try await dbB.createGraph()
                let f = Fixture(a: a.id, b: b.id, rootA: a.makeNodeID(), childA: a.makeNodeID(), edgeA: a.makeNodeID(), actionA: a.makeNodeID(),
                    rootB: b.makeNodeID(), childB: b.makeNodeID(), edgeB: b.makeNodeID(), actionB: b.makeNodeID(), marker: run.uuidString)
                try write(f, at: root.appendingPathComponent("fixture.json"), run: run)
                try await seedGraph(a, root: f.rootA, child: f.childA, edge: f.edgeA, action: f.actionA, label: "A", marker: f.marker)
                try await seedGraph(b, root: f.rootB, child: f.childB, edge: f.edgeB, action: f.actionB, label: "B", marker: f.marker)
                try await a.close(); try await b.close()
                let zoneA = try await prepare(dbA, graph: f.a), zoneB = try await prepare(dbB, graph: f.b)
                report.distinctNativeBoundaries = zoneA.zoneName != zoneB.zoneName
                guard report.distinctNativeBoundaries == true else { throw Failure.fixture }
                let identity = try read(GraphSharingIdentity.self, at: root.appendingPathComponent("identity.json"), run: run)
                try write(try await dbA.invite(identity, to: f.a), at: root.appendingPathComponent("invitation-A.json"), run: run)
                try write(try await dbB.invite(identity, to: f.b), at: root.appendingPathComponent("invitation-B.json"), run: run)
                report.checks += ["one-graph-seeded-per-original-store", "distinct-owner-share-zones", "two-recipient-invitations"]
                for name in ["fresh-private-A", "fresh-private-B"] {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else { throw Failure.replay }
                }
                let freshA = try await open(root.appendingPathComponent("fresh-private-A"), container: container, paired: false)
                let freshB = try await open(root.appendingPathComponent("fresh-private-B"), container: container, paired: false)
                report.samples = try await observe(freshA, freshB, prefix: "fresh-private", fixture: f)
                report.samples += [try await sample(dbA, label: "original-A", intended: "A", fixture: f),
                                   try await sample(dbB, label: "original-B", intended: "B", fixture: f)]
                report.physicalIsolationCounterexample = report.samples.contains { $0.containsOtherGraph }
                guard report.samples.count >= 2, report.samples[0].completeA, report.samples[1].completeB else { throw Failure.deadline }
                report.checks.append("fresh-private-resources-no-source-files")
            } else if stage == "recover-A-only" {
                let f = try read(Fixture.self, at: root.appendingPathComponent("fixture.json"), run: run)
                let directory = root.appendingPathComponent("single-private-A")
                guard owners.isEmpty, !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.replay }
                let db = try await open(directory, container: container, paired: false)
                report.openedNativeOwnerCount = owners.count
                guard report.openedNativeOwnerCount == 1 else { throw Failure.fixture }
                var recoveredA = false
                for _ in 0..<120 {
                    if await complete(db, fixture: f, a: true) { recoveredA = true; break }
                    try await Task.sleep(for: .seconds(2))
                }
                guard recoveredA else { throw Failure.deadline }
                log("Only A was opened; retaining the sole native owner for a bounded import window.")
                for _ in 0..<45 { try await Task.sleep(for: .seconds(2)) }
                // Do not open B, inspect its catalog or validate its content while cloud is active.
                // Collect this closed store and inspect B offline, with no CloudKit container.
                try await db.close()
                report.inspectionDeferredUntilClosed = true
                report.checks += ["one-native-owner-only", "fresh-single-private-resource", "A-content-recovered", "no-store-B-opened", "no-graph-B-handle-opened", "no-application-writes", "bounded-90-second-window", "native-owner-closed-before-offline-inspection"]
            } else {
                let f = try read(Fixture.self, at: root.appendingPathComponent("fixture.json"), run: run)
                let prefix = stage == "recover-shared" ? "fresh-pair" : "participant-pair"
                for suffix in ["A", "B"] {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(prefix + "-" + suffix).path) else { throw Failure.replay }
                }
                let a = try await open(root.appendingPathComponent(prefix + "-A"), container: container, paired: true)
                let b = try await open(root.appendingPathComponent(prefix + "-B"), container: container, paired: true)
                try await a.acceptInvitation(read(GraphInvitation.self, at: root.appendingPathComponent("invitation-A.json"), run: run))
                try await b.acceptInvitation(read(GraphInvitation.self, at: root.appendingPathComponent("invitation-B.json"), run: run))
                report.samples = try await observe(a, b, prefix: prefix, fixture: f)
                report.physicalIsolationCounterexample = report.samples.contains { $0.containsOtherGraph }
                guard report.samples.count == 2, report.samples[0].completeA, report.samples[1].completeB else { throw Failure.deadline }
                report.checks.append("independent-pairs-no-native-store-transfer")
            }
            report.succeeded = true
            log(report.physicalIsolationCounterexample ? "Observed complete foreign graph in a dedicated resource: physical isolation fails." : "Stage completed; absence is not proof of physical isolation.")
        } catch {
            let failure = error as NSError; report.errorDomain = failure.domain; report.errorCode = failure.code
            log("Stage failure; inspect the protected report. Do not replay mutations.")
        }
        if let reportURL, let runID { try? write(report, at: reportURL, run: runID) }
    }
}
