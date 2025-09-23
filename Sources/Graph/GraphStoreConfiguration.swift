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
    public var name: String = "default"
    public var backend: GraphStoreBackend = .sqlite
    public var location: URL = File.path(.applicationSupportDirectory, path: "CosmicMind/Graph/")!
    public var appGroupIdentifier: String? = nil
    public var cloudKitContainerIdentifier: String? = nil
    public var requiredGraphModelVersion: Int = 1
    public var requiredAppDataVersion: Int = 1

    /// Public default initializer so this type can be used in default argument values.
    public init() {}

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

    /// Route (Local vs Cloud) determinata dalla presenza del container CloudKit.
    public var route: String {
        cloudKitContainerIdentifier == nil ? "Local/\(name)" : "Cloud/\(name)"
    }

    /// Convenience versions wrapper.
    public var requiredVersions: Versions {
        Versions(graphModel: requiredGraphModelVersion, appData: requiredAppDataVersion)
    }

    /// Resolved store URL that handles if location points directly to a file or a directory.
    public var resolvedStoreURL: URL {
        if location.pathExtension == "sqlite" {
            // Already a full sqlite file path
            return location
        } else {
            return resolvedLocation.appendingPathComponent(route).appendingPathComponent(storeFilename)
        }
    }

    public struct Versions: Equatable {
        public var graphModel: Int?
        public var appData: Int?
        public init(graphModel: Int?, appData: Int?) {
            self.graphModel = graphModel
            self.appData = appData
        }
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
