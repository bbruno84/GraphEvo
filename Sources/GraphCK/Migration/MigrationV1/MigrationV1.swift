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


/// Esegue la prima migrazione ufficiale (legacy -> modello attuale).
public struct MigrationV1: GraphMigration {
    
    public var id: String { "MigrationV1" }
    
    public func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, storeURL: URL, graph: Graph?) -> Bool {
        switch phase {
        case .preInit:
            do {
                // 0. Esiste un file
                let fm = FileManager.default
                guard fm.fileExists(atPath: storeURL.path) else { return false }
                
                // 1. Compatibilità Core Data
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType,
                    at: storeURL
                )
                let isCompatible = Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
                
                // 2. Versioni GraphCK / App
                let currentVersions = try GraphStoreMetadata.read(from: storeURL)
                let requiredVersions = GraphStoreDescription.requiredVersions
                let needsUpgrade = GraphStoreMetadata.needsUpgrade(current: currentVersions,
                                                                   required: requiredVersions)
                
                if !isCompatible || needsUpgrade {
                    print("[MigrationV1] Migrazione necessaria: compatibilità=\(!isCompatible), upgrade=\(needsUpgrade)")
                    return true
                }
                return false
            } catch {
                // Se non riusciamo a leggere i metadata → assumiamo che serva migrazione
                print("[MigrationV1] Errore nel leggere metadata, assumo che la migrazione sia necessaria: \(error)")
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
                Self.applyAppDataVersion(graph: graph)
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
    
    public func handleRemoteChanges(
        storeURL: URL,
        graph: Graph?,
        inserted: [NSManagedObjectID],
        updated: [NSManagedObjectID]
    ) {
        

        guard let _graph = graph else {return}

        guard let context = _graph.newBackgroundContext() else {return}

        context.perform {
            let idsToCheck = inserted + updated
            guard !idsToCheck.isEmpty else {return}

            let requiredVersion = GraphStoreDescription.requiredVersions.appData
            var updatedCount = 0

            for objectID in idsToCheck {
                do {
                    let object = try context.existingObject(with: objectID)
                    let currentVersion = object.value(forKey: "appDataVersion") as? Int

                    if let cv = currentVersion, let requiredVersion {
                        if cv < requiredVersion {
                            object.setValue(requiredVersion, forKey: "appDataVersion")
                            updatedCount += 1
                            
                        }
                    } else {
                        // nil → legacy, forza scrittura
                        object.setValue(requiredVersion, forKey: "appDataVersion")
                        updatedCount += 1
                    }
                } catch {
                    print("[MigrationV1] ❌ Failed to fetch object \(objectID): \(error)")
                }
            }

            if context.hasChanges {
                do {
                    try context.save()
                    
                    if let main = graph?.managedObjectContext {
                        main.perform {
                            main.mergeChanges(fromContextDidSave: Notification(name: .NSManagedObjectContextDidSave, object: context))
                        }
                    }
                } catch {
                    print("[MigrationV1] ❌ Failed to save context after updating appDataVersion: \(error)")
                }
            } else {
                print("[MigrationV1] ℹ️ Context has no changes")
            }
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

        // Aggiorna i metadata dello store con le versioni richieste
        do {
            try GraphStoreMetadata.write(
                GraphStoreDescription.requiredVersions,
                to: storeURL,
                model: Model.create()
            )
            print("📝 [MigrationV1] Metadata aggiornati: \(GraphStoreDescription.requiredVersions)")
        } catch {
            print("⚠️ [MigrationV1] Impossibile aggiornare i metadata: \(error)")
        }
        
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
        
        
        for entityName in propertyEntities {
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
            fetchRequest.predicate = NSPredicate(format: "object != nil")
            
            let results = try context.fetch(fetchRequest)
            
            Self.migrateProperties(results, in: context)
            
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
    
    private static func migrateProperties(_ objects: [NSManagedObject], in context: NSManagedObjectContext) {
        var legacyTypeCounts: [String: Int] = [:]

        for object in objects {
            guard let rawObject = object.value(forKey: "object") else { continue }

            do {
                if let rawData = rawObject as? Data {
                    // Try PDF first
                    if let pdf = PDFDocument(data: rawData), let pdfData = pdf.dataRepresentation() {
                        let encoded = try GraphArchiver.archive(pdfData)
                        reassignSafely(encoded, to: object)
                        legacyTypeCounts["PDFDocument(rawData)", default: 0] += 1
                    } else {
                        // Generic Data → enforce nested-Data policy
                        let encoded = try GraphArchiver.archive(rawData)
                        reassignSafely(encoded, to: object)
                        legacyTypeCounts["__NSCFData", default: 0] += 1
                    }
                } else if let image = rawObject as? UIImage, let data = image.pngData() {
                    let encoded = try GraphArchiver.archive(data)
                    reassignSafely(encoded, to: object)
                    legacyTypeCounts["UIImage", default: 0] += 1
                } else {
                    let encoded = try GraphArchiver.archive(rawObject)
                    reassignSafely(encoded, to: object)
                    let typeName = String(describing: type(of: rawObject))
                    legacyTypeCounts[typeName, default: 0] += 1
                }
            } catch {
                // On failure, assign a safe placeholder instead of nil
                if let placeholder = try? GraphArchiver.archive("MIGRATION_FAILED") {
                    reassignSafely(placeholder, to: object)
                    print("❌ MigrationV1: failed to archive \(type(of: rawObject)), stored placeholder")
                } else {
                    print("❌ MigrationV1: failed to archive \(type(of: rawObject)) and no placeholder could be stored")
                }
            }

            // 🔧 Update appDataVersion if attribute exists, forcing the write
            if object.entity.attributesByName.keys.contains("appDataVersion") {
                let requiredVersion = GraphStoreDescription.requiredVersions.appData
                object.willChangeValue(forKey: "appDataVersion")
                object.setPrimitiveValue(requiredVersion, forKey: "appDataVersion")
                object.didChangeValue(forKey: "appDataVersion")
            }
        }

        if context.hasChanges {
            do { try context.save() }
            catch { print("❌ MigrationV1: failed to save context: \(error)") }
        }

        if !legacyTypeCounts.isEmpty {
            print("📊 Tipi migrati: \(legacyTypeCounts)")
        }
    }
    
    private static func reassignSafely(_ value: Any?, to property: NSManagedObject) {
        // Force a change even if the new value is isEqual: to the old one
        property.willChangeValue(forKey: "object")
        property.setPrimitiveValue(value, forKey: "object")
        property.didChangeValue(forKey: "object")
    }
    
    internal static func applyAppDataVersion(graph: Graph) {
        guard let context = graph.managedObjectContext else {
            print("[MigrationV1] ⚠️ No managedObjectContext available, skipping appDataVersion update")
            return
        }
        context.performAndWait {
            let propertyEntities = [
                "ManagedEntityProperty",
                "ManagedActionProperty",
                "ManagedRelationshipProperty"
            ]
            for entityName in propertyEntities {
                let fetch = NSFetchRequest<NSManagedObject>(entityName: entityName)
                do {
                    let results = try context.fetch(fetch)
                    for object in results {
                        object.setValue(GraphStoreDescription.requiredVersions.appData, forKey: "appDataVersion")
                    }
                } catch {
                    print("[MigrationV1] ⚠️ Failed to update appDataVersion for \(entityName): \(error)")
                }
            }
            if context.hasChanges {
                do {
                    try context.save()
                    print("📝 [MigrationV1] appDataVersion applied to properties")
                } catch {
                    print("[MigrationV1] ❌ Failed to save appDataVersion changes: \(error)")
                }
            }
        }
    }
    
}
