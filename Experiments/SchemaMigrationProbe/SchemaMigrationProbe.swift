import UIKit
import CloudKit
@testable import GraphEvo

/// Disposable laboratory: no application data or native context escapes into the controller.
@available(iOS 17, *)
@MainActor final class SchemaMigrationProbeViewModel {
    private struct Transport<Value: Codable>: Codable { let run: UUID; let value: Value }
    private struct Report: Codable {
        let stage: String
        let launchTicket: UUID?
        let processID: Int32
        let succeeded: Bool
        let rows: [GraphSchemaMigrationLaboratory.Row]
        let handlers: [String]
        let nativeOperation: String
        let events: [GraphSchemaMigrationLaboratory.NativeEvent]
        let errorDomain: String?
        let errorCode: Int?
    }
    private var owner: GraphSchemaMigrationLaboratory?
    var changed: ((String) -> Void)?
    private(set) var status = "Schema migration laboratory; an explicit CLI stage is required."
    private func publish(_ value: String) { status = value; changed?(value) }
    private var started = false

    private func write<T: Codable>(_ value: T, to url: URL, run: UUID) throws {
        try JSONEncoder().encode(Transport(run: run, value: value)).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read<T: Codable>(_ type: T.Type, at url: URL, run: UUID) throws -> T {
        let result = try JSONDecoder().decode(Transport<T>.self, from: Data(contentsOf: url))
        guard result.run == run else { throw GraphSchemaMigrationLaboratory.Failure.fixture }; return result.value
    }

    func start(arguments: [String]) {
        guard !started else { return }; started = true
        Task {
            var root: URL?, report: URL?, run: UUID?, stage = "invalid"
            let ticketIndex = arguments.firstIndex(of: "--launch-ticket")
            let ticket = ticketIndex.flatMap { arguments.count > $0 + 1 ? UUID(uuidString: arguments[$0 + 1]) : nil }
            var rows: [GraphSchemaMigrationLaboratory.Row] = []
            do {
                guard let flag = arguments.firstIndex(of: "--schema"), arguments.count > flag + 3,
                      let id = UUID(uuidString: arguments[flag + 2]),
                      ["lightweight", "staged"].contains(arguments[flag + 3]),
                      let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String else {
                    throw GraphSchemaMigrationLaboratory.Failure.fixture
                }
                stage = arguments[flag + 1]; run = id
                let allowed = ["identity", "identity-refresh", "seed", "invite-prepared", "finish-invitation",
                    "diagnose", "diagnose-second", "migrate", "post-save", "owner-read", "peer-join", "peer-handler",
                    "peer-old", "peer-new", "peer-fresh", "peer-version-one", "peer-fresh-one", "peer-confirm", "peer-confirm-two"]
                guard allowed.contains(stage), !identifier.isEmpty else { throw GraphSchemaMigrationLaboratory.Failure.fixture }
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GraphEvoLaboratory/SchemaMigration/" + id.uuidString)
                root = folder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent(stage + ".report.json")
                guard !FileManager.default.fileExists(atPath: output.path),
                      !FileManager.default.fileExists(atPath: folder.appendingPathComponent(stage + ".json").path) else { throw GraphSchemaMigrationLaboratory.Failure.replay }
                try Data("reserved".utf8).write(to: output, options: .withoutOverwriting); report = output
                publish("Running " + stage)
                if stage == "identity" || stage == "identity-refresh" {
                    let identity = try await CKContainer(identifier: identifier).userRecordID().recordName
                    try write(identity, to: folder.appendingPathComponent("identity.json"), run: id)
                } else {
                    let isPeer = stage.hasPrefix("peer")
                    let fresh = stage == "peer-fresh" || stage == "peer-fresh-one"
                    let location = fresh ? folder.appendingPathComponent(stage == "peer-fresh-one" ? "fresh-one" : "fresh") : folder
                    let urls = isPeer ? [location.appendingPathComponent("private.sqlite"), location.appendingPathComponent("shared.sqlite")] : [location.appendingPathComponent("private.sqlite")]
                    let migrating = stage == "migrate"
                    let readVersionOne = ["peer-version-one", "peer-fresh-one"].contains(stage)
                    let readVersionTwo = ["peer-new", "peer-fresh"].contains(stage) || stage.hasPrefix("peer-confirm")
                    let newModel = migrating || ["post-save", "owner-read"].contains(stage) || readVersionOne || readVersionTwo
                    let route: GraphSchemaMigrationLaboratory.Route = migrating && arguments[flag + 3] == "staged" ? .staged : .lightweight
                    let db = try await GraphSchemaMigrationLaboratory.open(urls: urls, run: id, layout: newModel ? .versioned : .v1,
                        identifier: identifier, route: route)
                    owner = db
                    try await db.waitForSetup()
                    if stage == "seed" {
                        try await db.seed()
                        rows = try await db.snapshot()
                        try write(rows, to: folder.appendingPathComponent("baseline.json"), run: id)
                        let recipient = try read(String.self, at: folder.appendingPathComponent("identity.json"), run: id)
                        let invitation = try await db.invitation(recipient: recipient)
                        try write(invitation, to: folder.appendingPathComponent("invitation.json"), run: id)
                    } else if stage == "peer-join" {
                        try await db.accept(url: read(URL.self, at: folder.appendingPathComponent("invitation.json"), run: id), identifier: identifier)
                        rows = try await db.waitForRows()
                        let baseline = try read([GraphSchemaMigrationLaboratory.Row].self, at: folder.appendingPathComponent("baseline.json"), run: id)
                        guard rows == baseline else { throw GraphSchemaMigrationLaboratory.Failure.fixture }
                    } else if stage == "invite-prepared" {
                        let baseline = try read([GraphSchemaMigrationLaboratory.Row].self, at: folder.appendingPathComponent("baseline.json"), run: id)
                        rows = try await db.snapshot()
                        guard rows == baseline else { throw GraphSchemaMigrationLaboratory.Failure.fixture }
                        let recipient = try read(String.self, at: folder.appendingPathComponent("identity.json"), run: id)
                        let invitation = try await db.invitation(recipient: recipient)
                        try write(invitation, to: folder.appendingPathComponent("invitation.json"), run: id)
                    } else if stage == "finish-invitation" {
                        let recipient = try read(String.self, at: folder.appendingPathComponent("identity.json"), run: id)
                        let invitation = try await db.invitation(recipient: recipient, existingOnly: true)
                        try write(invitation, to: folder.appendingPathComponent("invitation.json"), run: id)
                        rows = try await db.snapshot()
                    } else if stage.hasPrefix("diagnose") {
                        rows = try await db.snapshot()
                        let count = try await db.inspectExistingShare()
                        publish("Read-only existing share mappings: \(count)")
                    } else if stage == "migrate" {
                        rows = try await db.snapshot()
                        guard rows.count == 4 else { throw GraphSchemaMigrationLaboratory.Failure.fixture }
                    } else if stage == "post-save" {
                        try await db.transform(value: "ordinary-save", version: 2)
                        rows = try await db.snapshot()
                    } else if readVersionOne {
                        rows = try await db.waitForRows(label: "handler-after", version: 1)
                    } else if readVersionTwo {
                        rows = try await db.waitForRows(label: "ordinary-save", version: 2)
                    } else if stage == "peer-handler" {
                        rows = try await db.waitForRows(label: "handler-after")
                    } else if stage == "peer-old" {
                        rows = try await db.waitForRows()
                    } else if stage == "owner-read" {
                        rows = try await db.snapshot()
                    } else { throw GraphSchemaMigrationLaboratory.Failure.fixture }
                }
                let result = Report(stage: stage, launchTicket: ticket, processID: ProcessInfo.processInfo.processIdentifier, succeeded: true,
                    rows: rows, handlers: owner?.handlerEvents ?? [], nativeOperation: owner?.lastNativeOperation ?? "none", events: owner?.nativeEvents ?? [], errorDomain: nil, errorCode: nil)
                try write(result, to: output, run: id)
                publish("PASS " + stage + " rows=\(rows.count). Owner retained; inspect independent replica evidence.")
            } catch {
                let error = error as NSError
                if let root {
                    try? String(describing: error).write(to: root.appendingPathComponent(stage + "-framework-error.txt"), atomically: true, encoding: .utf8)
                }
                if let report, let run {
                    let result = Report(stage: stage, launchTicket: ticket, processID: ProcessInfo.processInfo.processIdentifier, succeeded: false,
                        rows: rows, handlers: owner?.handlerEvents ?? [], nativeOperation: owner?.lastNativeOperation ?? "none", events: owner?.nativeEvents ?? [], errorDomain: error.domain, errorCode: error.code)
                    try? write(result, to: report, run: run)
                }
                publish("FAIL " + stage + " domain=" + error.domain + " code=\(error.code). No automatic retry.")
            }
            _ = root
        }
    }
}

@available(iOS 17, *)
@MainActor final class SchemaMigrationProbeViewController: UIViewController {
    private let model = SchemaMigrationProbeViewModel()
    private let text = UITextView()
    private let arguments: [String]
    init(arguments: [String]) { self.arguments = arguments; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use explicit laboratory arguments.") }
    override func viewDidLoad() {
        super.viewDidLoad(); view = text; text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.text = model.status
        model.changed = { [weak self] in self?.text.text = $0 }
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func startProbe() { model.start(arguments: arguments) }
}
