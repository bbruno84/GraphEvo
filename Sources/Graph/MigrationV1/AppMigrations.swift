//
//  AppMigrations.swift
//  MyHomeBill
//
//  Created by Valerio Buriani on 21/09/25.
//  Copyright © 2025 Marco Cavicchi. All rights reserved.
//


//
//  AppMigrations.swift
//  MyHomeBills
//
//  Created by Valerio Buriani on 21/09/25.
//

import Foundation
import Graph

enum AppMigrations {
    /// Registra tutte le migrazioni specifiche dell'app.
    static func registerAll() {
        GraphMigrationManager.registerMigrations([
            MigrationV1(),
            // 🔜 Aggiungi qui MigrationV2(), MigrationV3(), ecc.
        ])
    }
}
