//
//  GraphStoreMetadata.swift
//  GraphCK
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
    /// - Returns: GraphStoreDescription.Versions (nil = legacy/non presente)
    public static func read(from storeURL: URL) throws -> GraphStoreDescription.Versions {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        let gm = metadata[graphModelVersionKey] as? Int
        let av = metadata[appDataVersionKey] as? Int
        return .init(graphModel: gm, appData: av)
    }

    /// Scrive le versioni nei metadata usando un PSC già aperto.
    /// Non modifica nulla in memoria; persiste solo su disco.
    public static func write(
        _ versions: GraphStoreDescription.Versions,
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
        _ versions: GraphStoreDescription.Versions,
        to storeURL: URL,
        model: NSManagedObjectModel
    ) throws {
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try psc.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
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
    public static func needsUpgrade(current: GraphStoreDescription.Versions,
                                    required: GraphStoreDescription.Versions) -> Bool {
        let curGM = current.graphModel ?? 0
        let curAV = current.appData   ?? 0
        let reqGM = required.graphModel ?? 0
        let reqAV = required.appData   ?? 0
        return (curGM < reqGM) || (curAV < reqAV)
    }
}
