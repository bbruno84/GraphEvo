//
//  GraphStoreConfiguration.swift
//  Graph
//
//  Created by Valerio Buriani on 21/09/25.
//

import Foundation
import CoreData

/// Configuration object for a Graph store.
/// Encapsulates all options for backend, location, versioning and CloudKit.
public struct GraphStoreConfiguration {
    public var name: String
    public var backend: GraphStoreBackend
    public var location: URL
    public var appGroupIdentifier: String?
    public var cloudKitContainerIdentifier: String?
    public var requiredGraphModelVersion: Int
    public var requiredAppDataVersion: Int

    public init(
        name: String = "default",
        backend: GraphStoreBackend = .sqlite,
        location: URL = File.path(.applicationSupportDirectory, path: "CosmicMind/Graph/")!,
        appGroupIdentifier: String? = nil,
        cloudKitContainerIdentifier: String? = nil,
        requiredGraphModelVersion: Int = 1,
        requiredAppDataVersion: Int = 1
    ) {
        self.name = name
        self.backend = backend
        self.location = location
        self.appGroupIdentifier = appGroupIdentifier
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.requiredGraphModelVersion = requiredGraphModelVersion
        self.requiredAppDataVersion = requiredAppDataVersion
    }

    // MARK: - Computed resolution

    /// Path effettivo risolto, considerando AppGroup se presente.
    public var resolvedLocation: URL {
        if let id = appGroupIdentifier,
           let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return base.appendingPathComponent("CosmicMind/Graph/")
        }
        return location
    }

    /// Nome file dello store.
    public var storeFilename: String { "Graph.sqlite" }

    /// URL finale dello store (dir + filename).
    public var storeURL: URL {
        resolvedLocation.appendingPathComponent(storeFilename)
    }

    /// Route (Local vs Cloud).
    public var route: String {
        cloudKitContainerIdentifier == nil ? "Local/\(name)" : "Cloud/\(name)"
    }

    /// Convenience versions wrapper.
    public var requiredVersions: Versions {
        Versions(graphModel: requiredGraphModelVersion, appData: requiredAppDataVersion)
    }

    public struct Versions: Equatable {
        public var graphModel: Int?
        public var appData: Int?
    }
}

/// Backend types supported by Graph.
public enum GraphStoreBackend {
    case sqlite
    case inMemory

    var coreDataType: String {
        switch self {
        case .sqlite: return NSSQLiteStoreType
        case .inMemory: return NSInMemoryStoreType
        }
    }
}