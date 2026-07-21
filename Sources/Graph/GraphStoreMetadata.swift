//
//  GraphStoreMetadata.swift
//  Graph
//
//  Created by Valerio Buriani on 20/09/25.
//

import Foundation
import CoreData

public enum GraphStoreMetadata {
    // Chiavi nei metadata (proprietà list–safe).
    private static let graphModelVersionKey = "GraphModelVersion"
    private static let appDataVersionKey    = "AppDataVersion"

    /// Checks compatibility without opening or modifying the store.
    /// Applications can use this before running their own migration.
    public static func isCompatible(
        at storeURL: URL,
        with model: NSManagedObjectModel = Model.create()
    ) throws -> Bool {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// Legge le versioni correnti dai metadata dello store.
    /// - Parameter configuration: configurazione completa dello store.
    /// - Returns: GraphStoreConfiguration.Versions (nil = legacy/non presente)
    public static func read(from configuration: GraphStoreConfiguration, at: URL? = nil) throws -> GraphStoreConfiguration.Versions {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: at ?? configuration.resolvedStoreURL
        )
        let gm = metadata[graphModelVersionKey] as? Int
        let av = metadata[appDataVersionKey] as? Int
        return .init(graphModel: gm, appData: av)
    }
    

    /// Scrive le versioni nei metadata usando un PSC già aperto.
    /// Non modifica nulla in memoria; persiste solo su disco.
    public static func write(
        _ versions: GraphStoreConfiguration.Versions,
        using coordinator: NSPersistentStoreCoordinator,
        for store: NSPersistentStore
    ) throws {
        var md = coordinator.metadata(for: store)
        md[graphModelVersionKey] = versions.graphModel
        md[appDataVersionKey]    = versions.appData
        coordinator.setMetadata(md, for: store)
    }

    /// Comodo helper: apre temporaneamente lo store, scrive i metadata e chiude.
    public static func write(
        _ versions: GraphStoreConfiguration.Versions,
        to configuration: GraphStoreConfiguration,
        model: NSManagedObjectModel
    ) throws {
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try psc.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: configuration.resolvedStoreURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: false,
                NSInferMappingModelAutomaticallyOption: false
            ]
        )
        try write(versions, using: psc, for: store)
        try psc.remove(store)
    }

    /// Decide se “serve upgrade” confrontando le versioni.
    /// Regola: `nil` è legacy (= 0). Si migra se `current < required` per uno dei due.
    public static func needsUpgrade(current: GraphStoreConfiguration.Versions,
                                    required: GraphStoreConfiguration.Versions) -> Bool {
        let curGM = current.graphModel ?? 0
        let curAV = current.appData   ?? 0
        let reqGM = required.graphModel ?? 0
        let reqAV = required.appData   ?? 0
        return (curGM < reqGM) || (curAV < reqAV)
    }
}

// MARK: - Generic key/value metadata API

public extension GraphStoreMetadata {
    /// Legge un valore PropertyList-safe opzionale dai metadata dello store.
    /// - Parameters:
    ///   - key: chiave del valore da leggere
    ///   - configuration: configurazione completa dello store
    ///   - at: URL opzionale dello store (default: configuration.resolvedStoreURL)
    /// - Returns: valore opzionale di tipo T (PropertyList-safe), nil se assente o errore
    static func readValue<T>(forKey key: String, from configuration: GraphStoreConfiguration, at: URL? = nil) -> T? {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: at ?? configuration.resolvedStoreURL
            )
            return metadata[key] as? T
        } catch {
            return nil
        }
    }

    /// Scrive o rimuove un valore PropertyList-safe nei metadata dello store.
    /// - Parameters:
    ///   - value: valore opzionale da scrivere; se nil, la chiave viene rimossa
    ///   - key: chiave del valore da scrivere
    ///   - configuration: configurazione completa dello store
    ///   - model: modello Core Data usato per aprire temporaneamente lo store
    /// - Throws: errori di I/O o Core Data
    static func writeValue<T>(_ value: T?, forKey key: String, to configuration: GraphStoreConfiguration, model: NSManagedObjectModel) throws {
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try psc.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: configuration.resolvedStoreURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: false,
                NSInferMappingModelAutomaticallyOption: false
            ]
        )
        var metadata = psc.metadata(for: store)
        if let value = value {
            metadata[key] = value
        } else {
            metadata.removeValue(forKey: key)
        }
        psc.setMetadata(metadata, for: store)
        try psc.remove(store)
    }

    /// Helper per leggere flag booleani dai metadata dello store.
    /// Ritorna false se assente o in caso di errore.
    /// - Parameters:
    ///   - key: chiave del flag booleano
    ///   - configuration: configurazione completa dello store
    /// - Returns: valore booleano (false se assente o errore)
    static func boolValue(forKey key: String, from configuration: GraphStoreConfiguration) -> Bool {
        (readValue(forKey: key, from: configuration) as Bool?) ?? false
    }

    /// Rimuove una chiave dai metadata dello store aprendo temporaneamente lo store.
    /// - Parameters:
    ///   - key: chiave da rimuovere
    ///   - configuration: configurazione completa dello store
    ///   - model: modello Core Data usato per aprire temporaneamente lo store
    /// - Throws: errori di I/O o Core Data
    static func removeValue(forKey key: String, to configuration: GraphStoreConfiguration, model: NSManagedObjectModel) throws {
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try psc.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: configuration.resolvedStoreURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: false,
                NSInferMappingModelAutomaticallyOption: false
            ]
        )
        var metadata = psc.metadata(for: store)
        metadata.removeValue(forKey: key)
        psc.setMetadata(metadata, for: store)
        try psc.remove(store)
    }

    /// Restituisce tutte le chiavi presenti nei metadata dello store.
    /// - Parameters:
    ///   - configuration: configurazione completa dello store
    ///   - at: URL opzionale dello store (default: configuration.resolvedStoreURL)
    /// - Returns: array di stringhe con tutte le chiavi presenti nei metadata
    static func listAllKeys(from configuration: GraphStoreConfiguration, at: URL? = nil) -> [String] {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: at ?? configuration.resolvedStoreURL
            )
            return Array(metadata.keys)
        } catch {
            return []
        }
    }
}
