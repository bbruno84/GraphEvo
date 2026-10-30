import UIKit
import WidgetKit

@MainActor final class WidgetLaboratoryViewModel {
    private let owner = WidgetProbeOwner()
    private(set) var isBusy = false
    var changed: ((String) -> Void)?

    func perform(_ action: String, run: UUID) {
        guard !isBusy else { return }; isBusy = true
        changed?("Running \(action)…")
        Task {
            var ticket: URL?
            do {
                let parts = action.split(separator: "-", maxSplits: 1).map(String.init)
                guard let verb = parts.first else { throw WidgetProbeStorage.Failure.mismatch }
                let manual = ["increment", "reload", "close"].contains(verb) && parts.count == 2 && UUID(uuidString: parts[1]) != nil
                guard ["local", "cloud", "update1", "update2", "reload", "close"].contains(action) || manual else { throw WidgetProbeStorage.Failure.mismatch }
                let root = try WidgetProbeStorage.root()
                let reports = root.appendingPathComponent("AppReports/\(run.uuidString)")
                try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
                let report = reports.appendingPathComponent(action + ".txt")
                guard !FileManager.default.fileExists(atPath: report.path) else { throw WidgetProbeStorage.Failure.replay }
                try "reserved\n".write(to: report, atomically: true, encoding: .utf8); ticket = report
                let message: String
                switch manual ? verb : action {
                case "local", "cloud":
                    let value = try await owner.prepare(run: run, mirrored: action == "cloud")
                    message = "Value \(value). Application owner retained."
                case "update1", "update2", "increment":
                    let value = try await owner.increment(expectedRun: run)
                    message = "Committed value \(value). Application owner retained."
                case "close": try await owner.close(); message = "Application owner closed."
                case "reload": message = "Requested a new WidgetKit timeline; delivery is system-scheduled."
                default: throw WidgetProbeStorage.Failure.mismatch
                }
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetProbeStorage.kind)
                let summary = "PASS \(action) pid=\(ProcessInfo.processInfo.processIdentifier)\n" + message + "\n"
                try summary.write(to: report, atomically: true, encoding: .utf8)
                changed?(summary + "\nAdd ‘GraphEvo laboratory’ to the Home Screen and compare its value.\n")
            } catch {
                let error = error as NSError
                let summary = "FAIL \(action) domain=\(error.domain) code=\(error.code)\n"
                if let ticket { try? summary.write(to: ticket, atomically: true, encoding: .utf8) }
                changed?(summary)
            }
            isBusy = false
        }
    }
}

@MainActor final class WidgetLaboratoryViewController: UIViewController {
    private let model = WidgetLaboratoryViewModel()
    private let report = UITextView()
    private var runID = UUID()
    private let arguments: [String]
    private var started = false
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use the laboratory initializer.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GraphEvo widget laboratory"
        view.backgroundColor = .systemBackground
        report.isEditable = false; report.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        report.text = "Add the GraphEvo laboratory widget first to test the missing-store state.\nThen prepare a new local fixture or a CloudKit fixture.\nOnly the application writes to Graph."
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.addArrangedSubview(button("Prepare local fixture", action: #selector(local)))
        stack.addArrangedSubview(button("Prepare CloudKit fixture", action: #selector(cloud)))
        stack.addArrangedSubview(button("Increment in the app", action: #selector(increment)))
        stack.addArrangedSubview(button("Request widget refresh", action: #selector(reload)))
        stack.addArrangedSubview(button("Close application owner", action: #selector(closeOwner)))
        stack.addArrangedSubview(report); stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)])
        model.changed = { [weak self] in self?.report.text = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
        if let root = try? WidgetProbeStorage.root(), let active = try? WidgetProbeStorage.manifest(in: root) { runID = active.runID }
        startProbe()
    }
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside); return button
    }
    func startProbe() {
        guard !started else { return }; started = true
        guard let flag = arguments.firstIndex(of: "--widget-lab"), arguments.count > flag + 2,
              let run = UUID(uuidString: arguments[flag + 2]) else { return }
        runID = run; model.perform(arguments[flag + 1], run: run)
    }
    @objc private func local() { guard !model.isBusy else { return }; runID = UUID(); model.perform("local", run: runID) }
    @objc private func cloud() { guard !model.isBusy else { return }; runID = UUID(); model.perform("cloud", run: runID) }
    @objc private func increment() {
        guard !model.isBusy else { return }
        model.perform("increment-" + UUID().uuidString, run: runID)
    }
    @objc private func reload() { model.perform("reload-" + UUID().uuidString, run: runID) }
    @objc private func closeOwner() { model.perform("close-" + UUID().uuidString, run: runID) }
}
