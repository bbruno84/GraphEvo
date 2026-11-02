import CloudKit
import Foundation
import UIKit

/// External-only synthetic proof of the MF10 first-create exclusion prerequisite.
@available(iOS 17, *)
@MainActor final class RecordTransportProbeViewController: UIViewController {
    private let arguments: [String]
    private let text = UITextView()
    private var started = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic laboratory only") }
    override func loadView() { text.isEditable = false; text.text = "MF10 authority prerequisite"; view = text }
    func startProbe() {
        guard !started else { return }; started = true
        Task { await run() }
    }
    private func run() async {
        guard let flag = arguments.firstIndex(of: "--record-transport"), arguments.count > flag + 3,
              arguments[flag + 1] == "claim-exclusion", arguments[flag + 3] == "owner",
              let run = UUID(uuidString: arguments[flag + 2]),
              let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GraphEvoLaboratory/AuthoritativeCloud/" + run.uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("claim.started"), options: .withoutOverwriting)
        } catch { text.text = "Refused existing or unavailable stage. No replay."; return }
        do {
            let checks = try await Self.prove(container: container, run: run)
            try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks], options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("claim.report.json"), options: .withoutOverwriting)
            text.text = (["PASS"] + checks).joined(separator: "\n")
        } catch {
            let e = error as NSError
            let report: [String: Any] = ["status": "failed", "domain": e.domain, "code": e.code]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("claim.report.json"), options: .withoutOverwriting)
            text.text = "Claim proof failed. Inspect retained evidence; do not replay."
        }
    }
    nonisolated private static func save(_ database: CKDatabase, id: CKRecord.ID, value: String) async -> Int {
        let record = CKRecord(recordType: "GraphEvoActivation", recordID: id)
        record["graphID"] = value as CKRecordValue
        record["payload"] = Data(value.utf8) as CKRecordValue
        do {
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let item = result.saveResults[id] else { return -1 }
            _ = try item.get(); return 0
        } catch let error as CKError { return error.code.rawValue }
        catch { return -1 }
    }
    nonisolated private static func prove(container: String, run: UUID) async throws -> [String] {
        let database = CKContainer(identifier: container).privateCloudDatabase
        guard try await CKContainer(identifier: container).accountStatus() == .available else { throw ProofFailure() }
        let zone = CKRecordZone(zoneName: "GE2-MF10-Claim-" + run.uuidString)
        _ = try await database.save(zone)
        let id = CKRecord.ID(recordName: "graphevo.activation", zoneID: zone.zoneID)
        let a = UUID().uuidString, b = UUID().uuidString
        async let left = save(database, id: id, value: a)
        async let right = save(database, id: id, value: b)
        let results = await [left, right]
        guard results.filter({ $0 == 0 }).count == 1,
              results.filter({ $0 == CKError.serverRecordChanged.rawValue }).count == 1 else { throw ProofFailure() }
        let winner = try await database.record(for: id)
        let value = results[0] == 0 ? a : b
        guard winner["graphID"] as? String == value, winner.recordChangeTag != nil else { throw ProofFailure() }
        let loser = await save(database, id: id, value: UUID().uuidString)
        guard loser == CKError.serverRecordChanged.rawValue else { throw ProofFailure() }
        let unchanged = try await database.record(for: id)
        guard unchanged["graphID"] as? String == value,
              unchanged.recordChangeTag == winner.recordChangeTag else { throw ProofFailure() }
        return ["Two independent untagged first saves: exactly one accepted and one serverRecordChanged.",
                "Exact winner fetched with a real server change tag.",
                "A later untagged contender is rejected without changing the winner.",
                "Fresh synthetic private zone retained; no reset or application data used."]
    }
    private struct ProofFailure: Error {}
}
