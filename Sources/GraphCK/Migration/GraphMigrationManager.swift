//
//  GraphMigrationManager.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

/// A protocol for defining custom graph migrations.
public enum GraphMigrationResult {
    case done
    case error(Error)
    case fallback
}

public protocol GraphMigration {
    var id: String { get }
    func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, storeURL: URL, graph: Graph?, completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, storeURL: URL, graph: Graph?) -> Bool
}

/// Manages the migrations of the Graph store.
/// This becomes the official system for all future migrations.
public final class GraphMigrationManager {
    
    private static let initialized: Void = {
        GraphMigrations.registerAll()
    }()
    
    public enum GraphLifecyclePhase {
        case preInit
        case postInit
        case postMigration
        case ready
    }
    
    /// Stores lifecycle phase callbacks. The callback receives the store URL and an optional Graph context.
    /// Some phases may not provide a Graph instance.
    private static var callbacks: [GraphLifecyclePhase: [(URL, Graph?) -> Void]] = [:]

    /// Stores all registered migrations in order.
    private static var migrations: [GraphMigration] = []
    /// Tracks the current migration index for sequential execution.
    private static var currentMigrationIndex: Int = 0
    
    /// Registers a callback to be executed during a given lifecycle phase.
    /// The callback receives the store URL and an optional Graph context. Some phases may not provide a Graph instance.
    public static func registerCallback(for phase: GraphLifecyclePhase, _ callback: @escaping (URL, Graph?) -> Void) {
        _ = initialized
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
    
    /// Executes all callbacks and registered migrations for the specified lifecycle phase, running migrations in sequence.
    /// - Parameters:
    ///   - phase: The lifecycle phase being handled.
    ///   - storeURL: The Core Data store URL this phase refers to.
    ///   - graph: Optional Graph instance (may be nil in early phases).
    public static func handlePhase(_ phase: GraphLifecyclePhase, storeURL: URL, graph: Graph?) {
        _ = initialized
        // Fire callbacks
        callbacks[phase]?.forEach { $0(storeURL, graph) }
        // Reset migration index for every phase
        currentMigrationIndex = 0
        runNextMigration(for: phase, storeURL: storeURL, graph: graph)
    }

    /// Runs the next migration in sequence for the given phase.
    private static func runNextMigration(for phase: GraphLifecyclePhase, storeURL: URL, graph: Graph?) {
        guard currentMigrationIndex < migrations.count else { return }
        let migration = migrations[currentMigrationIndex]
        if !migration.needsRun(at: phase, storeURL: storeURL, graph: graph) {
            currentMigrationIndex += 1
            runNextMigration(for: phase, storeURL: storeURL, graph: graph)
            return
        }
        migration.handlePhase(phase, storeURL: storeURL, graph: graph) { result in
            switch result {
            case .done, .fallback:
                currentMigrationIndex += 1
                if currentMigrationIndex < migrations.count {
                    runNextMigration(for: phase, storeURL: storeURL, graph: graph)
                }
            case .error(let error):
                // Log error and stop further migrations
                print("GraphMigrationManager: Migration '\(migration.id)' failed with error: \(error)")
            }
        }
    }
    
    /// Convenience overload: derives the store URL if only a Graph (or none) is available.
    public static func handlePhase(_ phase: GraphLifecyclePhase, graph: Graph?) {
        _ = initialized
        let resolvedURL: URL
        if let g = graph {
            resolvedURL = GraphStoreDescription.storeURL(baseURL: g.locationPublic)
        } else {
            resolvedURL = GraphStoreDescription.storeURL(baseURL: GraphStoreDescription.location)
        }
        handlePhase(phase, storeURL: resolvedURL, graph: graph)
    }
}
