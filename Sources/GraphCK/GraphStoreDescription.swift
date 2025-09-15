//
//  GraphStoreDescription.swift
//  GraphCK
//
//  Created by Valerio Buriani on 15/09/25.
//
import CoreData
import Foundation

public struct GraphStoreDescription {
  /// Datastore name.
  static let name: String = "default"
  
  /// Graph type.
  static let type: String = NSSQLiteStoreType
  
  /// URL reference to where the Graph datastore will live.
  static var location: URL = File.path(.applicationSupportDirectory, path: "CosmicMind/Graph/")!

  /// Centralized App Group identifier shortcut.
  static let appGroupIdentifier: String? = "group.MyHomeBills"

  /// Resolved App Group location with safe fallback to default location if not available.
  static var appGroupLocation: URL {
      if let id = appGroupIdentifier,
         let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
          return base.appendingPathComponent("CosmicMind/Graph/")
      }
      return location
  }
    
  public enum locations {
      case standard
      case appGroup
  }
    
  public enum graphCloudIdentifiers : String {
      case old
      case application
      case todayExtension
      case widgetExtension
  }

  static func setLocation(_ locating: GraphStoreDescription.locations)->URL {
      switch locating {
      case .standard:
          return location
      case .appGroup:
          return appGroupLocation
      }
  }
    
  /// Returns the fixed filename used for all stores: Graph.sqlite
  static func storeFilename() -> String {
      return "Graph.sqlite"
  }

  /// Returns the full URL for the store inside the given base directory.
  static func storeURL(baseURL: URL) -> URL {
      return baseURL.appendingPathComponent(storeFilename())
  }
    
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
}
