//
//  GraphMigrations.swift
//  GraphCK
//
//  Created by Valerio Buriani on 15/09/25.
//

import Foundation

/// Central registry of all official graph migrations.
/// Keeps GraphMigrationManager.swift clean and focused on orchestration.
public enum GraphMigrations {
    
    /// Register all known migrations in the correct order.
    public static func registerAll() {
        GraphMigrationManager.registerMigration(MigrationV1())
        // 🔜 Future migrations go here, in order:
        // GraphMigrationManager.registerMigration(MigrationV2.self)
        // GraphMigrationManager.registerMigration(MigrationV3.self)
    }
}
