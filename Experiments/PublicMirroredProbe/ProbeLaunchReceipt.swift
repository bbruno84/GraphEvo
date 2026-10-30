import Foundation
import os

/// Payload-free acknowledgement for disposable host launches, independent of Graph/store work.
@MainActor enum ProbeLaunchReceipt {
    private struct Receipt: Encodable {
        let requestID: UUID
        let processIdentifier: Int32
        var milestones: [String]
    }
    private static var receipt: Receipt?
    private static var destination: URL?
    private static let logger = Logger(subsystem: "GraphEvo.PublicMirroredProbe", category: "Launch")

    static func start(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--launch-ticket"), arguments.count > flag + 1,
              let request = UUID(uuidString: arguments[flag + 1]) else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GraphEvoLaboratory/LaunchReceipts")
        destination = folder.appendingPathComponent(request.uuidString + ".json")
        receipt = Receipt(requestID: request, processIdentifier: ProcessInfo.processInfo.processIdentifier, milestones: [])
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { logger.error("Launch receipt directory unavailable."); return }
        mark("didFinishLaunching")
    }

    static func mark(_ milestone: String) {
        guard var value = receipt, let destination else { return }
        value.milestones.append(milestone); receipt = value
        do { try JSONEncoder().encode(value).write(to: destination, options: .atomic) }
        catch { logger.error("Launch receipt write failed.") }
    }
}
