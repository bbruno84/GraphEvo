//
//  GraphMigrationLedger.swift
//  GraphEvo
//

import Foundation

public enum GraphMigrationState: String, Codable, Sendable {
    case started
    case done
    case failed
}

public enum GraphMigrationCompletionSynchronization: Equatable, Sendable {
    case local
    case localAndICloudKeyValueStore
}

public struct GraphMigrationRecord: Codable, Equatable, Sendable {
    public let migrationID: String
    public let version: Int
    public let state: GraphMigrationState
    public let startedAt: Date
    public let updatedAt: Date
    public let errorDescription: String?

    public init(
        migrationID: String,
        version: Int,
        state: GraphMigrationState,
        startedAt: Date,
        updatedAt: Date,
        errorDescription: String? = nil
    ) {
        self.migrationID = migrationID
        self.version = version
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.errorDescription = errorDescription
    }
}

enum GraphMigrationLedger {
    private static let fileManager = FileManager.default
    private static let queue = DispatchQueue(label: "GraphEvo.migration-ledger")
    private static var didRequestCloudSynchronization = false
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func localRecord(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration
    ) -> GraphMigrationRecord? {
        queue.sync {
            let url = recordURL(migrationID: migrationID, version: version, configuration: configuration)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(GraphMigrationRecord.self, from: data)
        }
    }

    static func reconciledRecord(
        migrationID: String,
        version: Int,
        synchronization: GraphMigrationCompletionSynchronization,
        configuration: GraphStoreConfiguration
    ) -> GraphMigrationRecord? {
        let local = localRecord(migrationID: migrationID, version: version, configuration: configuration)
        guard synchronization == .localAndICloudKeyValueStore else { return local }

        if local?.state == .done {
            publishDone(local!, configuration: configuration)
            return local
        }

        guard let remote = remoteDoneRecord(
            migrationID: migrationID,
            version: version,
            configuration: configuration
        ) else {
            return local
        }

        try? write(remote, configuration: configuration)
        return remote
    }

    static func markStarted(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration,
        now: Date = Date()
    ) throws -> GraphMigrationRecord {
        let record = GraphMigrationRecord(
            migrationID: migrationID,
            version: version,
            state: .started,
            startedAt: now,
            updatedAt: now
        )
        try write(record, configuration: configuration)
        return record
    }

    static func markDone(
        migrationID: String,
        version: Int,
        synchronization: GraphMigrationCompletionSynchronization,
        configuration: GraphStoreConfiguration,
        now: Date = Date()
    ) throws -> GraphMigrationRecord {
        let previous = localRecord(migrationID: migrationID, version: version, configuration: configuration)
        let record = GraphMigrationRecord(
            migrationID: migrationID,
            version: version,
            state: .done,
            startedAt: previous?.startedAt ?? now,
            updatedAt: now
        )
        try write(record, configuration: configuration)
        if synchronization == .localAndICloudKeyValueStore {
            publishDone(record, configuration: configuration)
        }
        return record
    }

    static func markFailed(
        migrationID: String,
        version: Int,
        error: Error,
        configuration: GraphStoreConfiguration,
        now: Date = Date()
    ) throws -> GraphMigrationRecord {
        let previous = localRecord(migrationID: migrationID, version: version, configuration: configuration)
        let record = GraphMigrationRecord(
            migrationID: migrationID,
            version: version,
            state: .failed,
            startedAt: previous?.startedAt ?? now,
            updatedAt: now,
            errorDescription: error.localizedDescription
        )
        try write(record, configuration: configuration)
        return record
    }

    static func reset(
        migrationID: String,
        version: Int,
        synchronization: GraphMigrationCompletionSynchronization,
        configuration: GraphStoreConfiguration
    ) throws {
        try clearLocal(migrationID: migrationID, version: version, configuration: configuration)
        if synchronization == .localAndICloudKeyValueStore {
            NSUbiquitousKeyValueStore.default.removeObject(
                forKey: cloudKey(migrationID: migrationID, version: version, configuration: configuration)
            )
        }
    }

    static func clearLocal(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration
    ) throws {
        try queue.sync {
            let url = recordURL(migrationID: migrationID, version: version, configuration: configuration)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}

private extension GraphMigrationLedger {
    static func write(_ record: GraphMigrationRecord, configuration: GraphStoreConfiguration) throws {
        try queue.sync {
            let url = recordURL(
                migrationID: record.migrationID,
                version: record.version,
                configuration: configuration
            )
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(record).write(to: url, options: .atomic)
        }
    }

    static func recordURL(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration
    ) -> URL {
        GraphMigrationManager.defaultBackupRoot(for: configuration)
            .appendingPathComponent("ledger", isDirectory: true)
            .appendingPathComponent("\(safeComponent(migrationID))-v\(version).json")
    }

    static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("_") }
        return String(scalars).prefix(80).description
    }

    static func publishDone(_ record: GraphMigrationRecord, configuration: GraphStoreConfiguration) {
        NSUbiquitousKeyValueStore.default.set(
            [
                "migrationID": record.migrationID,
                "version": Int64(record.version),
                "status": GraphMigrationState.done.rawValue,
                "completedAt": record.updatedAt
            ],
            forKey: cloudKey(
                migrationID: record.migrationID,
                version: record.version,
                configuration: configuration
            )
        )
    }

    static func remoteDoneRecord(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration
    ) -> GraphMigrationRecord? {
        requestCloudSynchronizationIfNeeded()
        guard let value = NSUbiquitousKeyValueStore.default.dictionary(
            forKey: cloudKey(migrationID: migrationID, version: version, configuration: configuration)
        ),
        value["status"] as? String == GraphMigrationState.done.rawValue else {
            return nil
        }

        let completedAt = value["completedAt"] as? Date ?? Date()
        return GraphMigrationRecord(
            migrationID: migrationID,
            version: version,
            state: .done,
            startedAt: completedAt,
            updatedAt: completedAt
        )
    }

    static func requestCloudSynchronizationIfNeeded() {
        let shouldSynchronize = queue.sync {
            guard !didRequestCloudSynchronization else { return false }
            didRequestCloudSynchronization = true
            return true
        }
        if shouldSynchronize {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    static func cloudKey(
        migrationID: String,
        version: Int,
        configuration: GraphStoreConfiguration
    ) -> String {
        let identity = [
            configuration.cloudKitContainerIdentifier ?? "local",
            configuration.name,
            migrationID,
            String(version)
        ].joined(separator: "|")
        return "GraphMigration.done.\(fnv1a64(identity))"
    }

    static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
