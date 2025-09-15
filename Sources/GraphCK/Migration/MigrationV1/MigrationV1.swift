//
//  MigrationV1.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData

/// Esegue la prima migrazione ufficiale (legacy -> modello attuale).
public struct MigrationV1: GraphMigration {
    public var id: String { "MigrationV1" }
    
    public func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, storeURL: URL, graph: Graph?, completion: @escaping (GraphMigrationResult) -> Void) {
        switch phase {
        case .preInit:
            do {
                _ = try Self.execute(storeURL: storeURL)
                completion(.done)
            } catch {
                print("[MigrationV1] preInit error: \(error)")
                completion(.error(error))
            }
        case .postInit:
            if let graph = graph {
                Self.mergeBaselineIfPresent(storeURL: storeURL, localGraph: graph, completion: completion)
            } else {
                completion(.done)
            }
        default:
            completion(.done)
        }
    }
    
    internal static func execute(
        storeURL: URL
    ) throws -> Bool {
        
        // Metadata check
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL
            )
            if Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                print("[MigrationV1] Store già compatibile, nessuna migrazione necessaria.")
                return false
            }
        } catch {
            print("[MigrationV1] Errore nel recuperare i metadata: \(error). Procedo con la migrazione.")
            return true
        }
        
        // Backup condizionale
        try preflightBackup(storeURL: storeURL)
        
        // Migration should proceed automatically after this point
        return true
    }
}

// MARK: - Helpers

internal extension MigrationV1 {
    
    /// Restituisce l'URL di backup con `.legacyV1` inserito prima dell'estensione, all'interno della cartella di backup.
    static func makeLegacyV1BackupURL(for originalURL: URL, in backupFolderURL: URL) -> URL {
        let filenameWithoutExtension = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension
        let newFilename = "\(filenameWithoutExtension).legacyV1" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        return backupFolderURL.appendingPathComponent(newFilename)
    }
    
    /// Copia un file in backup se esiste nella cartella di backup, con log.
    static func backupFileIfExists(_ fileURL: URL, to backupFolderURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            let backupURL = makeLegacyV1BackupURL(for: fileURL, in: backupFolderURL)
            try fm.copyItem(at: fileURL, to: backupURL)
            print("[MigrationV1] Backup creato: \(backupURL)")
        }
    }
    
    /// Copia store legacy come backup in una sottocartella MigrationV1, includendo baseline.zip se presente.
    static func backupStoreFiles(at url: URL) throws {
        let fm = FileManager.default

        let storeDirectory = url.deletingLastPathComponent()
        let backupFolderURL = storeDirectory.appendingPathComponent("migrationV1", isDirectory: true)
        if !fm.fileExists(atPath: backupFolderURL.path) {
            try fm.createDirectory(at: backupFolderURL, withIntermediateDirectories: true, attributes: nil)
        }

        try backupFileIfExists(url, to: backupFolderURL)

        let basePath = url.path
        try backupFileIfExists(URL(fileURLWithPath: basePath + "-wal"), to: backupFolderURL)
        try backupFileIfExists(URL(fileURLWithPath: basePath + "-shm"), to: backupFolderURL)

        let baselineZipURL = storeDirectory.appendingPathComponent("baseline.zip")
        try backupFileIfExists(baselineZipURL, to: backupFolderURL)
    }
    
    /// Effettua un backup condizionale prima della migrazione.
    static func preflightBackup(storeURL: URL) throws {
        let userDefaults = migrationUserDefaults()
        let backupKey = "MigrationV1BackedUp"
        
        if userDefaults.bool(forKey: backupKey) {
            print("[MigrationV1] Backup già effettuato in precedenza, salto il backup.")
            return
        }
        
        var isCompatible = false
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL
            )
            isCompatible = Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        } catch {
            print("[MigrationV1] Errore nel recuperare i metadata: \(error). Procedo con il backup senza controllo compatibilità.")
            // Proceed to backup regardless of error
        }
        
        if isCompatible {
            print("[MigrationV1] Store già compatibile, backup non necessario.")
            return
        }
        
        try backupStoreFiles(at: storeURL)
        userDefaults.set(true, forKey: backupKey)
        print("[MigrationV1] Backup completato e flag impostato in UserDefaults.")
    }
    
    private static func migrationUserDefaults() -> UserDefaults {
        if let suite = UserDefaults(suiteName: GraphStoreDescription.appGroupIdentifier) {
            return suite
        }
        return .standard
    }
}
