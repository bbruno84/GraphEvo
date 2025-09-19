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

extension Notification.Name {
    /// Custom remote-change notification used by tests to avoid clashing with the real CloudKit one.
    static let GraphCKSimulatedRemoteChange = Notification.Name("GraphCK.SimulatedRemoteChange")
}

@objc(GraphDelegate)
public protocol GraphDelegate {
  /**
   A delegation method that is executed when a graph instance
   will prepare cloud storage.
   - Parameter graph: A Graph instance.
   - Parameter transition: A GraphCloudStorageTransition value.
   */
  @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
  @objc
  optional func graphWillPrepareCloudStorage(graph: Graph, transition: GraphCloudStorageTransition)
  
  /**
   A delegation method that is executed when a graph instance
   did prepare cloud storage.
   - Parameter graph: A Graph instance.
   */
  @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
  @objc
  optional func graphDidPrepareCloudStorage(graph: Graph)
  
  /**
   A delegation method that is executed when a graph instance
   will update from cloud storage.
   - Parameter graph: A Graph instance.
   */
  @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
  @objc
  optional func graphWillUpdateFromCloudStorage(graph: Graph)
  
  /**
   A delegation method that is executed when a graph instance
   did update from cloud storage.
   - Parameter graph: A Graph instance.
   */
  @available(*, deprecated, message: "iCloud Ubiquitous Store is no longer supported.")
  @objc
  optional func graphDidUpdateFromCloudStorage(graph: Graph)
}

public enum GraphCloudStatus {
    case available
    case unavailable
}

public protocol GraphCloudStatusDelegate: AnyObject {
    /// Called when iCloud availability changes (or is first determined).
    func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus)
}

@objc(Graph)
public class Graph: NSObject {
  /// Graph location.
  internal var location: URL
    
  public var locationPublic : URL { return location}
  
  /// Graph route.
  public internal(set) var route: String
  
  /// Graph name.
  public internal(set) var name: String
    
  /// Graph User.
  public internal(set) var appIdentifier: String?
    
  /// Graph should be rebuilded from cloud data
  public internal(set) var rebuildFromCloud: Bool?
  
  /// Graph type.
  public internal(set) var type: String
  
  /// Worker managedObjectContext.
  public internal(set) var managedObjectContext: NSManagedObjectContext!
  
  /// Number of items to return.
  public var batchSize = 0 // 0 == no limit
  
  /// Start the return results from this offset.
  public var batchOffset = 0
  
  /// Watch instances.
  public internal(set) lazy var watchers : [Watcher] = []
  
  /// Optional delegate to receive iCloud availability updates (informational).
  public weak var cloudStatusDelegate: GraphCloudStatusDelegate? {
      didSet {
          if let status = lastCloudStatus, let delegate = cloudStatusDelegate {
              delegate.graph(self, iCloudStatusChanged: status)
          }
      }
  }

  /// M2: cache last known iCloud availability to notify late-bound delegates.
  private var lastCloudStatus: GraphCloudStatus?
  
  public weak var delegate: GraphDelegate?

    /// M2: Optional override for the CloudKit container identifier.
    /// If set, this takes precedence over Info.plist and enables CloudKit sync without relying on plist UX.
    public static var cloudKitContainerIdentifier: String?

    /// M2: Keep a reference to the CloudKit container so we can spawn background contexts, etc.
    internal var persistentContainer: NSPersistentCloudKitContainer?
  
  /**
   A reference to the graph completion handler.
   - Parameter success: A boolean indicating if the cloud connection
   is possible or not.
   */
  internal var completion: ((Bool, Error?) -> Void)?
  
  /// Deinitializer that removes the Graph from NSNotificationCenter.
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  
  /**
   Initializer to named Graph with optional type and location.
   - Parameter name: A name for the Graph.
   - Parameter backend: Graph store backend.
   executed to determine if iCloud support is available or not.
   */
    public init(name: String? = nil, backend: GraphStoreDescription.GraphStoreBackend = .sqlite) {
        GraphValueTransformer.register()
        self.name = name ?? GraphStoreDescription.name
        self.type = backend.coreDataType
        self.location = GraphStoreDescription.location
        route = "Local/\(self.name)"
        GraphMigrationManager.handlePhase(.preInit, graph: nil)
        super.init()
        GraphMigrationManager.handlePhase(.postInit, graph: self)
        observeRemoteStoreChanges()
        checkICloudAccountStatus()
        prepareGraphContextRegistry()
        prepareManagedObjectContext(locate: location)
        GraphMigrationManager.handlePhase(.ready, graph: self)
    }
    
    public init(name: String? = nil, locate: GraphStoreDescription.locations, backend: GraphStoreDescription.GraphStoreBackend = .sqlite) {
        GraphValueTransformer.register()
        self.name = name ?? GraphStoreDescription.name
        self.type = backend.coreDataType
        self.location = GraphStoreDescription.setLocation(locate)
        route = "Local/\(self.name)"
        GraphMigrationManager.handlePhase(.preInit, graph: nil)
        super.init()
        GraphMigrationManager.handlePhase(.postInit, graph: self)
        observeRemoteStoreChanges()
        checkICloudAccountStatus()
        prepareGraphContextRegistry()
        prepareManagedObjectContext(locate: location)
        GraphMigrationManager.handlePhase(.ready, graph: self)
    }
  
    public init(storeURL: URL, backend: GraphStoreDescription.GraphStoreBackend = .sqlite) {
        GraphValueTransformer.register()

        if storeURL.pathExtension == "sqlite" {
            // Caso: viene passato direttamente il file .sqlite
            self.name = storeURL.deletingPathExtension().lastPathComponent
            self.location = storeURL.deletingLastPathComponent()
        } else {
            // Caso: viene passata una directory -> ci aspettiamo Graph.sqlite dentro
            self.name = storeURL.lastPathComponent
            self.location = storeURL
        }

        self.type = backend.coreDataType
        self.route = "" // non usiamo più route per evitare percorsi doppi

        GraphMigrationManager.handlePhase(.preInit, storeURL: storeURL, graph: nil)
        super.init()
        GraphMigrationManager.handlePhase(.postInit, graph: self)
        observeRemoteStoreChanges()
        checkICloudAccountStatus()
        prepareGraphContextRegistry()
        prepareManagedObjectContext(locate: location)
        GraphMigrationManager.handlePhase(.ready, graph: self)
    }
      
  /**
   Initializer to named Graph with optional type and location.
   - Parameter cloud: A name for the Graph.
   - Parameter type: Graph type.
   - Parameter location: A location for storage.
   - Parameter completion: An Optional completion block that is
   executed to determine if iCloud support is available or not.
   */
    @available(*, deprecated, message: "Deprecated: uses modern CloudKit container (private DB) under the hood; falls back to local if iCloud is unavailable.")
    public convenience init(cloud name: String, appIdentifier: GraphStoreDescription.graphCloudIdentifiers?, rebuild: Bool? = false, completion: ((Bool, Error?) -> Void)? = nil) {
        self.init(name: name, backend: .sqlite)
        self.appIdentifier = appIdentifier?.rawValue
        self.rebuildFromCloud = rebuild
        self.completion = completion
    }

    @available(*, deprecated, message: "Deprecated: uses modern CloudKit container (private DB) under the hood; falls back to local if iCloud is unavailable.")
    public convenience init(cloud name: String, appIdentifier: GraphStoreDescription.graphCloudIdentifiers?, rebuild: Bool? = false, locate: GraphStoreDescription.locations, completion: ((Bool, Error?) -> Void)? = nil) {
        self.init(name: name, locate: locate, backend: .sqlite)
        self.appIdentifier = appIdentifier?.rawValue
        self.rebuildFromCloud = rebuild
        self.completion = completion
    }
  
    // MARK: - Context factory (modern API)
    /// Returns a new background context backed by the same NSPersistentCloudKitContainer.
    /// Returns nil if the container is not yet initialized.
    public func newBackgroundContext() -> NSManagedObjectContext? {
        guard let container = persistentContainer else { return nil }
        let bg = container.newBackgroundContext()
        // Ensure history filtering can identify this device's writes
        bg.transactionAuthor = GraphDeviceAuthor.current()
        // Prefer incoming server values to win on conflict
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return bg
    }
  
    // MARK: - CloudKit / Remote change hooks (M2)
  
    /// Observe only the custom test channel here (the real remote observer lives in Graph+PersistentHistory).
    private func observeRemoteStoreChanges() {
        #if canImport(CoreData)
        let nc = NotificationCenter.default
        // Test channel: watchers already know how to consume this payload.
        nc.addObserver(self,
                       selector: #selector(handleRemoteStoreChange(_:)),
                       name: .GraphCKSimulatedRemoteChange,
                       object: nil)
        #endif
    }
  
    @objc
    private func handleRemoteStoreChange(_ notification: Notification) {
        // Only merge; Watchers observe and dispatch separately.
        guard notification.name == .GraphCKSimulatedRemoteChange else { return }
        guard let moc = managedObjectContext else { return }
        moc.perform { [weak moc] in
            guard let moc = moc else { return }
            moc.mergeChanges(fromContextDidSave: notification)
        }
    }
  
    /// Check iCloud account status and notify the optional cloudStatusDelegate.
    private func checkICloudAccountStatus() {
        // If we're under unit tests, avoid touching CloudKit and synchronously report unavailable.
        if NSClassFromString("XCTestCase") != nil {
            self.lastCloudStatus = .unavailable
            if let delegate = self.cloudStatusDelegate {
                delegate.graph(self, iCloudStatusChanged: .unavailable)
            }
            return
        }
  
        // Resolve a container identifier: runtime override first, then optional Info.plist fallback.
        var resolvedID: String? = Graph.cloudKitContainerIdentifier
        if resolvedID == nil || resolvedID?.isEmpty == true {
            resolvedID = Bundle.main.object(forInfoDictionaryKey: "GraphCloudKitContainerIdentifier") as? String
        }
  
        // If no identifier is configured (SPM / no capabilities), don't touch CloudKit APIs.
        guard let containerID = resolvedID, !containerID.isEmpty else {
            self.lastCloudStatus = .unavailable
            if let delegate = self.cloudStatusDelegate {
                delegate.graph(self, iCloudStatusChanged: .unavailable)
            }
            return
        }
  
        // Use the explicitly resolved container to query account status.
        CKContainer(identifier: containerID).accountStatus { [weak self] status, _ in
            guard let self = self else { return }
            let mapped: GraphCloudStatus = (status == .available) ? .available : .unavailable
            self.lastCloudStatus = mapped
            DispatchQueue.main.async {
                self.cloudStatusDelegate?.graph(self, iCloudStatusChanged: mapped)
            }
        }
    }
}
