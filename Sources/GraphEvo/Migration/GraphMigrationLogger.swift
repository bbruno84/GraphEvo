//
//  GraphMigrationLogger.swift
//  Graph
//
//  Created by Codex on 10/07/26.
//

import Foundation

public enum GraphMigrationLogLevel: String, Codable {
    case info
    case warning
    case error
}

public struct GraphMigrationLogEntry: Codable {
    public let date: Date
    public let migrationID: String
    public let phase: String
    public let level: GraphMigrationLogLevel
    public let event: String
    public let message: String
    public let metadata: [String: String]
}

public enum GraphMigrationLogger {
    public static let logDidAppendNotification = Notification.Name("GraphMigrationLogger.logDidAppend")

    /// File logging is opt-in. Applications can consume the notification or
    /// forward GraphEvent values to their own logging system instead.
    public static var fileLoggingEnabled = false

    @discardableResult
    public static func log(
        migrationID: String,
        phase: GraphMigrationManager.GraphLifecyclePhase? = nil,
        level: GraphMigrationLogLevel,
        event: String,
        message: String,
        metadata: [String: String] = [:],
        configuration: GraphStoreConfiguration? = nil
    ) -> GraphMigrationLogEntry {
        let entry = GraphMigrationLogEntry(
            date: Date(),
            migrationID: migrationID,
            phase: phase.map(String.init(describing:)) ?? "unknown",
            level: level,
            event: event,
            message: message,
            metadata: metadata
        )

        // Info and warning entries are already available through the
        // notification and, where enabled, the JSONL file. Printing them here
        // would duplicate the application's GraphEvent/logging pipeline.
        if level == .error {
            print(formatForConsole(entry))
        }
        if fileLoggingEnabled {
            append(entry, configuration: configuration)
        }
        NotificationCenter.default.post(
            name: logDidAppendNotification,
            object: nil,
            userInfo: ["entry": entry]
        )
        return entry
    }

    public static func logURL(for configuration: GraphStoreConfiguration) -> URL {
        GraphMigrationManager.defaultBackupRoot(for: configuration)
            .appendingPathComponent("migrationLogs", isDirectory: true)
            .appendingPathComponent("graph-migration.jsonl")
    }

    private static func append(_ entry: GraphMigrationLogEntry, configuration: GraphStoreConfiguration?) {
        guard let configuration else { return }

        let url = logURL(for: configuration)
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            let data = try JSONEncoder.graphMigrationLogEncoder.encode(entry)
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } else {
                var line = data
                line.append(0x0A)
                try line.write(to: url, options: .atomic)
            }
        } catch {
            print("[GraphMigrationLogger][error] failed_to_write_log: \(error.localizedDescription)")
        }
    }

    private static func formatForConsole(_ entry: GraphMigrationLogEntry) -> String {
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        return "[GraphMigration][\(entry.level.rawValue)][\(entry.migrationID)][\(entry.phase)] \(entry.event): \(entry.message)\(suffix)"
    }
}

private extension JSONEncoder {
    static var graphMigrationLogEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
