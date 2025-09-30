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

/// A protocol for defining custom graph migrations.
public enum GraphMigrationResult {
    case done
    case error(Error)
    case fallback
}

public protocol GraphMigration {
    var id: String { get }
    func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context:GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool
    /// Handle remote changes delivered from Persistent History.
    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID])
}

public extension GraphMigration {
    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID]) {
        // Default empty implementation
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
    
    /// Stores lifecycle phase callbacks. The callback receives the store configuration and an optional Graph context.
    /// Some phases may not provide a Graph instance.
    private static var callbacks: [GraphLifecyclePhase: [(GraphStoreConfiguration?, Graph?) -> Void]] = [:]

    /// Stores all registered migrations in order.
    private static var migrations: [GraphMigration] = []
    /// Tracks the current migration index for sequential execution.
    private static var currentMigrationIndex: Int = 0
    
    /// Tracks active migrations that have been activated in .preInit phase.
    private static var activeMigrations: Set<String> = []

    /// Shared context for the entire migration cycle.
    private static var currentContext: GraphMigrationContext? = nil

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
        // Always pass the context to needsRun
        var mutableContext = context
        let needsRun = migration.needsRun(at: phase, configuration: configuration, graph: graph, context: &mutableContext)

        if !isActive && !needsRun {
            currentMigrationIndex += 1
            runNextMigration(for: phase, configuration: configuration, graph: graph, context: context)
            return
        }

        if needsRun && phase == .preInit {
            activeMigrations.insert(migration.id)
        }

        // Always pass the context to handlePhase
        migration.handlePhase(phase, configuration: configuration, graph: graph, context: context) { result in
            switch result {
            case .done, .fallback:
                currentMigrationIndex += 1
                if currentMigrationIndex < migrations.count {
                    runNextMigration(for: phase, configuration: configuration, graph: graph, context: context)
                }
            case .error(let error):
                // Log error and stop further migrations
                print("GraphMigrationManager: Migration '\(migration.id)' failed with error: \(error)")
            }
        }
    }
}

// MARK: - Notifications
public extension Notification.Name {
    /// Notification posted when a migration phase changes.
    static let migrationPhaseDidChange = Notification.Name("GraphMigrationManager.migrationPhaseDidChange")
    
    
}

private extension GraphMigrationManager {
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
