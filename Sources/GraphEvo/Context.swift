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
    _ = GraphContextRegistry.shared
  }
  
  /**
   Prepares the managedObjectContext.
   - Parameter configuration: The store configuration.
   */
  func prepareManagedObjectContext(configuration: GraphStoreConfiguration) {
    let storeURL = configuration.resolvedStoreURL
    let storeKey = configuration.storeIdentityKey
    let storeExistedBeforeOpen = FileManager.default.fileExists(atPath: storeURL.path)
    runtimeStoreURL = storeURL

    if type == NSSQLiteStoreType,
       storeExistedBeforeOpen {
      do {
        guard try GraphStoreMetadata.isCompatible(at: storeURL) else {
          failStoreOpening(.incompatibleStore(storeURL))
          return
        }
      } catch {
        failStoreOpening(.unreadableStore(storeURL, underlying: error))
        return
      }
    }

        if type == NSInMemoryStoreType {
      // In-memory store configuration
      let storeDescription = NSPersistentStoreDescription()
      storeDescription.type = NSInMemoryStoreType

      let container = NSPersistentContainer(name: name, managedObjectModel: Model.create())
      container.persistentStoreDescriptions = [storeDescription]

      container.loadPersistentStores { [unowned self] (desc, error) in
        if let error = error {
          self.failStoreOpening(.failedToLoadStore(storeURL, underlying: error))
          return
        }
        self.persistentContainer = container
        self.managedObjectContext = container.viewContext
        // Mark per-device author for potential filtering in Persistent History
        self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
        self.managedObjectContext.name = "GraphEvo.viewContext"
        self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.managedObjectContext.undoManager = nil
        self.managedObjectContext.automaticallyMergesChangesFromParent = true
        self.runtimeStoreURL = storeURL
        self.emit(.stateChanged(.persistenceMode(.local)))
        self.contextRegistryKey = storeKey
        GraphContextRegistry.shared.register(
          graph: self,
          key: storeKey,
          context: self.managedObjectContext,
          container: container,
          configuration: configuration
        )
        self.storeDidOpenSuccessfully()
      }
      return
    }

    // Reuse cached context if present
        if let cached = GraphContextRegistry.shared.context(for: storeKey) {
      managedObjectContext = cached
      contextRegistryKey = storeKey
      persistentContainer = GraphContextRegistry.shared.container(for: storeKey)
      GraphContextRegistry.shared.register(
        graph: self,
        key: storeKey,
        context: cached,
        container: persistentContainer,
        configuration: configuration
      )
            if persistentContainer != nil {
                installRemoteObserverIfNeeded()
            }
            emit(.stateChanged(.persistenceMode(
                persistentContainer is NSPersistentCloudKitContainer ? .cloud : .local
            )))
            storeDidOpenSuccessfully()
      return
    }

    // Ensure parent directory exists, not the .sqlite file itself
    let dirURL = storeURL.deletingLastPathComponent()
    var directoryCreationError: Error?
    File.createDirectoryAtPath(dirURL, withIntermediateDirectories: true, attributes: nil) { (success, error) in
      directoryCreationError = error
    }
    if let directoryCreationError {
      failStoreOpening(.failedToLoadStore(storeURL, underlying: directoryCreationError))
      return
    }

    if configuration.cloudKitContainerIdentifier != nil && !Graph.isRunningUnderTests {
      let container = GraphStoreContainerFactory.makeCloud(name: name, storeURL: storeURL, configuration: configuration)

        container.loadPersistentStores { [unowned self] (desc, error) in
          if let error = error {
          emit(.warning(.cloudStoreFallback(underlying: error)))
          // Fallback: try a plain local NSPersistentContainer (no CloudKit) instead of crashing.
          let plain = GraphStoreContainerFactory.makeLocal(name: name, storeURL: storeURL, configuration: configuration)
          
          plain.loadPersistentStores { [unowned self] (desc, plainError) in
            if let plainError = plainError {
              debugPrint("[Graph Error] CloudKit container failed: \(error.localizedDescription); fallback also failed: \(plainError.localizedDescription)")
              self.failStoreOpening(.failedToLoadStore(storeURL, underlying: plainError))
              return
            }
            // Success with plain container: proceed with local-only context.
            emit(.stateChanged(.persistenceMode(.localFallback)))
            self.persistentContainer = plain
            self.managedObjectContext = plain.viewContext
            // Mark per-device author for potential filtering in Persistent History
            self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
            self.managedObjectContext.name = "GraphEvo.viewContext"
            self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            self.managedObjectContext.undoManager = nil
            self.managedObjectContext.automaticallyMergesChangesFromParent = true
            self.runtimeStoreURL = desc.url ?? storeURL
            self.contextRegistryKey = storeKey
            GraphContextRegistry.shared.register(
              graph: self,
              key: storeKey,
              context: self.managedObjectContext,
              container: plain,
              configuration: configuration
            )
            self.installRemoteObserverIfNeeded()

            if let store = plain.persistentStoreCoordinator.persistentStores.first {
                do {
                    let current = try GraphStoreMetadata.read(from: configuration, at: runtimeStoreURL)
                    if !storeExistedBeforeOpen && (current.graphModel == nil || current.appData == nil) {
                        try GraphStoreMetadata.write(configuration.requiredVersions,
                                                     using: plain.persistentStoreCoordinator,
                                                     for: store)
                    }
                } catch {
                    emit(.warning(.metadataPersistence(underlying: error)))
                }
            }
            self.storeDidOpenSuccessfully()
          }
          return
        }
        self.persistentContainer = container
        self.managedObjectContext = container.viewContext
        // Mark per-device author for potential filtering in Persistent History
        self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
        self.managedObjectContext.name = "GraphEvo.viewContext"
        self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.managedObjectContext.undoManager = nil
        self.managedObjectContext.automaticallyMergesChangesFromParent = true
        self.runtimeStoreURL = desc.url ?? storeURL
        self.contextRegistryKey = storeKey
        GraphContextRegistry.shared.register(
          graph: self,
          key: storeKey,
          context: self.managedObjectContext,
          container: container,
          configuration: configuration
        )
        self.emit(.stateChanged(.persistenceMode(.cloud)))

        if let store = container.persistentStoreCoordinator.persistentStores.first {
            do {
                let current = try GraphStoreMetadata.read(from: configuration, at: runtimeStoreURL)
                if !storeExistedBeforeOpen && (current.graphModel == nil || current.appData == nil) {
                    try GraphStoreMetadata.write(configuration.requiredVersions,
                                                 using: container.persistentStoreCoordinator,
                                                 for: store)
                    print("📝 [GraphEvo] Metadata inizializzati con versioni correnti \(configuration.requiredVersions)")
                }
            } catch {
                self.emit(.warning(.metadataPersistence(underlying: error)))
            }
        }
        self.installRemoteObserverIfNeeded()
        // Prepare Persistent History bootstrap on launch (token restore / bootstrap-from-now).
        // This is safe to call multiple times; it will no-op if already initialized.
        self.ph_prepareOnLaunchAfterContainerReady()
        self.storeDidOpenSuccessfully()
      }
    } else {
      let container = GraphStoreContainerFactory.makeLocal(name: name, storeURL: storeURL, configuration: configuration)

      container.loadPersistentStores { [unowned self] (desc, error) in
        if let error = error {
          self.failStoreOpening(.failedToLoadStore(storeURL, underlying: error))
          return
        }
        self.persistentContainer = container
        self.managedObjectContext = container.viewContext
        // Mark per-device author for potential filtering in Persistent History
        self.managedObjectContext.transactionAuthor = GraphDeviceAuthor.current()
        self.managedObjectContext.name = "GraphEvo.viewContext"
        self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.managedObjectContext.undoManager = nil
        self.managedObjectContext.automaticallyMergesChangesFromParent = true
        self.runtimeStoreURL = desc.url ?? storeURL
        self.contextRegistryKey = storeKey
        GraphContextRegistry.shared.register(
          graph: self,
          key: storeKey,
          context: self.managedObjectContext,
          container: container,
          configuration: configuration
        )
        self.emit(.stateChanged(.persistenceMode(.local)))

        if let store = container.persistentStoreCoordinator.persistentStores.first {
            do {
                let current = try GraphStoreMetadata.read(from: configuration, at: runtimeStoreURL)
                if !storeExistedBeforeOpen && (current.graphModel == nil || current.appData == nil) {
                    try GraphStoreMetadata.write(configuration.requiredVersions,
                                                 using: container.persistentStoreCoordinator,
                                                 for: store)
                    print("📝 [GraphEvo] Metadata inizializzati con versioni correnti \(configuration.requiredVersions)")
                }
            } catch {
                self.emit(.warning(.metadataPersistence(underlying: error)))
            }
        }
        self.storeDidOpenSuccessfully()
      }
    }
  }

  /// Installs at most one remote-history observer for the store.
  func installRemoteObserverIfNeeded() {
    guard let container = persistentContainer,
          container is NSPersistentCloudKitContainer,
          configuration.cloudKitContainerIdentifier != nil,
          !Graph.isRunningUnderTests,
          let key = contextRegistryKey,
          GraphContextRegistry.shared.claimObserver(graph: self, key: key) else { return }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePersistentStoreRemoteChange(_:)),
      name: .NSPersistentStoreRemoteChange,
      object: container.persistentStoreCoordinator
    )
  }

  /// Records an opening failure without moving, replacing or recreating the
  /// existing store. The application can inspect the error and migrate the
  /// exact `runtimeStoreURL` itself before trying again.
  private func failStoreOpening(_ error: GraphStoreOpeningError) {
    storeOpeningError = error
    managedObjectContext = nil
    persistentContainer = nil
    readiness = .failed(error)
    let completions = readinessCompletions
    readinessCompletions.removeAll()
    completions.forEach { $0(.failure(error)) }
    emit(.error(.storeOpening(error)))
    emit(.stateChanged(.readiness(.failed(error))))
    print("⚠️ [GraphEvo] Store opening refused: \(error.localizedDescription)")
  }

  /// Completes store setup and, when enabled, the migration lifecycle before
  /// releasing the public readiness callbacks.
  func storeDidOpenSuccessfully() {
    guard case .initializing = readiness else { return }

    guard migrationEnabled else {
      completeReadiness()
      return
    }

    GraphMigrationManager.handlePhase(
      .postInit,
      configuration: configuration,
      graph: self
    ) { [weak self] in
      guard let self else { return }
      GraphMigrationManager.handlePhase(
        .ready,
        configuration: self.configuration,
        graph: self
      ) { [weak self] in
        self?.completeReadiness()
      }
    }
  }

  private func completeReadiness() {
    guard case .initializing = readiness else { return }
    readiness = .ready
    emit(.stateChanged(.readiness(.ready)))
    let completions = readinessCompletions
    readinessCompletions.removeAll()
    completions.forEach { $0(.success(self)) }
  }
  
  /// Prepares the SQLite file if needed.
  func prepareSQLite() {
    if NSSQLiteStoreType == type {
      runtimeStoreURL = runtimeStoreURL ?? configuration.resolvedStoreURL
    }
  }
}
/*
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
*/
