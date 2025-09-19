//
//  MigrationV1.swift
//  GraphCK
//
//  Created by Valerio Buriani on 11/09/25.
//

import Foundation
import CoreData
import UIKit
import PDFKit

/// Helper KVO per NSMigrationManager.migrationProgress con log leggibili (solo API pubbliche)
final class MigrationV1ProgressObserver: NSObject {
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "migrationProgress",
              let mgr = object as? NSMigrationManager else { return }
        
        let pct = Int((mgr.migrationProgress * 100.0).rounded())
        let steps: [NSEntityMapping] = mgr.mappingModel.entityMappings ?? []
        let total = steps.count
        let idx: Int = {
            guard total > 0 else { return 0 }
            let approx = Int(floor(Double(mgr.migrationProgress) * Double(total)))
            return max(0, min(approx, max(total - 1, 0)))
        }()
        let current = (0..<total).contains(idx) ? steps[idx] : nil
        let name   = current?.name ?? "idle"
        let src    = current?.sourceEntityName ?? "nil"
        let dst    = current?.destinationEntityName ?? "nil"
        let policy = current?.entityMigrationPolicyClassName ?? "none"
        
        // Log version hashes if available
        var hashesStr = ""
        if let current = current {
            if let srcHash = current.sourceEntityVersionHash {
                hashesStr += " | srcHash: \(srcHash.map { String(format: "%02x", $0) }.joined())"
            }
            if let dstHash = current.destinationEntityVersionHash {
                hashesStr += " | dstHash: \(dstHash.map { String(format: "%02x", $0) }.joined())"
            }
        }
        
        debugPrint("[MigrationV1][Progress] \(pct)% | step \(min(idx, max(total-1, 0)))/\(total) | \(name) (\(src) → \(dst)) | policy: \(policy)\(hashesStr)")
    }
}

/// Esegue la prima migrazione ufficiale (legacy -> modello attuale).
public struct MigrationV1: GraphMigration {
    
    public var id: String { "MigrationV1" }
    
    public func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, storeURL: URL, graph: Graph?) -> Bool {
        switch phase {
        case .preInit:
            do {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType,
                    at: storeURL
                )
                // If compatible, no migration needed
                let isNeeded = !Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
                if isNeeded {
                    print("[MigrationV1] Model is incompatible, migration needed")
                }
                return isNeeded
            } catch {
                // Error loading metadata, assume migration needed
                print("[MigrationV1] unable to load metadata, assuming migration needed")
                return true
            }
        default:
            return false
        }
    }
    
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
                
                GraphValueTransformer.register()
                
                Self.mergeBaselineIfPresent(storeURL: storeURL, localGraph: graph, completion: completion)
            } else {
                completion(.done)
            }
        case .ready:
            
            GraphValueTransformer.register()
            
        default:
            completion(.done)
        }
    }
    
    internal static func execute(
        storeURL: URL
    ) throws -> Bool {
        print("📦 Avvio migrazione in-place sullo store: \(storeURL.lastPathComponent)")
        
        // Backup condizionale
        try preflightBackup(storeURL: storeURL)
        
        //Registra il transformer temporaneo per la migrazione
        LegacyCompatibleTransformer.registerTemporarilyForMigration()
        
        //Migra gli oggetti codificati con il transformer temporaneo compatibile con il definitivo
        try migrateLegacyObjectFieldInPlace(at: storeURL)
        
        //Registra il transformer definitivo
        GraphValueTransformer.register()
        
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

extension MigrationV1 {
    
    static func migrateLegacyObjectField(in context: NSManagedObjectContext) throws {
        
        let propertyEntities = [
            "ManagedEntityProperty",
            "ManagedActionProperty",
            "ManagedRelationshipProperty"
        ]
        
        var nilCount = 0
        
        var legacyTypeCounts: [String: Int] = [:]
        
        for entityName in propertyEntities {
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
            fetchRequest.predicate = NSPredicate(format: "object != nil")
            
            let results = try context.fetch(fetchRequest)
            
            for object in results {
                guard let rawObject = object.value(forKey: "object") else {
                    print("⚠️ Campo object nil, saltato")
                    nilCount += 1
                    continue
                }
                
                if let data = rawObject as? Data {
                    do {
                        // 🔎 Verifica se è un PDF in formato raw data (PDFDocument archived as Data)
                        if let pdf = PDFDocument(data: data), let pdfData = pdf.dataRepresentation() {
                            let encoded = try GraphArchiver.archive(pdfData)
                            reassignSafely(encoded, to: object)
                            legacyTypeCounts["PDFDocument(rawData)", default: 0] += 1
                            continue
                        }
                    } catch {
                        print("❌ Errore nel decoding dell'oggetto legacy: \(error)")
                    }
                } else {
                    // È un oggetto semplice: Double, String, Date, ecc.
                    do {
                        if let image = rawObject as? UIImage, let data = image.pngData() {
                            let encoded = try GraphArchiver.archive(data)
                            reassignSafely(encoded, to: object)
                        } else {
                            let encoded = try GraphArchiver.archive(rawObject)
                            reassignSafely(encoded, to: object)
                        }
                        
                        let typeName = String(describing: type(of: rawObject))
                        legacyTypeCounts[typeName, default: 0] += 1
                        
                    } catch {
                        let typeName = String(describing: type(of: rawObject))
                        print("❌ Trasformazione fallita per oggetto \(typeName): \(error)")
                        
                        if rawObject is UIImage {
                            // 🔁 Usa immagine di fallback
                            if let fallback = UIImage(systemName: "questionmark.square"),
                               let fallbackData = fallback.pngData() {
                                do {
                                    let encoded = try GraphArchiver.archive(fallbackData)
                                    reassignSafely(encoded, to: object)
                                    print("🛟 Immagine di fallback salvata per tipo \(typeName)")
                                } catch {
                                    print("❌ Fallita archiviazione dell'immagine di fallback: \(error)")
                                }
                            }
                        }
                    }
                }
            }
            // Dopo il ciclo degli oggetti, stampa il riepilogo dei tipi legacy
        }
        
        print("📊 Tipi legacy trovati:")
        for (type, count) in legacyTypeCounts.sorted(by: { $0.value > $1.value }) {
            print("   • \(type): \(count)")
        }

        if context.hasChanges {
            try context.save()
            print("💾 Migrazione completata e salvata")
        } else {
            print("ℹ️ Nessuna modifica rilevata, nessun salvataggio eseguito")
        }
    }
    
    static func migrateLegacyObjectFieldInPlace(at storeURL: URL) throws {
        
        // 1. Costruisci il modello finale
        let legacyModel = MigrationV1LegacyModel.create()
        
        // 2. Costruisci il coordinator
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        print("✅ Store caricato: \(store)")
        
        // 3. Esegui la migrazione
        try context.performAndWait {
            try migrateLegacyObjectField(in: context)
        }
        
        // 4. Cleanup
        try coordinator.remove(coordinator.persistentStores.first!)
        context.reset()
        print("✅ Migrazione legacy completata e store disconnesso.")
    }
    
    private static func reassignSafely(_ value: Any, to property: NSManagedObject) {
        property.setValue(value, forKey: "object")
    }
    
}



