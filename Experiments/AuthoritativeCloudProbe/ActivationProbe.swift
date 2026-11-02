import Foundation
import GraphEvo
import UIKit

@available(iOS 17, *)
@MainActor final class RecordTransportProbeViewController: UIViewController {
    private let arguments: [String]
    private let probe = GraphCloudActivationDeviceProbe()
    private let text = UITextView()
    private var started = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic laboratory only") }
    override func loadView() { text.isEditable = false; text.text = "MF10 explicit stage"; view = text }
    func startProbe() {
        guard !started else { return }; started = true
        Task { await run() }
    }
    private func run() async {
        guard let flag = arguments.firstIndex(of: "--record-transport"), arguments.count > flag + 3,
              let run = UUID(uuidString: arguments[flag + 2]),
              let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else { return }
        let stage = arguments[flag + 1], replica = arguments[flag + 3]
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GraphEvoLaboratory/AuthoritativeCloud")
        let root = base.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        do {
            let checks = try await probe.execute(stage: stage, run: run, replica: replica, directory: base, container: container)
            try JSONSerialization.data(withJSONObject: ["status": "passed", "stage": stage, "replica": replica, "checks": checks], options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent(stage + ".report.json"), options: .withoutOverwriting)
            text.text = (["PASS " + stage] + checks).joined(separator: "\n")
        } catch {
            let native = error as NSError
            let report: [String: Any] = ["status": "failed", "stage": stage, "replica": replica, "domain": native.domain, "code": native.code]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent(stage + ".report.json"), options: .withoutOverwriting)
            text.text = "Stage failed. Retain evidence; no automatic replay."
        }
    }
}
