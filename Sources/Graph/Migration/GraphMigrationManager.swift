//
//  GraphMigrationManager.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

public struct GraphMigrationContext {
    private var values: [String: Any]
    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }
    public subscript<T>(key: String) -> T? {
        return values[key] as? T
    }
    public mutating func set<T>(_ key: String, value: T) {
        values[key] = value
    }
}

public extension GraphMigrationContext {
    var previousMigrationRecord: GraphMigrationRecord? {
        self["GraphMigration.previousRecord"]
    }
}

/// A protocol for defining custom graph migrations.
public enum GraphMigrationResult {
    case done
    case error(Error)
    case fallback
    case skipped
}

public protocol GraphMigration {
    var id: String { get }
    var version: Int { get }
    var completionSynchronization: GraphMigrationCompletionSynchronization { get }
    /// Default root folder for backups used by this migration.
    /// Implementations can override to customize the backup location.
    /// If `nil` is returned, a standard location derived from the
    /// GraphStoreConfiguration will be used.
    func backupRoot(for configuration: GraphStoreConfiguration?) -> URL?
    func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context:GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool
    func recognizesLegacyCompletion(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) -> Bool
    /// Handle remote changes delivered from Persistent History.
    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID])
    
    func resetMigrationState(for configuration: GraphStoreConfiguration)
}

public extension GraphMigration {
    var version: Int { 1 }
    var completionSynchronization: GraphMigrationCompletionSynchronization { .local }

    /// Default implementation: uses GraphMigrationManager.defaultBackupRoot(for:)
    /// if a configuration is available.
    func backupRoot(for configuration: GraphStoreConfiguration?) -> URL? {
        guard let config = configuration else { return nil }
        return GraphMigrationManager.defaultBackupRoot(for: config)
    }
    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID]) {
        // Default empty implementation
    }
    func recognizesLegacyCompletion(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) -> Bool {
        false
    }
    func resetMigrationState(for configuration: GraphStoreConfiguration) {
        try? GraphMigrationManager.resetRecord(for: self, configuration: configuration)
    }
}

/// Manages the migrations of the Graph store.
/// This becomes the official system for all future migrations.
public final class GraphMigrationManager {
    
    public enum GraphLifecyclePhase {
        case preInit
        case postInit
        case postMigration
        case ready
    }
    
    /// Default base folder where migrations can store their backups
    /// (e.g. SQLite stores, baseline.zip, etc.).
    ///
    /// By convention this is:
    ///   <storeDir>/../migrationBackups/
    /// where `storeDir` is the directory that contains the resolved store URL.
    public static func defaultBackupRoot(for configuration: GraphStoreConfiguration) -> URL {
        let storeDir = configuration.resolvedStoreURL.deletingLastPathComponent()
        return storeDir
            .deletingLastPathComponent()
            .appendingPathComponent("migrationBackups", isDirectory: true)
    }
    
    /// Stores lifecycle phase callbacks. The callback receives the store configuration and an optional Graph context.
    /// Some phases may not provide a Graph instance.
    private static var callbacks: [GraphLifecyclePhase: [(GraphStoreConfiguration?, Graph?) -> Void]] = [:]

    /// Stores all registered migrations in order.
    private static var migrations: [GraphMigration] = []
    /// Tracks the current migration index for sequential execution.
    private static var currentMigrationIndex: Int = 0
    
    /// Tracks active migrations that have been activated in .preInit phase.
    private static var activeMigrations: Set<String> = []

    /// Prevents terminal migration decisions from being repeated at every lifecycle phase.
    private static var loggedTerminalDecisions: Set<String> = []

    /// Shared context for the entire migration cycle.
    private static var currentContext: GraphMigrationContext? = nil

    public static func record(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) -> GraphMigrationRecord? {
        GraphMigrationLedger.reconciledRecord(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: configuration
        )
    }

    public static func resetRecord(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) throws {
        try GraphMigrationLedger.reset(
            migrationID: migration.id,
            version: migration.version,
            synchronization: migration.completionSynchronization,
            configuration: configuration
        )
    }

    /// Registers a callback to be executed during a given lifecycle phase.
    /// The callback receives the store configuration and an optional Graph context. Some phases may not provide a Graph instance.
    public static func registerCallback(for phase: GraphLifecyclePhase, _ callback: @escaping (GraphStoreConfiguration?, Graph?) -> Void) {
        if callbacks[phase] != nil {
            callbacks[phase]?.append(callback)
        } else {
            callbacks[phase] = [callback]
        }
    }

    /// Registers a migration to be executed at lifecycle phases.
    public static func registerMigration(_ migration: GraphMigration) {
        // Ensure we do not register the same migration twice (by id).
        guard !migrations.contains(where: { $0.id == migration.id }) else { return }
        migrations.append(migration)
    }
    
    /// Registers multiple migrations to be executed at lifecycle phases.
    public static func registerMigrations(_ migrations: [GraphMigration]) {
        migrations.forEach { registerMigration($0) }
    }
    
    /// Executes all callbacks and registered migrations for the specified lifecycle phase, running migrations in sequence.
    /// - Parameters:
    ///   - phase: The lifecycle phase being handled.
    ///   - configuration: The Core Data store configuration this phase refers to.
    ///   - graph: Optional Graph instance (may be nil in early phases).
    public static func handlePhase(_ phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        // Post notification for phase change
        postPhaseNotification(phase: phase, configuration: configuration, graph: graph)
        GraphMigrationLogger.log(
            migrationID: "GraphMigrationManager",
            phase: phase,
            level: .info,
            event: "lifecycle_phase_entered",
            message: "Graph lifecycle phase entered; no migration has started yet",
            metadata: ["graphID": graph?.name ?? ""],
            configuration: configuration
        )
        // Fire callbacks
        callbacks[phase]?.forEach { $0(configuration, graph) }
        // Reset migration index for every phase
        currentMigrationIndex = 0
        // Use existing context if present, otherwise create new one
        if currentContext == nil {
            currentContext = GraphMigrationContext()
        }
        runNextMigration(for: phase, configuration: configuration, graph: graph, context: currentContext)
        // Reset context when phase is ready
        if phase == .ready {
            currentContext = nil
        }
    }

    /// Runs the next migration in sequence for the given phase.
    private static func runNextMigration(for phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext? = nil) {
        guard currentMigrationIndex < migrations.count else { return }
        let migration = migrations[currentMigrationIndex]

        let isActive = activeMigrations.contains(migration.id)
        var mutableContext = context

        if !isActive, let configuration {
            let localRecord = GraphMigrationLedger.localRecord(
                migrationID: migration.id,
                version: migration.version,
                configuration: configuration
            )
            let previousRecord = record(for: migration, configuration: configuration)
            if let previousRecord {
                mutableContext?.set("GraphMigration.previousRecord", value: previousRecord)
            }

            if let previousRecord, previousRecord.state == .done {
                let source = localRecord?.state == .done ? "local_ledger" : "icloud_kvs"
                logTerminalDecisionOnce(
                    migration: migration,
                    phase: phase,
                    reason: "ledger_done",
                    source: source,
                    record: previousRecord,
                    configuration: configuration
                )
                advanceToNextMigration(for: phase, configuration: configuration, graph: graph, context: mutableContext)
                return
            }

            if migration.recognizesLegacyCompletion(at: phase, configuration: configuration, graph: graph) {
                persistDone(
                    for: migration,
                    configuration: configuration,
                    event: "legacy_completion_adopted"
                )
                advanceToNextMigration(for: phase, configuration: configuration, graph: graph, context: mutableContext)
                return
            }
        }

        let needsRun = migration.needsRun(at: phase, configuration: configuration, graph: graph, context: &mutableContext)
        currentContext = mutableContext

        if !isActive && !needsRun {
            advanceToNextMigration(for: phase, configuration: configuration, graph: graph, context: mutableContext)
            return
        }

        if !isActive, needsRun, let configuration {
            persistStarted(for: migration, configuration: configuration)
            if phase == .preInit {
                activeMigrations.insert(migration.id)
            }
        }

        migration.handlePhase(phase, configuration: configuration, graph: graph, context: mutableContext) { result in
            switch result {
            case .done, .fallback:
                let completesMigration = phase == .ready || !activeMigrations.contains(migration.id)
                if completesMigration, let configuration {
                    persistDone(for: migration, configuration: configuration)
                }
                if phase == .ready {
                    activeMigrations.remove(migration.id)
                }
                advanceToNextMigration(for: phase, configuration: configuration, graph: graph, context: mutableContext)
            case .skipped:
                if let configuration {
                    clearStartedRecord(for: migration, configuration: configuration)
                }
                activeMigrations.remove(migration.id)
                advanceToNextMigration(for: phase, configuration: configuration, graph: graph, context: mutableContext)
            case .error(let error):
                if let configuration {
                    persistFailed(for: migration, error: error, configuration: configuration)
                }
                // Log error and stop further migrations
                GraphMigrationLogger.log(
                    migrationID: migration.id,
                    phase: phase,
                    level: .error,
                    event: "migration_failed",
                    message: error.localizedDescription,
                    metadata: ["graphID": graph?.name ?? ""],
                    configuration: configuration
                )
                postFailureNotification(
                    migrationID: migration.id,
                    phase: phase,
                    configuration: configuration,
                    graph: graph,
                    error: error
                )
                activeMigrations.remove(migration.id)
            }
        }
    }
}

// MARK: - Notifications
public extension Notification.Name {
    /// Notification posted when a migration phase changes.
    static let migrationPhaseDidChange = Notification.Name("GraphMigrationManager.migrationPhaseDidChange")
    /// Notification posted when a migration fails.
    static let graphMigrationDidFail = Notification.Name("GraphMigrationManager.graphMigrationDidFail")
    
}

private extension GraphMigrationManager {
    static func advanceToNextMigration(
        for phase: GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?
    ) {
        currentMigrationIndex += 1
        if currentMigrationIndex < migrations.count {
            runNextMigration(for: phase, configuration: configuration, graph: graph, context: context)
        }
    }

    static func persistStarted(for migration: GraphMigration, configuration: GraphStoreConfiguration) {
        do {
            _ = try GraphMigrationLedger.markStarted(
                migrationID: migration.id,
                version: migration.version,
                configuration: configuration
            )
            logLedgerEvent("migration_started", migration: migration, configuration: configuration)
        } catch {
            logLedgerError(error, event: "migration_started_write_failed", migration: migration, configuration: configuration)
        }
    }

    static func persistDone(
        for migration: GraphMigration,
        configuration: GraphStoreConfiguration,
        event: String = "migration_done"
    ) {
        do {
            _ = try GraphMigrationLedger.markDone(
                migrationID: migration.id,
                version: migration.version,
                synchronization: migration.completionSynchronization,
                configuration: configuration
            )
            logLedgerEvent(event, migration: migration, configuration: configuration)
        } catch {
            logLedgerError(error, event: "migration_done_write_failed", migration: migration, configuration: configuration)
        }
    }

    static func persistFailed(
        for migration: GraphMigration,
        error: Error,
        configuration: GraphStoreConfiguration
    ) {
        do {
            _ = try GraphMigrationLedger.markFailed(
                migrationID: migration.id,
                version: migration.version,
                error: error,
                configuration: configuration
            )
            logLedgerEvent("migration_failed", migration: migration, configuration: configuration)
        } catch {
            logLedgerError(error, event: "migration_failed_write_failed", migration: migration, configuration: configuration)
        }
    }

    static func clearStartedRecord(for migration: GraphMigration, configuration: GraphStoreConfiguration) {
        do {
            try GraphMigrationLedger.clearLocal(
                migrationID: migration.id,
                version: migration.version,
                configuration: configuration
            )
            logLedgerEvent("migration_skipped", migration: migration, configuration: configuration)
        } catch {
            logLedgerError(error, event: "migration_skipped_clear_failed", migration: migration, configuration: configuration)
        }
    }

    static func logLedgerEvent(
        _ event: String,
        migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) {
        GraphMigrationLogger.log(
            migrationID: migration.id,
            level: .info,
            event: event,
            message: "Migration ledger updated",
            metadata: ["version": String(migration.version)],
            configuration: configuration
        )
    }

    static func logLedgerError(
        _ error: Error,
        event: String,
        migration: GraphMigration,
        configuration: GraphStoreConfiguration
    ) {
        GraphMigrationLogger.log(
            migrationID: migration.id,
            level: .error,
            event: event,
            message: error.localizedDescription,
            metadata: ["version": String(migration.version)],
            configuration: configuration
        )
    }

    static func logTerminalDecisionOnce(
        migration: GraphMigration,
        phase: GraphLifecyclePhase,
        reason: String,
        source: String,
        record: GraphMigrationRecord,
        configuration: GraphStoreConfiguration
    ) {
        let key = "\(migration.id)-v\(migration.version)-\(reason)"
        guard loggedTerminalDecisions.insert(key).inserted else { return }

        GraphMigrationLogger.log(
            migrationID: migration.id,
            phase: phase,
            level: .info,
            event: "migration_not_started",
            message: "Migration will not start because completion is already recorded",
            metadata: [
                "reason": reason,
                "source": source,
                "state": record.state.rawValue,
                "version": String(record.version),
                "updatedAt": ISO8601DateFormatter().string(from: record.updatedAt)
            ],
            configuration: configuration
        )
    }

    /// Posts a notification for migration phase changes.
    static func postPhaseNotification(phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?) {
        let userInfo: [String: Any] = [
            "phase": phase,
            "storeURL": configuration?.storeURL as Any,
            "graphID": graph?.name ?? ""
        ]
        NotificationCenter.default.post(
            name: .migrationPhaseDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postFailureNotification(
        migrationID: String,
        phase: GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        error: Error
    ) {
        let userInfo: [String: Any] = [
            "migrationID": migrationID,
            "phase": phase,
            "storeURL": configuration?.resolvedStoreURL as Any,
            "graphID": graph?.name ?? "",
            "error": error,
            "errorDescription": error.localizedDescription
        ]
        NotificationCenter.default.post(
            name: .graphMigrationDidFail,
            object: nil,
            userInfo: userInfo
        )
    }
    

}
extension GraphMigrationManager {
    /// Handles remote entity changes from Persistent History by notifying all registered migrations.
    public static func handleRemoteEntityChanges(configuration: GraphStoreConfiguration?, graph: Graph?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID], context: GraphMigrationContext? = nil) {
        let ctx = context ?? currentContext ?? GraphMigrationContext()
        for migration in migrations {
            migration.handleRemoteChanges(configuration: configuration, graph: graph, context: ctx, inserted: inserted, updated: updated)
        }
    }
}
