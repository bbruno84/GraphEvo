//
//  ExportDB.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation

extension GraphTools {
    /// Copies an SQLite file (and optional WAL/SHM files) to a temporary simulator directory.
    @discardableResult
    static func exportMigratedDB(to folderName: String = "ExportedDB", sqliteURL: URL) -> URL? {
        let fileManager = FileManager.default
        
        // Temporary simulator directory.
        let tempDir = fileManager.temporaryDirectory
        let exportDir = tempDir.appendingPathComponent(folderName, isDirectory: true)
        
        do {
            // Create the directory when it does not exist.
            if !fileManager.fileExists(atPath: exportDir.path) {
                try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            
            // Copy the SQLite, WAL, and SHM files.
            let baseName = sqliteURL.deletingPathExtension().lastPathComponent
            let extensions = ["sqlite", "sqlite-wal", "sqlite-shm"]
            
            for ext in extensions {
                let source = sqliteURL.deletingPathExtension().appendingPathExtension(ext)
                if fileManager.fileExists(atPath: source.path) {
                    let dest = exportDir.appendingPathComponent("\(baseName).\(ext)")
                    // Remove an existing destination.
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
            print("❌ Export error: \(error)")
            return nil
        }
    }
}
