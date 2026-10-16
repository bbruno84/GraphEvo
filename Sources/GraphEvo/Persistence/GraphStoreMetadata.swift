//
//  GraphStoreMetadata.swift
//  Graph
//
//  Created by Valerio Buriani on 20/09/25.
//

import Foundation
import CoreData

public enum GraphStoreMetadata {
    // Metadata keys (property-list safe).
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

    /// Reads the current versions from store metadata.
    /// - Parameter configuration: complete store configuration.
    /// - Returns: GraphStoreConfiguration.Versions (nil = legacy or missing).
    public static func read(from configuration: GraphStoreConfiguration, at: URL? = nil) throws -> GraphStoreConfiguration.Versions {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: at ?? configuration.resolvedStoreURL
        )
        let gm = metadata[graphModelVersionKey] as? Int
        let av = metadata[appDataVersionKey] as? Int
        return .init(graphModel: gm, appData: av)
    }
    

    /// Writes versions to metadata using an already-open PSC.
    /// Does not change in-memory state; persists only to disk.
    public static func write(
        _ versions: GraphStoreConfiguration.Versions,
        using coordinator: NSPersistentStoreCoordinator,
        for store: NSPersistentStore
    ) throws {
        var md = coordinator.metadata(for: store)
        if let graphModel = versions.graphModel {
            md[graphModelVersionKey] = graphModel
        } else {
            md.removeValue(forKey: graphModelVersionKey)
        }
        if let appData = versions.appData {
            md[appDataVersionKey] = appData
        } else {
            md.removeValue(forKey: appDataVersionKey)
        }
        coordinator.setMetadata(md, for: store)
        try NSPersistentStoreCoordinator.setMetadata(
            md,
            forPersistentStoreOfType: store.type,
            at: try storeURL(for: store),
            options: nil
        )
    }

    /// Convenience helper: temporarily opens the store, writes metadata, and closes it.
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
    /// Rule: `nil` is legacy (= 0). Upgrade when `current < required` for either version.
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
    /// Reads an optional PropertyList-safe value from store metadata.
    /// - Parameters:
    ///   - key: key of the value to read.
    ///   - configuration: complete store configuration.
    ///   - at: optional store URL (default: configuration.resolvedStoreURL).
    /// - Returns: An optional PropertyList-safe value of type T, nil when missing or on error.
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

    /// Writes or removes a PropertyList-safe value in store metadata.
    /// - Parameters:
    ///   - value: optional value to write; when nil, the key is removed.
    ///   - key: key of the value to write.
    ///   - configuration: complete store configuration.
    ///   - model: Core Data model used to temporarily open the store.
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
        try NSPersistentStoreCoordinator.setMetadata(
            metadata,
            forPersistentStoreOfType: store.type,
            at: try storeURL(for: store),
            options: nil
        )
        try psc.remove(store)
    }

    /// Helper for reading Boolean flags from store metadata.
    /// Returns false when missing or on error.
    /// - Parameters:
    ///   - key: key of the Boolean flag.
    ///   - configuration: complete store configuration.
    /// - Returns: A Boolean value (false when missing or on error).
    static func boolValue(forKey key: String, from configuration: GraphStoreConfiguration) -> Bool {
        (readValue(forKey: key, from: configuration) as Bool?) ?? false
    }

    /// Removes a key from store metadata by temporarily opening the store.
    /// - Parameters:
    ///   - key: key to remove.
    ///   - configuration: complete store configuration.
    ///   - model: Core Data model used to temporarily open the store.
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
        try NSPersistentStoreCoordinator.setMetadata(
            metadata,
            forPersistentStoreOfType: store.type,
            at: try storeURL(for: store),
            options: nil
        )
        try psc.remove(store)
    }

    /// Restituisce tutte le chiavi presenti nei metadata dello store.
    /// - Parameters:
    ///   - configuration: complete store configuration.
    ///   - at: optional store URL (default: configuration.resolvedStoreURL).
    /// - Returns: Array of strings containing all metadata keys.
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

private func storeURL(for store: NSPersistentStore) throws -> URL {
    guard let url = store.url else {
        throw CocoaError(.fileNoSuchFile)
    }
    return url
}
