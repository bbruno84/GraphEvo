import Foundation
import GraphEvo
import UIKit

@available(iOS 17, *)
@MainActor final class RecordTransportProbeViewController: UIViewController {
    private let arguments: [String]
    private let probe = GraphCloudTransportDeviceProbe()
    private let text = UITextView()
    private var started = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic laboratory only") }
    override func loadView() { text.isEditable = false; text.text = "GraphEvo T01 — preparing explicit request"; view = text }
    func startProbe() {
        guard !started else { return }; started = true
        Task { await run() }
    }
    private func run() async {
        guard let flag = arguments.firstIndex(of: "--record-transport"), arguments.count > flag + 3,
              let run = UUID(uuidString: arguments[flag + 2]),
              let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String,
              !container.isEmpty else { text.text = "Invalid explicit laboratory request."; return }
        let stage = arguments[flag + 1], replica = arguments[flag + 3]
        guard ["owner", "peer", "fresh"].contains(replica),
              ["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"].contains(stage) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GraphEvoLaboratory/RecordTransport")
        let folder = base.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // UI/launcher receipt and stage reservation are independent acknowledgements.
            let messages = try await probe.execute(stage: stage, run: run, replica: replica, directory: base, container: container)
            let report = ["status": "passed", "stage": stage, "replica": replica, "checks": messages] as [String: Any]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent(stage + ".report.json"), options: .withoutOverwriting)
            text.text = (["PASS " + stage] + messages).joined(separator: "\n")
        } catch {
            let native = error as NSError
            let message = "Failure domain \(native.domain), code \(native.code). No automatic stage replay."
            let report = ["status": "failed", "stage": stage, "replica": replica, "error": message]
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(stage + ".report.json").path) {
                try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                    .write(to: folder.appendingPathComponent(stage + ".report.json"), options: .withoutOverwriting)
            }
            text.text = message
        }
    }
}
