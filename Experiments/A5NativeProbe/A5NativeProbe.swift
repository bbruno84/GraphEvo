import Foundation
import GraphEvo
import UIKit

private struct A5EntityProbe: GraphModel {
    nonisolated static let graphType = "A5.entity"
    nonisolated static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

private struct A5EdgeProbe: GraphModel {
    nonisolated static let graphType = "A5.edge"
    nonisolated static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

private struct A5ActionProbe: GraphModel {
    nonisolated static let graphType = "A5.action"
    nonisolated static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    nonisolated var id: GraphNodeID { record.id }
    nonisolated init(graphRecord: GraphRecord) throws { record = graphRecord }
    nonisolated func graphRecord() throws -> GraphRecord { record }
}

/// Public API integration on authorized synthetic fixtures. Sensitive transports never reach the console.
@MainActor final class A5NativeProbeViewController: UIViewController {
    private struct Fixture: Codable, Sendable { let a: GraphID; let b: GraphID; let members: [GraphNodeID] }
    private struct Transport<Value: Codable>: Codable { let runID: UUID; let value: Value }
    private struct PrivateControl: Codable { let graphID: GraphID; let memberID: GraphNodeID }
    private enum Failure: Error { case arguments, replay, fixture, deadline }
    private let output = UITextView()
    private let arguments: [String]
    private var task: Task<Void, Never>?
    private var reportURL: URL?
    private var retainedDatabase: GraphDatabase?
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { await run() }
    }
    private func log(_ value: String) {
        output.text += value + "\n"; print("A5: " + value)
        if let reportURL { try? output.text.write(to: reportURL, atomically: true, encoding: .utf8) }
    }
    private func write<Value: Codable>(_ value: Value, to url: URL, runID: UUID) throws {
        let bytes = try JSONEncoder().encode(Transport(runID: runID, value: value))
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<Value: Codable>(_ type: Value.Type, from url: URL, runID: UUID) throws -> Value {
        let transport = try JSONDecoder().decode(Transport<Value>.self, from: Data(contentsOf: url))
        guard transport.runID == runID else { throw Failure.fixture }
        return transport.value
    }
    private func run() async {
        var database: GraphDatabase?
        do {
            guard let flag = arguments.firstIndex(of: "--a5"), arguments.count > flag + 2,
                  let runID = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
                  !identifier.isEmpty else { throw Failure.arguments }
            let stage = arguments[flag + 1]
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/A5/\(runID.uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report = folder.appendingPathComponent(stage + ".txt")
            guard !FileManager.default.fileExists(atPath: report.path) else { throw Failure.replay }
            try "reserved\n".write(to: report, atomically: true, encoding: .utf8)
            reportURL = report
            let db = try await GraphDatabase.openMirrored(privateStoreAt: folder.appendingPathComponent("private.sqlite"),
                sharedStoreAt: folder.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier)
            database = db
            log("Opened one native owner with private/shared stores; local readiness only.")
            try await waitSetup(db)
            let identityURL = folder.appendingPathComponent("identity.json")
            let invitationURL = folder.appendingPathComponent("invitation.json")
            let fixtureURL = folder.appendingPathComponent("fixture.json")
            let controlURL = folder.appendingPathComponent("private-control.json")
            if stage == "identity" {
                try write(try await db.sharingIdentity(), to: identityURL, runID: runID)
                let own = try await db.createGraph(), member = own.makeNodeID()
                _ = try await own.transaction { try $0.insert(GraphRecord(id: member, type: "private-control", properties: ["label": .string("XR-private")])) }
                _ = try await prepare(db, id: own.id)
                try write(PrivateControl(graphID: own.id, memberID: member), to: controlURL, runID: runID)
                try await own.close()
                log("Protected recipient identity and private control prepared.")
            } else if stage == "seed" {
                let a = try await db.createGraph(), b = try await db.createGraph()
                let ids = (0..<5).map { _ in a.makeNodeID() }
                try await seed(a, ids: ids, label: "A")
                let bIDs = (0..<5).map { _ in b.makeNodeID() }
                try await seed(b, ids: bIDs, label: "B")
                let first = try await prepare(db, id: a.id), second = try await prepare(db, id: b.id)
                guard first.zoneName != second.zoneName else { throw Failure.fixture }
                try write(Fixture(a: a.id, b: b.id, members: ids + bIDs), to: fixtureURL, runID: runID)
                try await a.close(); try await b.close()
                log("Owner A5/B5 prepared in distinct owner-only boundaries.")
            } else {
                let fixture = try read(Fixture.self, from: fixtureURL, runID: runID)
                switch stage {
                case "invite", "reinvite":
                    let recipient = try read(GraphSharingIdentity.self, from: identityURL, runID: runID)
                    let invitation = try await db.invite(recipient, to: fixture.a)
                    try write(invitation, to: invitationURL, runID: runID)
                    log("Private A invitation persisted for the pinned recipient; B unchanged.")
                case "accept", "reaccept":
                    try await db.acceptInvitation(read(GraphInvitation.self, from: invitationURL, runID: runID))
                    log("Native acceptance completed; waiting for imported graph.")
                    try await verifyParticipant(db, fixture: fixture, expectedCount: stage == "accept" ? 5 : 8)
                case "participant-add":
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 5)
                    let a = try await db.openGraph(fixture.a)
                    let patch = try GraphRecordPatch(id: fixture.members[0], properties: ["label": .set(.string("participant-updated"))])
                    try await a.transaction { _ = try $0.patch(patch) }
                    do { _ = try await a.insertShared(addedRecords(fixture)) }
                    catch GraphStoreError.pendingNativeOperation {
                        log("Native assignment pending; retaining intent and checking recovery without replaying share.")
                        try await recover(a)
                    }
                    try await a.close()
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 8)
                case "participant-details":
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 8)
                    let graph = try await db.openGraph(fixture.a)
                    let patch = try GraphRecordPatch(id: fixture.members[0], properties: ["note": .set(.string("shared-detail")), "count": .set(.integer(7))],
                                                     addingTags: ["updated"], addingGroups: ["participant"])
                    do { _ = try await graph.patchShared(patch) }
                    catch GraphStoreError.pendingNativeOperation { try await recover(graph, expected: 1) }
                    try await graph.close()
                    try await verifyDetails(db, fixture: fixture)
                case "owner-observe", "owner-observe-details", "owner-after-leave":
                    try await verifyOwner(db, fixture: fixture, expectedCount: 8)
                    if stage == "owner-observe-details" { try await verifyDetails(db, fixture: fixture) }
                case "interrupt-after-assignment":
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 8)
                    #if DEBUG
                    A5RecoveryProbeControl.pauseAfterAssignment(graphID: fixture.a) {
                        self.log("ASSIGNMENT-PAUSED; intent and native objects retained before finalization.")
                        let intents = try await db.pendingSharedOperations()
                        guard intents.contains(where: { $0.graphID == fixture.a && $0.kind == .patch && $0.nodeIDs == [fixture.members[0]] }) else { throw Failure.fixture }
                        self.log("INTENT-VISIBLE while the native writer is paused.")
                    }
                    #else
                    throw Failure.arguments
                    #endif
                    let graph = try await db.openGraph(fixture.a)
                    let patch = try GraphRecordPatch(id: fixture.members[0], properties: ["interrupted": .set(.string("survived-interruption"))])
                    _ = try await graph.patchShared(patch)
                    throw Failure.fixture
                case "recover-patch":
                    let pending = try await db.pendingSharedOperations()
                    guard pending.contains(where: { $0.graphID == fixture.a && $0.kind == .patch }) else { throw Failure.fixture }
                    let graph = try await db.openGraph(fixture.a)
                    try await recover(graph, expected: 1)
                    try await graph.close()
                    guard try await db.pendingSharedOperations().isEmpty else { throw Failure.fixture }
                    try await verifyRecovery(db, fixture: fixture)
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 8)
                case "owner-observe-recovery":
                    try await verifyRecovery(db, fixture: fixture)
                    try await verifyOwner(db, fixture: fixture, expectedCount: 8)
                case "read-write-probe":
                    try await waitPermission(db, id: fixture.a, permission: .readWrite)
                    let graph = try await db.openGraph(fixture.a)
                    let patch = try GraphRecordPatch(id: fixture.members[0], properties: ["note": .set(.string("read-write-restored"))])
                    try await graph.transaction { _ = try $0.patch(patch) }
                    try await graph.close()
                    log("Restored read/write metadata allowed an existing-detail edit.")
                case "resume-writer":
                    let graph = try await db.openGraph(fixture.a)
                    let value = try await graph.read { try $0.record(for: fixture.members[0])?.properties["note"] }
                    try await graph.close()
                    guard value == .string("read-write-restored") else { throw Failure.fixture }
                    log("Existing saved edit present; retaining writer without replaying a mutation.")
                case "owner-observe-rw", "owner-observe-rw-recovered":
                    try await verifyOwner(db, fixture: fixture, expectedCount: 8)
                    try await verifyDetails(db, fixture: fixture, expectedNote: "read-write-restored")
                case "read-only", "restore-rw":
                    let recipient = try read(GraphSharingIdentity.self, from: identityURL, runID: runID)
                    try await db.setPermission(stage == "read-only" ? .readOnly : .readWrite, for: recipient, in: fixture.a)
                    log("Owner permission change persisted; peer access metadata must be observed separately.")
                case "read-only-probe":
                    try await waitPermission(db, id: fixture.a, permission: .readOnly)
                    let graph = try await db.openGraph(fixture.a)
                    let patch = try GraphRecordPatch(id: fixture.members[0], properties: ["label": .set(.string("must-not-save"))])
                    do {
                        try await graph.transaction { _ = try $0.patch(patch) }
                        throw Failure.fixture
                    } catch GraphStoreError.permissionDenied { log("Known read-only write rejected by the library before save.") }
                    try await graph.close()
                case "leave":
                    try await verifyParticipant(db, fixture: fixture, expectedCount: 8)
                    try await db.leaveGraph(fixture.a)
                    guard !(try await db.graphIDs()).contains(fixture.a) else { throw Failure.fixture }
                    let control = try read(PrivateControl.self, from: controlURL, runID: runID)
                    let own = try await db.openGraph(control.graphID)
                    let label = try await own.read { try $0.record(for: control.memberID)?.properties["label"] }
                    guard label == .string("XR-private") else { throw Failure.fixture }
                    try await own.close()
                    log("Participant A removed; pinned private control preserved.")
                case "revoke":
                    try await verifyOwner(db, fixture: fixture, expectedCount: 8)
                    try await db.revoke(read(GraphSharingIdentity.self, from: identityURL, runID: runID), from: fixture.a)
                    log("Pinned participant revoked; owner A/B preserved.")
                case "observe-revoked":
                    for attempt in 0..<150 {
                        if !(try await db.graphIDs()).contains(fixture.a) { log("Shared A no longer locally present."); break }
                        if attempt == 149 { throw Failure.deadline }
                        try await Task.sleep(for: .seconds(2))
                    }
                    let control = try read(PrivateControl.self, from: controlURL, runID: runID)
                    let own = try await db.openGraph(control.graphID)
                    let value = try await own.read { try $0.record(for: control.memberID)?.properties["label"] }
                    try await own.close()
                    guard value == .string("XR-private") else { throw Failure.fixture }
                    log("Pinned private control retained after revocation.")
                default: throw Failure.arguments
                }
            }
            if ["participant-add", "participant-details", "read-write-probe", "recover-patch", "resume-writer"].contains(stage) {
                retainedDatabase = db
                database = nil
                log("PASS \(stage); native writer retained for independent peer observation.")
            } else {
                try await db.close(); database = nil
                log("PASS \(stage)")
            }
        } catch {
            // Framework errors may carry account or invitation material; log only error category/code.
            let ns = error as NSError
            log("FAIL domain=\(ns.domain) code=\(ns.code)")
            if let database { try? await database.close() }
        }
    }
    private func waitSetup(_ database: GraphDatabase) async throws {
        for attempt in 0..<150 {
            let status = try await database.cloudSetupStatus()
            if status.storeCount == 2, status.readyStoreCount == 2 { log("Native setup completed for both stores."); return }
            if attempt == 149 { throw Failure.deadline }
            if attempt % 15 == 0 { log("Waiting for native setup: \(status.readyStoreCount)/\(status.storeCount).") }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func prepare(_ database: GraphDatabase, id: GraphID) async throws -> GraphMirrorBoundary {
        for attempt in 0..<90 {
            do { return try await database.prepareMirroring(for: id) }
            catch GraphMirroringError.metadataUnavailable {
                if attempt == 89 { throw Failure.deadline }
                if attempt % 15 == 0 { log("Waiting for the native sharing metadata preflight.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw Failure.deadline
    }
    private func seed(_ graph: GraphStore, ids: [GraphNodeID], label: String) async throws {
        try await graph.transaction { scope throws -> Void in
            for index in 0..<2 {
                try scope.insert(GraphRecord(id: ids[index], type: "A5.entity", properties: ["label": .string("\(label)-\(index)"), "binary": .data(Data([0,255,UInt8(index)]))], tags: ["original"], groups: ["A5"]))
            }
            try scope.insert(GraphRecord(id: ids[2], type: "A5.edge", endpoints: .relationship(subject: ids[0], object: ids[1])))
            try scope.insert(GraphRecord(id: ids[3], type: "A5.edge", endpoints: .relationship(subject: ids[1], object: ids[0])))
            try scope.insert(GraphRecord(id: ids[4], type: "A5.action", endpoints: .action(subjects: [ids[0]], objects: [ids[1]])))
        }
    }
    nonisolated private func addedRecords(_ fixture: Fixture) throws -> [GraphRecord] {
        let ids = ["00000000-0000-0000-0000-000000000011", "00000000-0000-0000-0000-000000000012", "00000000-0000-0000-0000-000000000013"].map {
            GraphNodeID(graphID: fixture.a, rawValue: UUID(uuidString: $0)!)
        }
        return try [GraphRecord(id: ids[0], type: "A5.entity", properties: ["label": .string("participant-added"), "binary": .data(Data([128,0,255]))], tags: ["new"], groups: ["A5"]),
            GraphRecord(id: ids[1], type: "A5.edge", endpoints: .relationship(subject: fixture.members[0], object: ids[0])),
            GraphRecord(id: ids[2], type: "A5.action", endpoints: .action(subjects: [ids[0]], objects: [fixture.members[1]]))]
    }
    private func recover(_ store: GraphStore, expected: Int = 3) async throws {
        for attempt in 0..<150 {
            do { guard try await store.recoverSharedOperation().count == expected else { throw Failure.fixture }; return }
            catch GraphStoreError.pendingNativeOperation {
                if attempt == 149 { throw Failure.deadline }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func verifyRecovery(_ database: GraphDatabase, fixture: Fixture) async throws {
        for attempt in 0..<150 {
            let graph = try await database.openGraph(fixture.a)
            let value = try await graph.read { try $0.record(for: fixture.members[0])?.properties["interrupted"] }
            try await graph.close()
            if value == .string("survived-interruption") { log("Interrupted operation value recovered."); return }
            if attempt == 149 { throw Failure.deadline }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func verifyDetails(_ database: GraphDatabase, fixture: Fixture, expectedNote: String = "shared-detail") async throws {
        for attempt in 0..<150 {
            let graph = try await database.openGraph(fixture.a)
            let record = try await graph.read { try $0.record(for: fixture.members[0]) }
            try await graph.close()
            if let record, record.properties["note"] == .string(expectedNote), record.properties["count"] == .integer(7),
               record.tags == ["original", "updated"], record.groups == ["A5", "participant"] {
                let mapping = try await database.inspectMirroring(for: fixture.a)
                let status = try await database.sharingStatus(for: fixture.a)
                if mapping.pendingMappingCount == 0, mapping.unexpectedZoneCount == 0, !status.hasPendingOperation {
                    log("New detail properties/tags/groups recovered in A's boundary; native rows=\(mapping.nativeObjectCount).")
                    return
                }
            }
            if attempt == 149 { throw Failure.deadline }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func waitPermission(_ db: GraphDatabase, id: GraphID, permission: GraphSharePermission) async throws {
        for attempt in 0..<150 {
            if let status = try? await db.sharingStatus(for: id), status.permission == permission, status.accepted { return }
            if attempt == 149 { throw Failure.deadline }
            if attempt % 15 == 0 { log("Waiting for native permission metadata.") }
            try await Task.sleep(for: .seconds(2))
        }
    }
    private func verifyParticipant(_ db: GraphDatabase, fixture: Fixture, expectedCount: Int) async throws {
        try await verify(db, fixture: fixture, owner: false, count: expectedCount)
    }
    private func verifyOwner(_ db: GraphDatabase, fixture: Fixture, expectedCount: Int) async throws {
        try await verify(db, fixture: fixture, owner: true, count: expectedCount)
    }
    private func verify(_ db: GraphDatabase, fixture: Fixture, owner: Bool, count: Int) async throws {
        for attempt in 0..<150 {
            do {
                let catalog = try await db.graphIDs()
                guard catalog.contains(fixture.a), catalog.contains(fixture.b) == owner else { throw Failure.fixture }
                let graph = try await db.openGraph(fixture.a)
                let expected = Array(fixture.members.prefix(5)) + (count == 8 ? try addedRecords(fixture).map(\.id) : [])
                let all = try await graph.read { scope in
                    try scope.fetchAll(A5EntityProbe.self).map(\.record) + scope.fetchAll(A5EdgeProbe.self).map(\.record) + scope.fetchAll(A5ActionProbe.self).map(\.record)
                }
                try await graph.close()
                guard all.count == count, Set(all.map(\.id)) == Set(expected) else { throw Failure.fixture }
                let records = try expected.map { id in
                    guard let record = all.first(where: { $0.id == id }) else { throw Failure.fixture }; return record
                }
                if count == 8 {
                    guard records[0].properties["label"] == .string("participant-updated"),
                          records[5].properties["binary"] == .data(Data([128,0,255])), records[5].tags == ["new"], records[5].groups == ["A5"],
                          records[6].endpoints == .relationship(subject: fixture.members[0], object: records[5].id),
                          records[7].endpoints == .action(subjects: [records[5].id], objects: [fixture.members[1]]) else { throw Failure.fixture }
                }
                let mapping = try await db.inspectMirroring(for: fixture.a)
                let status = try await db.sharingStatus(for: fixture.a)
                guard mapping.boundary != nil, mapping.pendingMappingCount == 0, mapping.unexpectedZoneCount == 0,
                      status.role == (owner ? .owner : .participant), !status.hasPendingOperation,
                      status.scope == (owner ? .privateStore : .sharedStore) else { throw Failure.fixture }
                if owner {
                    let control = try await db.openGraph(fixture.b)
                    let members = Array(fixture.members.suffix(5))
                    let controlRows = try await control.read { scope in try members.compactMap { try scope.record(for: $0) } }
                    let controlCount = try await control.read { scope in
                        try scope.fetchAll(A5EntityProbe.self).count + scope.fetchAll(A5EdgeProbe.self).count + scope.fetchAll(A5ActionProbe.self).count
                    }
                    try await control.close()
                    guard controlCount == 5 else { throw Failure.fixture }
                    guard controlRows.count == 5, controlRows[0].properties["label"] == .string("B-0"),
                          controlRows[0].properties["binary"] == .data(Data([0,255,0])), controlRows[0].tags == ["original"] else { throw Failure.fixture }
                    let controlMapping = try await db.inspectMirroring(for: fixture.b)
                    guard controlMapping.boundary != nil, controlMapping.boundary?.zoneName != mapping.boundary?.zoneName,
                          controlMapping.pendingMappingCount == 0, controlMapping.unexpectedZoneCount == 0 else { throw Failure.fixture }
                }
                log("Verified \(owner ? "owner" : "participant") A=\(count), B \(owner ? "preserved" : "absent"), native rows=\(mapping.nativeObjectCount), all mapped in A boundary.")
                return
            } catch {
                if attempt == 149 { throw error }
                if attempt % 15 == 0 { log("Waiting for application fixture and native metadata.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
}
