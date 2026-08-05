//
//  GraphStoreContainerFactory.swift
//  GraphEvo
//
//  Creates the local and CloudKit persistent containers used by Graph.
//

import CoreData
import CloudKit

internal enum GraphStoreContainerFactory {
    static func makeLocal(
        name: String,
        storeURL: URL,
        configuration: GraphStoreConfiguration
    ) -> NSPersistentContainer {
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.type = NSSQLiteStoreType
        storeDescription.shouldAddStoreAsynchronously = false
        storeDescription.shouldMigrateStoreAutomatically = false
        storeDescription.shouldInferMappingModelAutomatically = false
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        let container = NSPersistentContainer(name: name, managedObjectModel: Model.create())
        container.persistentStoreDescriptions = [storeDescription]
        return container
    }

    static func makeCloud(
        name: String,
        storeURL: URL,
        configuration: GraphStoreConfiguration
    ) -> NSPersistentCloudKitContainer {
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.type = NSSQLiteStoreType
        storeDescription.shouldAddStoreAsynchronously = false
        storeDescription.shouldMigrateStoreAutomatically = false
        storeDescription.shouldInferMappingModelAutomatically = false
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if let containerID = configuration.cloudKitContainerIdentifier {
            storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        }

        let container = NSPersistentCloudKitContainer(name: name, managedObjectModel: Model.create())
        container.persistentStoreDescriptions = [storeDescription]
        return container
    }
}
