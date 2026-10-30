import CloudKit
import CoreData
import Foundation
import GraphEvo
import UIKit
@testable import GraphEvo

/// MC01 uses only synthetic run-scoped data in the explicitly configured Development container.
@MainActor final class StoreCopyProbeViewController: UIViewController {
    private struct Fixture: Codable {
        let a: GraphID; let b: GraphID
        let root: GraphNodeID; let child: GraphNodeID; let doomed: GraphNodeID
        let edge: GraphNodeID; let action: GraphNodeID; let added: GraphNodeID; let control: GraphNodeID
        let file: GraphNodeID; let removedFile: GraphNodeID
    }
    private struct Envelope<Value: Codable>: Codable { let run: UUID; let value: Value }
    private struct Report: Codable {
        let stage: String; let processID: Int32; let launchTicket: String?
        var succeeded = false
        var checks: [String] = []
        var errorDomain: String?; var errorCode: Int?
    }
    private enum Failure: Error { case arguments, replay, fixture, deadline }
    private let arguments: [String]
    private let output = UITextView()
    private var owner: GraphDatabase?
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    func startProbe() { loadViewIfNeeded(); Task { await run() } }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func log(_ message: String) { output.text += message + "\n"; print("MC01: " + message) }
    private func write<Value: Codable>(_ value: Value, at url: URL, run: UUID) throws {
        try JSONEncoder().encode(Envelope(run: run, value: value)).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<Value: Codable>(_ type: Value.Type, at url: URL, run: UUID) throws -> Value {
        let result = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: url))
        guard result.run == run else { throw Failure.fixture }; return result.value
    }
    private func open(_ directory: URL, identifier: String, peer: Bool) async throws -> GraphDatabase {
        let db: GraphDatabase
        if peer {
            db = try await GraphDatabase.openMirrored(privateStoreAt: directory.appendingPathComponent("private.sqlite"),
                sharedStoreAt: directory.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier, schema: .nativeIdentity)
        } else {
            db = try await GraphDatabase.openMirrored(at: directory.appendingPathComponent("private.sqlite"),
                containerIdentifier: identifier, schema: .nativeIdentity)
        }
        owner = db
        for _ in 0..<120 {
            let status = try await db.cloudSetupStatus()
            if status.readyStoreCount == status.storeCount { return db }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.deadline
    }
    private func seed(_ db: GraphDatabase, root: URL) async throws -> Fixture {
        let a = try await db.createGraph(), b = try await db.createGraph()
        let node = a.makeNodeID(), child = a.makeNodeID(), doomed = a.makeNodeID(), edge = a.makeNodeID(), action = a.makeNodeID(), added = a.makeNodeID(), control = b.makeNodeID()
        try await a.transaction { scope in
            for id in [node, child, doomed] { try scope.insert(GraphRecord(id: id, type: "MC01.item", properties: ["label": .string("before"), "remove": .integer(1)])) }
            try scope.insert(GraphRecord(id: edge, type: "MC01.edge", endpoints: .relationship(subject: node, object: child)))
            try scope.insert(GraphRecord(id: action, type: "MC01.action", endpoints: .action(subjects: [node], objects: [child])))
        }
        _ = try await b.transaction { try $0.insert(GraphRecord(id: control, type: "MC01.control", properties: ["keep": .integer(42)])) }
        let input = root.appendingPathComponent("initial.bin")
        try Data(repeating: 173, count: 2 * 1024 * 1024).write(to: input)
        let file = try await a.importAttachment(from: input, ownedBy: node)
        let removedFile = try await a.importAttachment(from: input, ownedBy: doomed)
        try await a.close(); try await b.close()
        for id in [a.id, b.id] {
            var prepared = false
            for _ in 0..<90 {
                do { _ = try await db.prepareMirroring(for: id); prepared = true; break }
                catch GraphMirroringError.metadataUnavailable { try await Task.sleep(for: .seconds(2)) }
            }
            guard prepared else { throw Failure.deadline }
        }
        return Fixture(a: a.id, b: b.id, root: node, child: child, doomed: doomed, edge: edge, action: action,
            added: added, control: control, file: file.id, removedFile: removedFile.id)
    }
    private func check(_ db: GraphDatabase, fixture f: Fixture, after: Bool, peer: Bool) async throws {
        let graph = try await db.openGraph(f.a)
        do {
            let label = try await graph.read { try $0.record(for: f.root)?.properties["label"] }
            guard label == .string(after ? "after" : "before"),
                  try await graph.read({ try $0.record(for: f.root)?.properties["remove"] }) == (after ? nil : .integer(1)),
                  try await graph.read({ try $0.record(for: f.edge)?.endpoints }) == .relationship(subject: f.root, object: after ? f.added : f.child),
                  try await graph.read({ try $0.record(for: f.action)?.endpoints }) == .action(subjects: [f.root], objects: [f.child]),
                  try await graph.attachment(f.file)?.data == Data(repeating: after ? 31 : 173, count: (after ? 3 : 2) * 1024 * 1024),
                  (try await graph.read { try $0.record(for: f.added) != nil }) == after,
                  (try await graph.attachment(f.removedFile) == nil) == after,
                  try await db.validateIntegrity(of: f.a) == (after ? 6 : 7) else { throw Failure.fixture }
            let mapping = try await db.inspectMirroring(for: f.a)
            guard mapping.boundary != nil, mapping.pendingMappingCount == 0, mapping.unexpectedZoneCount == 0 else { throw Failure.fixture }
            if peer { guard !(try await db.graphIDs()).contains(f.b) else { throw Failure.fixture } }
            else {
                let control = try await db.openGraph(f.b)
                let value = try await control.read { try $0.record(for: f.control)?.properties["keep"] }
                try await control.close()
                let other = try await db.inspectMirroring(for: f.b)
                guard value == .integer(42), other.boundary != nil,
                      other.boundary?.zoneName != mapping.boundary?.zoneName,
                      other.pendingMappingCount == 0, other.unexpectedZoneCount == 0 else { throw Failure.fixture }
            }
            try await graph.close()
        } catch { try? await graph.close(); throw error }
    }
    private func wait(_ db: GraphDatabase, fixture: Fixture, after: Bool, peer: Bool) async throws {
        for attempt in 0..<150 {
            do { try await check(db, fixture: fixture, after: after, peer: peer); return }
            catch {
                if attempt == 149 { throw error }
                if attempt % 20 == 0 { log("Waiting for exact fixture, content and native mappings.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func edit(_ work: URL, fixture f: Fixture, root: URL) async throws {
        let db = try await GraphDatabase.open(at: work, schema: .nativeIdentity), graph = try await db.openGraph(f.a)
        do {
            let transient = graph.makeNodeID()
            try await graph.transaction { scope in
                _ = try scope.patch(GraphRecordPatch(id: f.root, properties: ["label": .set(.string("after")), "remove": .remove]))
                try scope.insert(GraphRecord(id: f.added, type: "MC01.item", properties: ["new": .boolean(true)]))
                _ = try scope.patch(GraphRecordPatch(id: f.edge, endpoints: .relationship(subject: f.root, object: f.added)))
                try scope.delete(f.doomed)
                try scope.insert(GraphRecord(id: transient, type: "MC01.transient")); try scope.delete(transient)
            }
            let input = root.appendingPathComponent("replacement.bin")
            try Data(repeating: 31, count: 3 * 1024 * 1024).write(to: input)
            _ = try await graph.replaceAttachment(f.file, from: input)
            try await graph.close(); try await db.close()
        } catch { try? await graph.close(); try? await db.close(); throw error }
    }
    private func run() async {
        var reportURL: URL?, runID: UUID?
        var report = Report(stage: "invalid", processID: ProcessInfo.processInfo.processIdentifier,
            launchTicket: arguments.firstIndex(of: "--launch-ticket").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil })
        do {
            guard let flag = arguments.firstIndex(of: "--store-copy"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  identifier == "iCloud.com.valerioburiani.GraphCKDemo" else { throw Failure.arguments }
            let stage = arguments[flag + 1]; runID = run
            guard ["prepare", "identity", "seed", "peer-before", "copy-publish", "peer-after", "peer-fresh", "owner-final"].contains(stage) else { throw Failure.arguments }
            report = Report(stage: stage, processID: report.processID, launchTicket: report.launchTicket)
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/StoreCopy/" + run.uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let output = root.appendingPathComponent(stage + ".report.json")
            guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.replay }
            try Data("reserved".utf8).write(to: output, options: .withoutOverwriting); reportURL = output
            let peer = stage == "identity" || stage.hasPrefix("peer")
            let directory = root.appendingPathComponent(stage == "peer-fresh" ? "fresh" : "live")
            if stage == "peer-fresh", FileManager.default.fileExists(atPath: directory.path) { throw Failure.replay }
            let db = try await open(directory, identifier: identifier, peer: peer)
            let fixtureURL = root.appendingPathComponent("fixture.json"), invitationURL = root.appendingPathComponent("invitation.json")
            if stage == "prepare" {
                report.checks.append("empty-local-owner-prepared")
            } else if stage == "identity" {
                try write(try await db.sharingIdentity(), at: root.appendingPathComponent("identity.json"), run: run)
                report.checks.append("recipient-transport-written")
            } else if stage == "seed" {
                let fixture = try await seed(db, root: root)
                try write(fixture, at: fixtureURL, run: run)
                let identity = try read(GraphSharingIdentity.self, at: root.appendingPathComponent("identity.json"), run: run)
                try write(try await db.invite(identity, to: fixture.a), at: invitationURL, run: run)
                try await wait(db, fixture: fixture, after: false, peer: false)
                report.checks.append("seed-shares-content-control")
            } else {
                let fixture = try read(Fixture.self, at: fixtureURL, run: run)
                if stage == "copy-publish" {
                    try await wait(db, fixture: fixture, after: false, peer: false)
                    let boundary = try await db.inspectMirroring(for: fixture.a).boundary
                    try await db.close(); owner = nil
                    let source = directory.appendingPathComponent("private.sqlite")
                    let before = try GraphStoreCopyLaboratory.history(at: source)
                    try GraphStoreCopyLaboratory.copyClosed(from: source, to: root.appendingPathComponent("backup/private.sqlite"), method: .directory)
                    let work = root.appendingPathComponent("work/private.sqlite")
                    try GraphStoreCopyLaboratory.copyClosed(from: source, to: work, method: .coreData)
                    let copy = try GraphStoreCopyLaboratory.history(at: work)
                    guard copy.storeID == before.storeID, copy.transactions == before.transactions else { throw Failure.fixture }
                    try await edit(work, fixture: fixture, root: root)
                    let delta = try GraphStoreCopyLaboratory.history(at: work, after: before.lastToken)
                    guard delta.inserts > 0, delta.updates > 0, delta.deletes > 0 else { throw Failure.fixture }
                    try GraphStoreCopyLaboratory.replaceClosed(from: work, at: source)
                    let published = try GraphStoreCopyLaboratory.history(at: source, after: before.lastToken)
                    guard published.storeID == before.storeID, published.changes == delta.changes else { throw Failure.fixture }
                    report.checks += ["closed-source-backup", "history-and-store-identity-preserved", "local-only-copy-edits-published"]
                    // No post-open application save: the copied history alone must drive export.
                    let reopened = try await open(directory, identifier: identifier, peer: false)
                    try await wait(reopened, fixture: fixture, after: true, peer: false)
                    guard try await reopened.inspectMirroring(for: fixture.a).boundary == boundary else { throw Failure.fixture }
                    report.checks.append("same-share-boundary-and-complete-native-mappings")
                } else {
                    if stage == "peer-before" || stage == "peer-fresh" {
                        try await db.acceptInvitation(read(GraphInvitation.self, at: invitationURL, run: run))
                    }
                    try await wait(db, fixture: fixture, after: stage != "peer-before", peer: peer)
                    report.checks.append(stage == "peer-before" ? "independent-baseline" : "independent-migrated-content-topology-deletions")
                    if stage == "peer-fresh" { report.checks.append("fresh-native-pair-no-source-files") }
                }
            }
            report.succeeded = true
            log("PASS " + stage + "; native owner retained for independent observation.")
        } catch {
            let failure = error as NSError; report.errorDomain = failure.domain; report.errorCode = failure.code
            log("FAIL " + report.stage + "; inspect the protected stage report. No mutation replay.")
        }
        if let reportURL, let runID { try? write(report, at: reportURL, run: runID) }
    }
}
