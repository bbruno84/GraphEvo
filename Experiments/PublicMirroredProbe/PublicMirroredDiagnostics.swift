import CloudKit
import Foundation
import GraphEvo
import UIKit

/// Separate read-only triage using documented share APIs; never part of public-consumer acceptance.
@MainActor final class PublicMirroredDiagnosticsViewController: UIViewController {
    private struct Envelope<Value: Codable>: Codable { let runID: UUID; let value: Value }
    private struct Fixture: Codable { let a: GraphID }
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
    private func error(_ error: any Error, phase: String) {
        let ns = error as NSError; log("\(phase) domain=\(ns.domain) code=\(ns.code)")
    }
    private func run() async {
        do {
            guard let flag = arguments.firstIndex(of: "--native-diagnose"), arguments.count > flag + 2,
                  let run = UUID(uuidString: arguments[flag + 1]),
                  let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { return }
            let requestedRole = arguments[flag + 2]
            guard ["owner", "peer", "owner-visibility", "peer-visibility"].contains(requestedRole) else { return }
            let role = requestedRole.hasPrefix("owner") ? "owner" : "peer"
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GraphEvoLaboratory/NativeIdentityFiles/\(run.uuidString)")
            let ticket = folder.appendingPathComponent("diagnose-\(requestedRole).txt")
            guard !FileManager.default.fileExists(atPath: ticket.path) else { return }
            try "reserved\n".write(to: ticket, atomically: true, encoding: .utf8); report = ticket
            let data = try Data(contentsOf: folder.appendingPathComponent("invitation.json"))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  UUID(uuidString: object["runID"] as? String ?? "") == run,
                  let value = object["value"] as? [String: Any],
                  let recipient = value["recipient"] as? [String: Any],
                  let url = URL(string: value["url"] as? String ?? ""), url.scheme == "https",
                  let recordName = recipient["recordName"] as? String else { return }
            let fixture = try JSONDecoder().decode(Envelope<Fixture>.self, from: Data(contentsOf: folder.appendingPathComponent("fixture.json")))
            guard fixture.runID == run else { return }
            let service = CKContainer(identifier: identifier)
            let user = try await service.userRecordID()
            log("Recipient matches current account: \(user.recordName == recordName)")
            if role == "owner" {
                retainedDatabase = try await GraphDatabase.openMirrored(privateStoreAt: folder.appendingPathComponent("private.sqlite"),
                    sharedStoreAt: folder.appendingPathComponent("shared.sqlite"), containerIdentifier: identifier, schema: .nativeIdentity)
            }
            for attempt in 0..<(requestedRole == "peer-visibility" ? 18 : 1) {
                do {
                    let metadata = try await service.shareMetadata(for: url)
                    log("Share metadata readable; participant status=\(metadata.participantStatus.rawValue)")
                    break
                } catch {
                    if attempt == 0 || attempt == 17 { self.error(error, phase: "shareMetadata") }
                    if requestedRole == "peer-visibility" && attempt < 17 { try await Task.sleep(for: .seconds(10)) }
                }
            }
            if let db = retainedDatabase {
                do {
                    if let boundary = try await db.inspectMirroring(for: fixture.value.a).boundary {
                        let id = CKRecord.ID(recordName: boundary.shareRecordName,
                            zoneID: CKRecordZone.ID(zoneName: boundary.zoneName, ownerName: CKCurrentUserDefaultName))
                        let record = try await service.privateCloudDatabase.record(for: id)
                        if let share = record as? CKShare {
                            log("Server share exists; URL matches invitation: \(share.url == url)")
                            log("Server recipient user-record match: \(share.participants.contains { $0.userIdentity.userRecordID?.recordName == recordName })")
                            log("Server participant count: \(share.participants.count)")
                            for participant in share.participants {
                                log("Server participant role=\(participant.role.rawValue) acceptance=\(participant.acceptanceStatus.rawValue) permission=\(participant.permission.rawValue) hasUserRecord=\(participant.userIdentity.userRecordID != nil)")
                            }
                        }
                    }
                } catch { self.error(error, phase: "ownerShareRead") }
            }
            log("PASS read-only diagnostics; no invitation, acceptance or native assignment invoked.")
        } catch { self.error(error, phase: "diagnostic") }
    }
}
