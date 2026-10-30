import CloudKit
import Foundation
import GraphEvo
import UIKit
@testable import GraphEvo

@available(iOS 17, *)
@MainActor final class CustomSyncProbeViewController: UIViewController {
    private struct Fixture: Codable {
        let a: GraphID; let b: GraphID
        let rootA: GraphNodeID; let childA: GraphNodeID; let edgeA: GraphNodeID; let actionA: GraphNodeID
        let rootB: GraphNodeID; let childB: GraphNodeID; let edgeB: GraphNodeID; let actionB: GraphNodeID
        let zoneA: String; let zoneB: String
    }
    private struct Envelope<Value: Codable>: Codable { let run: UUID; let value: Value }
    private struct Report: Codable {
        let stage: String; let processID: Int32; let launchTicket: String?
        var succeeded = false; var checks: [String] = []; var pending: Int?; var fetched: Int?; var unexpectedZones: Int?
        var errorDomain: String?; var errorCode: Int?; var diagnostic: String?
    }
    private let arguments: [String]
    private let output = UITextView()
    private var engine: CS01Engine?
    private var controllers: [GraphID: CS01GraphController] = [:]
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    func startProbe() { loadViewIfNeeded(); Task { await run() } }
    override func viewDidLoad() { super.viewDidLoad(); view = output; output.isEditable = false; UIApplication.shared.isIdleTimerDisabled = true }
    private func log(_ message: String) { output.text += message + "\n"; print("CS01: " + message) }
    private func write<Value: Codable>(_ value: Value, at url: URL, run: UUID) throws {
        try JSONEncoder().encode(Envelope(run: run, value: value)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<Value: Codable>(_ type: Value.Type, at url: URL, run: UUID) throws -> Value {
        let result = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: url)); guard result.run == run else { throw CS01Failure.fixture }; return result.value
    }
    private func setup(_ root: URL, fixture f: Fixture, routes: [CS01Route], database: CKDatabase) async throws -> CS01Engine {
        for route in routes {
            let controller = CS01GraphController(id: route.graph, url: root.appendingPathComponent(route.graph == f.a ? "A/graph.sqlite" : "B/graph.sqlite"))
            try await controller.open(); controllers[route.graph] = controller
        }
        let value = try CS01Engine(file: root.appendingPathComponent("sync-state.json"), routes: routes, controllers: controllers, database: database)
        engine = value; try await value.start(); return value
    }
    private func seed(_ controller: CS01GraphController, f: Fixture, a: Bool) async throws -> [GraphRecord] {
        let root = a ? f.rootA : f.rootB, child = a ? f.childA : f.childB, edge = a ? f.edgeA : f.edgeB, action = a ? f.actionA : f.actionB
        let rows = [try GraphRecord(id: root, type: "CS01.root", properties: ["label": .string("baseline")]),
            try GraphRecord(id: child, type: "CS01.child", properties: ["value": .string("baseline")]),
            try GraphRecord(id: edge, type: "CS01.edge", endpoints: .relationship(subject: root, object: child)),
            try GraphRecord(id: action, type: "CS01.action", endpoints: .action(subjects: [root], objects: [child]))]
        try await controller.apply(rows)
        var actual: [GraphRecord] = []
        for row in rows { guard let stored = try await controller.record(row.id) else { throw CS01Failure.fixture }; actual.append(stored) }
        return actual
    }
    private func check(_ f: Fixture, migrated: Bool, remote: Bool, owner: Bool) async throws {
        guard let a = controllers[f.a], try await a.catalog() == [f.a], try await a.count() == 4,
              try await a.record(f.rootA)?.properties["label"] == .string(migrated ? "migrated" : "baseline"),
              try await a.record(f.childA)?.properties["value"] == .string(remote ? "remote-during-pause" : "baseline"),
              try await a.record(f.edgeA)?.endpoints == .relationship(subject: f.rootA, object: f.childA),
              try await a.record(f.actionA)?.endpoints == .action(subjects: [f.rootA], objects: [f.childA]) else { throw CS01Failure.fixture }
        if owner {
            guard let b = controllers[f.b], try await b.catalog() == [f.b], try await b.count() == 4,
                  try await b.record(f.rootB)?.properties["label"] == .string("baseline"),
                  try await b.record(f.childB)?.properties["value"] == .string("baseline") else { throw CS01Failure.fixture }
        }
    }
    private func syncAndCheck(_ value: CS01Engine, f: Fixture, migrated: Bool, remote: Bool, owner: Bool) async throws {
        for attempt in 0..<60 {
            try await value.synchronize()
            do { try await check(f, migrated: migrated, remote: remote, owner: owner); return }
            catch { if attempt == 59 { throw error }; try await Task.sleep(for: .seconds(2)) }
        }
    }
    private func expectPaused(_ value: CS01Engine, graph: GraphID) async throws {
        do { try await value.synchronize(only: graph); throw CS01Failure.fixture } catch CS01Failure.paused { }
    }
    private func run() async {
        let ticket = arguments.firstIndex(of: "--launch-ticket").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        var report = Report(stage: "invalid", processID: ProcessInfo.processInfo.processIdentifier, launchTicket: ticket)
        var destination: URL?, runID: UUID?
        do {
            guard let flag = arguments.firstIndex(of: "--custom-sync"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  identifier == "iCloud.com.valerioburiani.GraphCKDemo" else { throw CS01Failure.fixture }
            let stage = arguments[flag + 1]; runID = run
            guard ["prepare", "identity", "seed-share", "peer-baseline", "pause-migrate", "peer-paused-edit", "owner-paused-check", "resume", "peer-final", "peer-fresh", "owner-fresh-A"].contains(stage) else { throw CS01Failure.fixture }
            report = Report(stage: stage, processID: report.processID, launchTicket: ticket)
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GraphEvoLaboratory/CustomSync/" + run.uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let output = root.appendingPathComponent(stage + ".report.json")
            guard !FileManager.default.fileExists(atPath: output.path) else { throw CS01Failure.replay }
            try Data("reserved".utf8).write(to: output, options: .withoutOverwriting); destination = output
            let cloud = CKContainer(identifier: identifier)
            guard try await cloud.accountStatus() == .available else { throw CS01Failure.fixture }
            if stage == "prepare" { report.checks.append("case-directory-prepared") }
            else if stage == "identity" {
                try write(try await cloud.userRecordID().recordName, at: root.appendingPathComponent("identity.json"), run: run)
                report.checks.append("recipient-transport")
            } else if stage == "seed-share" {
                let a = GraphID(), b = GraphID()
                let f = Fixture(a: a, b: b, rootA: GraphNodeID(graphID: a), childA: GraphNodeID(graphID: a), edgeA: GraphNodeID(graphID: a), actionA: GraphNodeID(graphID: a),
                    rootB: GraphNodeID(graphID: b), childB: GraphNodeID(graphID: b), edgeB: GraphNodeID(graphID: b), actionB: GraphNodeID(graphID: b),
                    zoneA: "GE2.CS01." + run.uuidString + ".A", zoneB: "GE2.CS01." + run.uuidString + ".B")
                try write(f, at: root.appendingPathComponent("fixture.json"), run: run)
                let routes = [CS01Route(graph: a, zoneName: f.zoneA, ownerName: CKCurrentUserDefaultName), CS01Route(graph: b, zoneName: f.zoneB, ownerName: CKCurrentUserDefaultName)]
                let value = try await setup(root.appendingPathComponent("owner"), fixture: f, routes: routes, database: cloud.privateCloudDatabase)
                try await value.createZones(); try await value.synchronize()
                for isA in [true, false] {
                    for row in try await seed(controllers[isA ? a : b]!, f: f, a: isA) { try await value.enqueue(row) }
                }
                try await syncAndCheck(value, f: f, migrated: false, remote: false, owner: true)
                guard try await cloud.privateCloudDatabase.recordZone(for: routes[0].zoneID).share == nil,
                      try await cloud.privateCloudDatabase.recordZone(for: routes[1].zoneID).share == nil else { throw CS01Failure.fixture }
                report.checks += ["two-local-private-stores-one-graph-each", "two-private-zones-without-shares", "native-records-acknowledged"]
                let recipient = try read(String.self, at: root.appendingPathComponent("identity.json"), run: run)
                let recipientID = CKRecord.ID(recordName: recipient)
                let participants = try await cloud.shareParticipants(forUserRecordIDs: [recipientID])
                guard let result = participants[recipientID] else { throw CS01Failure.fixture }
                let participant = try result.get(); participant.permission = .readWrite
                let share = CKShare(recordZoneID: routes[0].zoneID); share.publicPermission = .none; share.addParticipant(participant)
                guard let saved = try await cloud.privateCloudDatabase.save(share) as? CKShare, let url = saved.url else { throw CS01Failure.fixture }
                try write(url, at: root.appendingPathComponent("invitation.json"), run: run)
                guard try await cloud.privateCloudDatabase.recordZone(for: routes[0].zoneID).share != nil,
                      try await cloud.privateCloudDatabase.recordZone(for: routes[1].zoneID).share == nil else { throw CS01Failure.fixture }
                report.checks += ["A-shared-in-its-original-zone", "B-remains-private-with-no-share"]
            } else {
                let f = try read(Fixture.self, at: root.appendingPathComponent("fixture.json"), run: run)
                let peer = stage.hasPrefix("peer"), fresh = stage == "peer-fresh" || stage == "owner-fresh-A"
                let directory = root.appendingPathComponent(fresh ? stage : (peer ? "peer" : "owner"))
                if fresh, FileManager.default.fileExists(atPath: directory.path) { throw CS01Failure.replay }
                let routes: [CS01Route]
                if peer {
                    let metadata = try await cloud.shareMetadata(for: read(URL.self, at: root.appendingPathComponent("invitation.json"), run: run))
                    if metadata.participantStatus == .pending { _ = try await cloud.accept(metadata) }
                    else { guard metadata.participantStatus == .accepted else { throw CS01Failure.fixture } }
                    let zone = metadata.share.recordID.zoneID
                    routes = [CS01Route(graph: f.a, zoneName: zone.zoneName, ownerName: zone.ownerName)]
                } else {
                    routes = [CS01Route(graph: f.a, zoneName: f.zoneA, ownerName: CKCurrentUserDefaultName)] + (fresh ? [] : [CS01Route(graph: f.b, zoneName: f.zoneB, ownerName: CKCurrentUserDefaultName)])
                }
                let value = try await setup(directory, fixture: f, routes: routes, database: peer ? cloud.sharedCloudDatabase : cloud.privateCloudDatabase)
                if stage == "pause-migrate" {
                    let queued = try await controllers[f.a]!.patch(f.rootA, key: "label", value: .string("queued-before-pause"))
                    try await value.enqueue(queued)
                    guard await value.status().pending > 0 else { throw CS01Failure.fixture }
                    try await value.pause(f.a); try await expectPaused(value, graph: f.a)
                    try await controllers[f.a]!.migrate()
                    let changed = try await controllers[f.a]!.patch(f.rootA, key: "label", value: .string("migrated"))
                    try await value.enqueue(changed); try await expectPaused(value, graph: f.a)
                    let progress = try await controllers[f.b]!.patch(f.rootB, key: "progress", value: .integer(1))
                    try await value.enqueue(progress); try await value.synchronize(only: f.b)
                    let recordB = try await cloud.privateCloudDatabase.record(for: CKRecord.ID(recordName: f.rootB.rawValue.uuidString, zoneID: routes[1].zoneID))
                    guard let payloadB = recordB["payload"] as? Data,
                          try GraphCustomSyncLaboratory.decode(payloadB).properties["progress"] == .integer(1) else { throw CS01Failure.fixture }
                    report.checks.append("B-export-progresses-while-A-is-paused")
                    try await check(f, migrated: true, remote: false, owner: true)
                    guard try GraphCustomSyncLaboratory.version(at: directory.appendingPathComponent("A/graph.sqlite")) == 2 else { throw CS01Failure.fixture }
                    report.checks += ["pending-write-before-pause", "paused-admission-blocked", "closed-source-backup", "native-model-1-to-2-migration", "pending-migration-edit-durable", "B-unchanged"]
                } else if stage == "peer-paused-edit" {
                    try await syncAndCheck(value, f: f, migrated: false, remote: false, owner: false)
                    try await value.enqueue(controllers[f.a]!.patch(f.childA, key: "value", value: .string("remote-during-pause")))
                    try await syncAndCheck(value, f: f, migrated: false, remote: true, owner: false)
                    report.checks += ["owner-migration-not-exported-while-paused", "independent-participant-edit-exported"]
                } else if stage == "owner-paused-check" {
                    try await expectPaused(value, graph: f.a); try await check(f, migrated: true, remote: false, owner: true)
                    guard await value.status().pending > 0 else { throw CS01Failure.fixture }
                    report.checks += ["pause-and-outbox-survive-process-restart", "remote-edit-not-applied-while-paused"]
                } else {
                    if stage == "resume" { try await value.resume(f.a) }
                    let migrated: Bool = stage != "peer-baseline"
                    try await syncAndCheck(value, f: f, migrated: migrated, remote: migrated, owner: !peer && !fresh)
                    report.checks.append(fresh ? "fresh-zone-scoped-recovery-with-no-source-store" : "exact-data-and-topology")
                    if peer || fresh { guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("B").path) else { throw CS01Failure.fixture }; report.checks.append("B-store-not-created") }
                }
            }
            if let engine {
                let status = await engine.status(); report.pending = status.pending; report.fetched = status.fetched; report.unexpectedZones = status.unexpected
                guard status.unexpected == 0, !status.failed else { throw CS01Failure.sync }
            }
            report.succeeded = true; log("PASS " + stage + "; retain owner until independent observation.")
        } catch {
            report.diagnostic = await engine?.diagnostic()
            let failure = error as NSError; report.errorDomain = failure.domain; report.errorCode = failure.code
            log("FAIL " + report.stage + "; preserve evidence and do not replay mutations.")
        }
        if let destination, let runID { try? write(report, at: destination, run: runID) }
    }
}
