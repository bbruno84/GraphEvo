import CryptoKit
import Darwin
import Foundation
import GraphEvo
import UIKit

/// One-use public API integration; no identity, invitation or application payload reaches logs.
@MainActor final class A6NativeProbeViewController: UIViewController {
    private struct Fixture: Codable {
        let a: GraphID; let b: GraphID; let ownerA: GraphNodeID; let ownerB: GraphNodeID
        let small: GraphAttachmentMetadata; let large: GraphAttachmentMetadata; let control: GraphAttachmentMetadata
    }
    private struct Transport<Value: Codable>: Codable { let runID: UUID; let value: Value }
    private enum Failure: Error { case arguments, replay, fixture, deadline }
    private let arguments: [String]
    private let output = UITextView()
    private var report: URL?
    private var database: GraphDatabase?
    private var peak: UInt64 = 0
    private var baseline: UInt64 = 0
    private var addition: GraphAttachmentMetadata?
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use CLI initialization.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = output; output.isEditable = false
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await run() }
    }
    private func log(_ value: String) {
        output.text += value + "\n"; print("A6: " + value)
        if let report { try? output.text.write(to: report, atomically: true, encoding: .utf8) }
    }
    private func write<Value: Codable>(_ value: Value, at url: URL, run: UUID) throws {
        try JSONEncoder().encode(Transport(runID: run, value: value)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<Value: Codable>(_ type: Value.Type, at url: URL, run: UUID) throws -> Value {
        let value = try JSONDecoder().decode(Transport<Value>.self, from: Data(contentsOf: url))
        guard value.runID == run else { throw Failure.fixture }; return value.value
    }
    private func memory() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    private func run() async {
        baseline = memory(); peak = baseline
        let sampler = Task { while !Task.isCancelled { peak = max(peak, memory()); try? await Task.sleep(for: .milliseconds(20)) } }
        defer { sampler.cancel() }
        do {
            guard let flag = arguments.firstIndex(of: "--a6"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 2]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String, !identifier.isEmpty else { throw Failure.arguments }
            let stage = arguments[flag + 1]
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GraphEvoLaboratory/A6/\(run.uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ticket = root.appendingPathComponent(stage + ".txt")
            guard !FileManager.default.fileExists(atPath: ticket.path) else { throw Failure.replay }
            try "reserved\n".write(to: ticket, atomically: true, encoding: .utf8); report = ticket
            let db = try await GraphDatabase.openMirrored(privateStoreAt: root.appendingPathComponent("private.sqlite"), sharedStoreAt: root.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier)
            database = db
            log("Native owner open; waiting for both setup events.")
            for attempt in 0..<150 {
                let setup = try await db.cloudSetupStatus()
                if setup.readyStoreCount == 2 { break }
                if attempt == 149 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2))
            }
            let fixtureURL = root.appendingPathComponent("fixture.json"), identityURL = root.appendingPathComponent("identity.json"), invitationURL = root.appendingPathComponent("invitation.json")
            if stage == "identity" { try write(try await db.sharingIdentity(), at: identityURL, run: run) }
            else if stage == "seed" {
                let a = try await db.createGraph(), b = try await db.createGraph()
                let ownerA = a.makeNodeID(), ownerB = b.makeNodeID()
                try await a.transaction { _ = try $0.insert(GraphRecord(id: ownerA, type: "A6.owner")) }
                try await b.transaction { _ = try $0.insert(GraphRecord(id: ownerB, type: "A6.owner")) }
                let small = try await a.importAttachment(from: source(root, size: 512, value: 31), ownedBy: ownerA, fileName: "small.bin")
                let large = try await a.importAttachment(from: source(root, size: 10 * 1024 * 1024, value: 173), ownedBy: ownerA, fileName: "large.bin")
                let control = try await b.importAttachment(from: source(root, size: 512, value: 47), ownedBy: ownerB, fileName: "control.bin")
                for id in [a.id, b.id] {
                    for attempt in 0..<90 {
                        do { _ = try await db.prepareMirroring(for: id); break }
                        catch GraphMirroringError.metadataUnavailable {
                            if attempt == 89 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2))
                        }
                    }
                }
                try write(Fixture(a: a.id, b: b.id, ownerA: ownerA, ownerB: ownerB, small: small, large: large, control: control), at: fixtureURL, run: run)
                try await a.close(); try await b.close()
                log("Prepared A with 512-byte/10-MiB files and personal B control in distinct boundaries.")
            } else {
                let fixture = try read(Fixture.self, at: fixtureURL, run: run)
                let additionURL = root.appendingPathComponent("addition.json")
                if FileManager.default.fileExists(atPath: additionURL.path) {
                    addition = try read(GraphAttachmentMetadata.self, at: additionURL, run: run)
                }
                switch stage {
                case "invite":
                    let identity = try read(GraphSharingIdentity.self, at: identityURL, run: run)
                    try write(try await db.invite(identity, to: fixture.a), at: invitationURL, run: run)
                case "accept", "export-replacement":
                    if stage == "accept" { try await db.acceptInvitation(read(GraphInvitation.self, at: invitationURL, run: run)) }
                    try await verify(db, fixture, owner: false, replacement: stage != "accept", deletion: false)
                    let graph = try await db.openGraph(fixture.a)
                    let export = root.appendingPathComponent(stage == "accept" ? "exported-large.bin" : "exported-replacement.bin")
                    _ = try await graph.exportAttachment(fixture.large.id, to: export)
                    guard try Data(contentsOf: export) == Data(repeating: stage == "accept" ? 173 : 91, count: 10 * 1024 * 1024) else { throw Failure.fixture }
                    try await graph.close(); log("Independent participant export is byte-exact.")
                case "add":
                    try await verify(db, fixture, owner: false, replacement: false, deletion: false)
                    let graph = try await db.openGraph(fixture.a)
                    do {
                        addition = try await graph.importAttachment(from: source(root, size: 512, value: 67), ownedBy: fixture.ownerA, fileName: "participant.bin")
                    } catch GraphStoreError.pendingNativeOperation {
                        let intents = try await db.pendingSharedOperations().filter { $0.graphID == fixture.a && $0.kind == .insertion }
                        guard intents.count == 1, let nodeID = intents.first?.nodeIDs.first, intents.first?.nodeIDs.count == 1 else { throw Failure.fixture }
                        for attempt in 0..<150 {
                            do { _ = try await graph.recoverSharedOperation(); break }
                            catch GraphStoreError.pendingNativeOperation {
                                if attempt == 149 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2))
                            }
                        }
                        addition = try await graph.attachment(nodeID)?.metadata
                    }
                    guard let addition else { throw Failure.fixture }
                    try write(addition, at: additionURL, run: run)
                    try await graph.close()
                    try await verify(db, fixture, owner: false, replacement: false, deletion: false)
                    log("New participant-owned file assigned to existing A share.")
                case "observe-add":
                    guard addition != nil else { throw Failure.fixture }
                    try await verify(db, fixture, owner: true, replacement: false, deletion: false)
                case "replace":
                    try await verify(db, fixture, owner: false, replacement: false, deletion: false)
                    let graph = try await db.openGraph(fixture.a)
                    let next = try await graph.replaceAttachment(fixture.large.id, from: source(root, size: 10 * 1024 * 1024, value: 91), fileName: "replacement.bin")
                    guard next.id == fixture.large.id, next.revision != fixture.large.revision else { throw Failure.fixture }
                    try await graph.close(); log("Participant replacement committed locally with stable ID.")
                case "observe-replacement": try await verify(db, fixture, owner: true, replacement: true, deletion: false)
                case "delete":
                    try await verify(db, fixture, owner: false, replacement: true, deletion: false)
                    let graph = try await db.openGraph(fixture.a)
                    try await graph.deleteAttachment(fixture.large.id); try await graph.close()
                    log("Participant deletion committed locally.")
                case "observe-deletion": try await verify(db, fixture, owner: true, replacement: true, deletion: true)
                case "owner-cascade":
                    try await verify(db, fixture, owner: true, replacement: true, deletion: true)
                    let graph = try await db.openGraph(fixture.a)
                    try await graph.delete(fixture.ownerA)
                    guard try await graph.attachment(fixture.small.id) == nil else { throw Failure.fixture }
                    try await graph.close(); log("Owner deletion cleaned its remaining owned content locally.")
                case "observe-cascade":
                    for attempt in 0..<180 {
                        let graph = try await db.openGraph(fixture.a)
                        let absent = try await graph.read { try $0.record(for: fixture.ownerA) == nil && $0.record(for: fixture.small.id) == nil && $0.record(for: fixture.large.id) == nil }
                        try await graph.close()
                        if absent {
                            if let addition {
                                let check = try await db.openGraph(fixture.a)
                                let missing = try await check.attachment(addition.id) == nil
                                try await check.close()
                                if !missing { if attempt == 179 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2)); continue }
                            }
                            break
                        }; if attempt == 179 { throw Failure.deadline }; try await Task.sleep(for: .seconds(2))
                    }
                    guard !(try await db.graphIDs()).contains(fixture.b) else { throw Failure.fixture }
                    log("Independent participant recovered owner/owned-file deletion; B absent.")
                case "owner-final", "owner-final-boundary":
                    let graph = try await db.openGraph(fixture.a)
                    guard try await graph.read({ try $0.record(for: fixture.ownerA) == nil && $0.record(for: fixture.small.id) == nil && $0.record(for: fixture.large.id) == nil }) else { throw Failure.fixture }
                    if let addition { guard try await graph.attachment(addition.id) == nil else { throw Failure.fixture } }
                    try await graph.close()
                    let control = try await db.openGraph(fixture.b)
                    try check(try await control.attachment(fixture.control.id), metadata: fixture.control, size: 512, value: 47)
                    try await control.close()
                    let aMapping = try await db.inspectMirroring(for: fixture.a)
                    let bMapping = try await db.inspectMirroring(for: fixture.b)
                    guard aMapping.boundary != nil, bMapping.boundary != nil,
                          aMapping.boundary?.zoneName != bMapping.boundary?.zoneName,
                          aMapping.pendingMappingCount == 0, bMapping.pendingMappingCount == 0,
                          aMapping.unexpectedZoneCount == 0, bMapping.unexpectedZoneCount == 0 else { throw Failure.fixture }
                    log("Owner B file retained after A cascade; both non-nil boundaries remain distinct.")
                default: throw Failure.arguments
                }
            }
            peak = max(peak, memory())
            log("Sampled stage resident bytes: baseline=\(baseline), peak=\(peak), delta=\(peak >= baseline ? peak - baseline : 0).")
            log("PASS \(stage); native owner retained for peer observation.")
        } catch {
            let error = error as NSError; log("FAIL domain=\(error.domain) code=\(error.code)")
        }
    }
    private func source(_ root: URL, size: Int, value: UInt8) throws -> URL {
        let file = root.appendingPathComponent("source-\(UUID()).bin")
        try Data(repeating: value, count: size).write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
        return file
    }
    private func check(_ content: GraphAttachmentContent?, metadata: GraphAttachmentMetadata, size: Int, value: UInt8, replacement: Bool = false) throws {
        guard let content, content.metadata.id == metadata.id, content.metadata.ownerID == metadata.ownerID,
              content.metadata.byteCount == size, content.data == Data(repeating: value, count: size),
              content.metadata.sha256 == SHA256.hash(data: content.data).map({ String(format: "%02x", $0) }).joined(),
              replacement ? content.metadata.revision != metadata.revision && content.metadata.fileName == "replacement.bin" : content.metadata == metadata else { throw Failure.fixture }
    }
    private func verify(_ db: GraphDatabase, _ fixture: Fixture, owner: Bool, replacement: Bool, deletion: Bool) async throws {
        for attempt in 0..<180 {
            do {
                guard (try await db.graphIDs()).contains(fixture.b) == owner else { throw Failure.fixture }
                let graph = try await db.openGraph(fixture.a)
                let count = try await graph.attachments(ownedBy: fixture.ownerA).count
                guard count == (deletion ? 1 : 2) + (addition == nil ? 0 : 1) else { throw Failure.fixture }
                try check(try await graph.attachment(fixture.small.id), metadata: fixture.small, size: 512, value: 31)
                if deletion { guard try await graph.attachment(fixture.large.id) == nil else { throw Failure.fixture } }
                else { try check(try await graph.attachment(fixture.large.id), metadata: fixture.large, size: 10 * 1024 * 1024, value: replacement ? 91 : 173, replacement: replacement) }
                if let addition { try check(try await graph.attachment(addition.id), metadata: addition, size: 512, value: 67) }
                try await graph.close()
                let mapping = try await db.inspectMirroring(for: fixture.a)
                guard mapping.boundary != nil, mapping.pendingMappingCount == 0, mapping.unexpectedZoneCount == 0 else { throw Failure.fixture }
                if owner {
                    let control = try await db.openGraph(fixture.b)
                    try check(try await control.attachment(fixture.control.id), metadata: fixture.control, size: 512, value: 47)
                    try await control.close()
                    let other = try await db.inspectMirroring(for: fixture.b)
                    guard other.boundary != nil, other.boundary?.zoneName != mapping.boundary?.zoneName, other.pendingMappingCount == 0, other.unexpectedZoneCount == 0 else { throw Failure.fixture }
                }
                log("Verified exact bytes/metadata/checksums, A mappings, B \(owner ? "preserved" : "absent").")
                return
            } catch {
                if attempt == 179 { throw error }
                if attempt % 15 == 0 { log("Waiting for exact file state and native mappings.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
}
