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

    /// Legge le versioni correnti dai metadata dello store.
    /// - Parameter configuration: configurazione completa dello store.
    /// - Returns: GraphStoreConfiguration.Versions (nil = legacy/non presente)
    public static func read(from configuration: GraphStoreConfiguration, at: URL? = nil) throws -> GraphStoreConfiguration.Versions {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: at ?? configuration.storeURL
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
            at: configuration.storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
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
