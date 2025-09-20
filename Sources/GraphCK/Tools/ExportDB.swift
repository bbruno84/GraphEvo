//
//  ExportDB.swift
//  GraphCK
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation

extension GraphTools {
    /// Copia un file SQLite (con eventuali WAL/SHM) in una cartella temporanea del simulatore
    @discardableResult
    static func exportMigratedDB(to folderName: String = "ExportedDB", sqliteURL: URL) -> URL? {
        let fileManager = FileManager.default
        
        // Cartella temporanea nel simulatore
        let tempDir = fileManager.temporaryDirectory
        let exportDir = tempDir.appendingPathComponent(folderName, isDirectory: true)
        
        do {
            // Crea cartella se non esiste
            if !fileManager.fileExists(atPath: exportDir.path) {
                try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            
            // Copia i file SQLite, WAL e SHM
            let baseName = sqliteURL.deletingPathExtension().lastPathComponent
            let extensions = ["sqlite", "sqlite-wal", "sqlite-shm"]
            
            for ext in extensions {
                let source = sqliteURL.deletingPathExtension().appendingPathExtension(ext)
                if fileManager.fileExists(atPath: source.path) {
                    let dest = exportDir.appendingPathComponent("\(baseName).\(ext)")
                    // Rimuovi se già presente
                    if fileManager.fileExists(atPath: dest.path) {
                        try fileManager.removeItem(at: dest)
                    }
                    try fileManager.copyItem(at: source, to: dest)
                    print("✅ Copiato \(source.lastPathComponent) → \(dest.path)")
                }
            }
            
            print("📂 DB esportato in: \(exportDir.path)")
            return exportDir
            
        } catch {
            print("❌ Errore durante l’esportazione: \(error)")
            return nil
        }
    }
}
