//
//  MigrationV1+BaselineZip.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

// MARK: - Baseline Zip Helpers

extension MigrationV1 {
    
    /// Cerca un baseline.zip nel container ubiquity.
    /// - Parameters:
    ///   - storeURL: URL dello store sqlite.
    ///   - containerID: Identificatore del container ubiquity (o nil per default).
    ///   - maxRetries: Numero massimo di tentativi.
    ///   - delay: Primo delay (in secondi) tra i tentativi.
    ///   - completion: Callback con URL trovato o nil.
    static func findBaselineZip(
        storeURL: URL,
        containerID: String?,
        maxRetries: Int = 5,
        delay: TimeInterval = 2.0,
        completion: @escaping (URL?) -> Void
    ) {
        func attempt(retriesLeft: Int, delay: TimeInterval) {
            let fm = FileManager.default
            if let containerURL = fm.url(forUbiquityContainerIdentifier: containerID) {
                // Estrarre store name: cartella sopra il file sqlite (es: .../Local/MyStore/Graph.sqlite -> MyStore)
                let storeName = storeURL.deletingLastPathComponent().lastPathComponent
                // Costruisci path root baseline
                let baselineRoot = containerURL
                    .appendingPathComponent("CoreData", isDirectory: true)
                    .appendingPathComponent(storeName, isDirectory: true)
                    .appendingPathComponent(".baseline", isDirectory: true)
                    .appendingPathComponent(storeName, isDirectory: true)
                
                // Cerca baseline.zip nelle sottocartelle
                if let enumerator = fm.enumerator(
                    at: baselineRoot,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.lastPathComponent == "baseline.zip" {
                            completion(fileURL)
                            return
                        }
                    }
                }
                
                // Fallback: cerca baseline.zip più recente ovunque nel container
                var latestZip: URL?
                var latestDate: Date?
                if let allEnum = fm.enumerator(
                    at: containerURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let fileURL as URL in allEnum {
                        if fileURL.lastPathComponent == "baseline.zip" {
                            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                               let modDate = attrs.contentModificationDate {
                                if latestDate == nil || modDate > latestDate! {
                                    latestDate = modDate
                                    latestZip = fileURL
                                }
                            } else if latestZip == nil {
                                latestZip = fileURL
                            }
                        }
                    }
                }
                if let found = latestZip {
                    completion(found)
                } else {
                    print("[MigrationV1] baseline.zip non trovato nel container ubiquity.")
                    completion(nil)
                }
            } else if retriesLeft > 0 {
                print("[MigrationV1] Ubiquity container non ancora disponibile, riprovo tra \(delay) secondi... (\(retriesLeft) tentativi rimasti)")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    attempt(retriesLeft: retriesLeft - 1, delay: delay * 2)
                }
            } else {
                print("[MigrationV1] Impossibile accedere al container ubiquity dopo vari tentativi.")
                completion(nil)
            }
        }
        attempt(retriesLeft: maxRetries, delay: delay)
    }
    
    /// Copia un baseline.zip trovato nell’ubiquity in una sottocartella migrationV1.
    /// - Parameters:
    ///   - baselineURL: URL del baseline.zip trovato.
    ///   - storeDirectory: Directory dello store locale (usata per collocare la sottocartella migrationV1).
    static func backupBaselineZip(_ baselineURL: URL, storeDirectory: URL) throws {
        let fm = FileManager.default
        let backupFolderURL = storeDirectory.appendingPathComponent("migrationV1", isDirectory: true)
        
        if !fm.fileExists(atPath: backupFolderURL.path) {
            try fm.createDirectory(at: backupFolderURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Local backup (unchanged)
        let destURLLocal = backupFolderURL
            .appendingPathComponent(baselineURL.deletingPathExtension().lastPathComponent + ".v1legacy")
            .appendingPathExtension(baselineURL.pathExtension)
        try backupFileIfExists(baselineURL, to: destURLLocal.deletingLastPathComponent())
        
        // Ubiquity backup: copy directly from baselineURL to ubiquity container path
        if let containerURL = fm.url(forUbiquityContainerIdentifier: nil) {
            let storeName = storeDirectory.lastPathComponent
            let ubiquityBackupFolder = containerURL
                .appendingPathComponent("CoreData", isDirectory: true)
                .appendingPathComponent(storeName, isDirectory: true)
                .appendingPathComponent(".baseline", isDirectory: true)
                .appendingPathComponent(storeName, isDirectory: true)
                .appendingPathComponent("migrationV1", isDirectory: true)
            
            if !fm.fileExists(atPath: ubiquityBackupFolder.path) {
                try fm.createDirectory(at: ubiquityBackupFolder, withIntermediateDirectories: true, attributes: nil)
            }
            
            let destURLUbiquity = ubiquityBackupFolder
                .appendingPathComponent("baseline.v1legacy")
                .appendingPathExtension("zip")
            
            // Check if .v1legacy.zip already exists at destination, skip copying if yes
            if fm.fileExists(atPath: destURLUbiquity.path) {
                // Skip copying to avoid overwriting
                return
            }
            
            // Copy directly from baselineURL (ubiquity file) to the destination in ubiquity container
            // The processing will later download the file locally as needed.
            try fm.copyItem(at: baselineURL, to: destURLUbiquity)
        }
    }

    /// Migrates the baseline store at the given URL using MigrationV1LegacyModel as source and Model as destination.
    /// - Parameter baselineURL: URL of the baseline store to migrate.
    /// - Returns: URL of the migrated temporary store.
    /// - Throws: Propagates errors from migration process.
    static func migrateBaseline(baselineURL: URL) throws -> URL {
        print("[MigrationV1] Starting migration of baseline at \(baselineURL.path)")

        let fm = FileManager.default
        let tempDir = baselineURL.deletingLastPathComponent()
        let tempStoreURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")

        let sourceModel = MigrationV1LegacyModel.create()
        let destinationModel = Model.create()
        let mappingModel = MigrationV1MappingModel.create()

        let migrationManager = NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)

        do {
            try migrationManager.migrateStore(
                from: baselineURL,
                sourceType: NSSQLiteStoreType,
                options: nil,
                with: mappingModel,
                toDestinationURL: tempStoreURL,
                destinationType: NSSQLiteStoreType,
                destinationOptions: nil
            )
            print("[MigrationV1] Migration successful. Migrated store at \(tempStoreURL.path)")
            return tempStoreURL
        } catch {
            print("[MigrationV1] Migration failed with error: \(error)")
            throw error
        }
    }
}

// MARK: - Baseline Merge Step

extension MigrationV1 {
    /// Checks for a baseline.zip related to the given store, backs it up if found, and prepares it for migration.
    /// - Parameters:
    ///   - storeURL: The URL of the local Core Data store.
    ///   - localGraph: The local Graph instance to use.
    ///   - completion: Completion callback with GraphMigrationResult.
    internal static func mergeBaselineIfPresent(storeURL: URL, localGraph: Graph, completion: @escaping (GraphMigrationResult) -> Void) {
        let ubiquitousStore = NSUbiquitousKeyValueStore.default
        if ubiquitousStore.bool(forKey: "MigrationV1BaselineProcessed") {
            print("[MigrationV1] Baseline migration already processed according to ubiquitous key-value store. Skipping merge.")
            completion(.done)
            return
        }
        // Step 1: Try to find a baseline.zip in the ubiquity container for this store.
        findBaselineZip(storeURL: storeURL, containerID: nil) { baselineURL in
            guard let baselineURL = baselineURL else {
                print("[MigrationV1] No baseline.zip found for store at \(storeURL.path).")
                completion(.done)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Step 2: Backup the found baseline.zip to migrationV1 folder (both locally and in ubiquity).
                    let storeDirectory = storeURL.deletingLastPathComponent()
                    try backupBaselineZip(baselineURL, storeDirectory: storeDirectory)
                    // Step 3: Log that the baseline has been backed up and is ready for migration.
                    print("[MigrationV1] baseline.zip backed up and ready for migration at \(baselineURL.path).")
                    // Step 4: Migrate the baseline and get the migrated store URL.
                    let migratedBaselineURL = try migrateBaseline(baselineURL: baselineURL)
                    print("[MigrationV1] Migrated baseline store available at \(migratedBaselineURL.path)")
                    
                    // Step 5: Open Graph instances for local and baseline stores, count entities, create discriminator, and deduplicate.
                    do {
                        let baselineGraph = Graph(storeURL: migratedBaselineURL, backend: .inMemory)
                        
                        let localCount = Search<Entity>(graph: localGraph).where(.type("*")).sync().count
                        let baselineCount = Search<Entity>(graph: baselineGraph).where(.type("*")).sync().count
                        
                        let discriminator = BaselineDedupDiscriminator(
                            localEntityCount: localCount,
                            baselineEntityCount: baselineCount,
                            originOf: { entity in
                                if entity.managedNode.managedObjectContext == localGraph.managedObjectContext {
                                    return .local
                                } else {
                                    return .baseline
                                }
                            }
                        )
                        
                        try DedupTool.deduplicateBetween(
                            primaryGraph: localGraph,
                            secondaryGraph: baselineGraph,
                            discriminator: discriminator
                        )
                        print("[MigrationV1] Deduplication completed. Primary: local store, Secondary: baseline store at \(migratedBaselineURL.lastPathComponent).")
                        // Set flag in ubiquitous key-value store
                        ubiquitousStore.set(true, forKey: "MigrationV1BaselineProcessed")
                        ubiquitousStore.synchronize()
                        completion(.done)
                    } catch {
                        print("[MigrationV1] Error during deduplication process: \(error)")
                        completion(.error(error))
                    }
                    
                } catch {
                    print("[MigrationV1] Error while backing up or migrating baseline.zip: \(error)")
                    completion(.error(error))
                }
            }
        }
    }
}
