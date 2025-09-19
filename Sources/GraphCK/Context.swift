/*
 * The MIT License (MIT)
 *
 * Copyright (C) 2019, CosmicMind, Inc. <http://cosmicmind.com>.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import CoreData
import CloudKit

// Unique author per device for filtering local writes in Persistent History
enum GraphDeviceAuthor {
  private static let key = "GraphCK.deviceAuthor"
  static func current() -> String {
    if let s = UserDefaults.standard.string(forKey: key) { return s }
    let s = UUID().uuidString
    UserDefaults.standard.set(s, forKey: key)
    return s
  }
}

internal struct GraphContextRegistry {
  static var dispatchToken = false
  static var added: [String: Bool]!
  static var managedObjectContexts: [String: NSManagedObjectContext]!
}

internal struct Context {
  /**
   Creates a NSManagedContext. The method will ensure that  any workerManagedObjectContexts that have
   a concurrency type of .MainQueueConcurrencyType are always created on the main
   thread.
   - Parameter concurrencyType: A concurrency type to use.
   - Parameter parentContext: An optional parent context.
   */
  static func create(_ concurrencyType: NSManagedObjectContextConcurrencyType, parentContext: NSManagedObjectContext? = nil) -> NSManagedObjectContext {
    var moc: NSManagedObjectContext!
    
    let makeContext = { [weak parentContext] in
      moc = NSManagedObjectContext(concurrencyType: concurrencyType)
      moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
      moc.undoManager = nil
      
      if let pmoc = parentContext {
        moc.parent = pmoc
      }
    }
    
    if concurrencyType == .mainQueueConcurrencyType && !Thread.isMainThread {
      DispatchQueue.main.sync {
        makeContext()
      }
    } else {
      makeContext()
    }
    
    return moc
  }
}

/// NSManagedObjectContext extension.
internal extension Graph {
  /// Prepares the registry.
  func prepareGraphContextRegistry() {
    guard false == GraphContextRegistry.dispatchToken else {
      return
    }
    
    GraphContextRegistry.dispatchToken = true
    GraphContextRegistry.added = [:]
    GraphContextRegistry.managedObjectContexts = [String: NSManagedObjectContext]()
  }
  
  /**
   Prapres the managedObjectContext.
   - Parameter locate: The location URL.
   */
  func prepareManagedObjectContext(locate: URL) {
    // Normalizza il percorso in base al tipo di input
    if locate.pathExtension == "sqlite" {
        // Se è già un file .sqlite, usalo direttamente
        location = locate
    } else {
        // Altrimenti, trattalo come directory e aggiungi Graph.sqlite
        location = locate.appendingPathComponent("Graph.sqlite")
    }

    // Final SQLite URL: use new API to get store URL
    let storeURL = location

    if type == NSInMemoryStoreType {
      // In-memory store configuration
      let storeDescription = NSPersistentStoreDescription()
      storeDescription.type = NSInMemoryStoreType

      let container = NSPersistentContainer(name: name, managedObjectModel: Model.create())
      container.persistentStoreDescriptions = [storeDescription]

      container.loadPersistentStores { [unowned self] (desc, error) in
        if let error = error {
          fatalError("[Graph Error] Failed to load in-memory store: \(error.localizedDescription)")
        }
        self.persistentContainer = nil
        self.managedObjectContext = container.viewContext
        // Mark per-device author for potential filtering in Persistent History
        self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
        self.managedObjectContext.name = "GraphCK.viewContext"
        self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.managedObjectContext.undoManager = nil
        self.managedObjectContext.automaticallyMergesChangesFromParent = true
        self.location = storeURL
        GraphContextRegistry.managedObjectContexts[self.route] = self.managedObjectContext
      }
      return
    }

    // Reuse cached context if present
    if let cached = GraphContextRegistry.managedObjectContexts[route] {
      managedObjectContext = cached
      return
    }

    // Ensure parent directory exists, not the .sqlite file itself
    let dirURL = storeURL.deletingLastPathComponent()
    File.createDirectoryAtPath(dirURL, withIntermediateDirectories: true, attributes: nil) { (success, error) in
        if let e = error {
            fatalError("[Graph Error: \(e.localizedDescription)]")
        }
    }

    // Store description with M2 options
    let storeDescription = NSPersistentStoreDescription(url: storeURL)
    storeDescription.type = NSSQLiteStoreType
    storeDescription.shouldAddStoreAsynchronously = false
    storeDescription.shouldMigrateStoreAutomatically = true
    storeDescription.shouldInferMappingModelAutomatically = true
    storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

    // Resolve CloudKit container identifier: runtime override > Info.plist fallback
    var resolvedContainerID: String? = Graph.cloudKitContainerIdentifier
    if resolvedContainerID == nil || resolvedContainerID?.isEmpty == true {
      resolvedContainerID = Bundle.main.object(forInfoDictionaryKey: "GraphCloudKitContainerIdentifier") as? String
    }
    if let containerID = resolvedContainerID, !containerID.isEmpty {
      storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
    }

    print("🛠 [GraphCK] Creating CloudKit container named: \(name)")

    // Create modern container
    let container = NSPersistentCloudKitContainer(name: name, managedObjectModel: Model.create())
    container.persistentStoreDescriptions = [storeDescription]

    print("📦 [GraphCK] Loading persistent store at: \(storeURL)")

    container.loadPersistentStores { [unowned self] (desc, error) in
      if let error = error {
        print("⚠️ [GraphCK] Failed to load CloudKit store. Error: \(error)")
        // Fallback: try a plain local NSPersistentContainer (no CloudKit) instead of crashing.
        let plain = NSPersistentContainer(name: name, managedObjectModel: Model.create())
        // Reuse the same storeDescription but ensure CloudKit options are cleared.
        let plainDesc = NSPersistentStoreDescription(url: storeURL)
        plainDesc.type = NSSQLiteStoreType
        plainDesc.shouldAddStoreAsynchronously = false
        plainDesc.shouldMigrateStoreAutomatically = true
        plainDesc.shouldInferMappingModelAutomatically = true
        plain.persistentStoreDescriptions = [plainDesc]
        
        plain.loadPersistentStores { [unowned self] (desc, plainError) in
          if let plainError = plainError {
            // Do not crash during tests: log both errors and leave MOC unset.
            debugPrint("[Graph Error] CloudKit container failed: \(error.localizedDescription); fallback also failed: \(plainError.localizedDescription)")
            return
          }
          // Success with plain container: proceed with local-only context.
          print("✅ [GraphCK] Fallback local store loaded successfully at: \(storeURL.lastPathComponent)")
          self.persistentContainer = nil
          self.managedObjectContext = plain.viewContext
          // Mark per-device author for potential filtering in Persistent History
          self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
          self.managedObjectContext.name = "GraphCK.viewContext"
          self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
          self.managedObjectContext.undoManager = nil
          self.managedObjectContext.automaticallyMergesChangesFromParent = true
          self.location = desc.url ?? storeURL
          GraphContextRegistry.managedObjectContexts[self.route] = self.managedObjectContext
        }
        return
      }
      self.persistentContainer = container
      self.managedObjectContext = container.viewContext
      // Mark per-device author for potential filtering in Persistent History
      self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
      self.managedObjectContext.name = "GraphCK.viewContext"
      self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
      self.managedObjectContext.undoManager = nil
      self.managedObjectContext.automaticallyMergesChangesFromParent = true
      self.location = desc.url ?? storeURL
      GraphContextRegistry.managedObjectContexts[self.route] = self.managedObjectContext
      print("✅ [GraphCK] CloudKit persistent container loaded successfully.")
      if GraphContextRegistry.added[self.route] != true {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handlePersistentStoreRemoteChange(_:)),
                                               name: .NSPersistentStoreRemoteChange,
                                               object: container.persistentStoreCoordinator)
        GraphContextRegistry.added[self.route] = true
        print("📡 [GraphCK] Registered for NSPersistentStoreRemoteChange notifications.")
      } else {
        print("📡 [GraphCK] Remote change observer already registered for route: \(self.route)")
      }
      // Prepare Persistent History bootstrap on launch (token restore / bootstrap-from-now).
      // This is safe to call multiple times; it will no-op if already initialized.
      self.ph_prepareOnLaunchAfterContainerReady()
    }
  }
  
  /// Prepares the SQLite file if needed.
  func prepareSQLite() {
    if NSSQLiteStoreType == type {
      // Append the fixed store filename (without GraphCK_ prefix)
      location = location.appendingPathComponent(GraphStoreDescription.storeFilename())
    }
  }
}

@available(iOS 10.0, OSX 10.12, *)
fileprivate extension Graph {
  // NOTE (M2): legacy helper, unused after migration to NSPersistentCloudKitContainer.
  func prepareContextContainer() {
    self.prepareSQLite()
    
    let storeDescription = NSPersistentStoreDescription()
    storeDescription.shouldAddStoreAsynchronously = false
    storeDescription.shouldMigrateStoreAutomatically = true //Added by bruno
    storeDescription.shouldInferMappingModelAutomatically = true //Addeed by bruno
    storeDescription.url = location
    
    let container = NSPersistentContainer(name: name, storeDescription: storeDescription)
    container.loadPersistentStores { [unowned self] (storeDescription, error) in
      self.managedObjectContext = container.viewContext
      GraphContextRegistry.managedObjectContexts[self.route] = self.managedObjectContext
    }
  }
}
