import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Facade-owned initialization; the runtime transaction owns the single save.
package struct GraphCoordinatorAdapter: Sendable {
    package let initializePolicy: (@Sendable (NSManagedObjectContext, GraphID, GraphConflictPolicy) throws -> Void)?
    package let graph: GraphStoreAdapter
    package let sync: GraphSyncAdapter?
    package let initialize: @Sendable (NSManagedObjectContext, GraphID, Bool) throws -> Void

    package init(graph: GraphStoreAdapter, sync: GraphSyncAdapter? = nil,
                 initializePolicy: (@Sendable (NSManagedObjectContext, GraphID, GraphConflictPolicy) throws -> Void)? = nil,
                 initialize: @escaping @Sendable (NSManagedObjectContext, GraphID, Bool) throws -> Void) {
        self.graph = graph; self.sync = sync; self.initialize = initialize; self.initializePolicy = initializePolicy
    }
}

/// Owns exactly one local graph. Consumer handles carry independent runtime leases.
package actor GraphCoordinator {
    package nonisolated let id: GraphID
    private let handle: StoreHandle
    private let adapter: GraphStoreAdapter
    private let syncSession: GraphSyncSession?

    private init(id: GraphID, handle: StoreHandle, adapter: GraphStoreAdapter, sync: GraphSyncAdapter?) {
        self.id = id; self.handle = handle; self.adapter = adapter
        self.syncSession = sync.map { GraphSyncSession(graphID: id, handle: handle, adapter: $0) }
    }

    static func open(id: GraphID, configuration: StoreConfiguration, creating: Bool,
                     registry: StoreRegistry, schema: StoreSchema, adapter: GraphCoordinatorAdapter,
                     conflictPolicy: GraphConflictPolicy = .lastEditWins, initiallyBlocked: Bool = false) async throws -> GraphCoordinator {
        guard case .sqlite(let url) = configuration.location else { throw GraphStoreError.unsupportedLayout }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if creating && exists { throw GraphStoreError.duplicateIdentity }
        if !creating && !exists { throw GraphStoreError.missingStore }
        let handle = try await registry.open(configuration, schema: schema)
        let owner = GraphCoordinator(id: id, handle: handle, adapter: adapter.graph, sync: adapter.sync)
        do {
            if creating {
                try await handle.transaction {
                    try adapter.initialize($0, id, true)
                    try adapter.initializePolicy?($0, id, conflictPolicy)
                }
            } else {
                try await handle.read { try adapter.initialize($0, id, false) }
            }
            if initiallyBlocked { try await handle.setDataAvailable(false) }
            if !creating, let access = adapter.graph.participantAccess {
                if try await handle.controlRead({ try access($0, id, nil) }) != nil {
                    try await handle.setDataAvailable(false)
                }
            }
            return owner
        } catch {
            let original = error
            do { try await owner.close() }
            catch { throw GraphCoordinatorQuarantine(owner: owner, failure: error) }
            throw original
        }
    }

    static func recoverForPurge(id: GraphID, configuration: StoreConfiguration, registry: StoreRegistry,
                                schema: StoreSchema, adapter: GraphCoordinatorAdapter) async throws -> GraphCoordinator {
        let handle = try await registry.open(configuration, schema: schema)
        try await handle.setDataAvailable(false)
        return GraphCoordinator(id: id, handle: handle, adapter: adapter.graph, sync: adapter.sync)
    }
    func storeIdentity() async throws -> String {
        let id = id
        return try await handle.controlRead { context in
            guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
                  let store = coordinator.persistentStores.first else { throw GraphCloudError.invalidState }
            let metadata = coordinator.metadata(for: store)
            guard metadata[StoreNativeContext.historySyncGraphKey] as? String == id.rawValue.uuidString,
                  let value = metadata[NSStoreUUIDKey] as? String else { throw GraphCloudError.invalidState }
            return value
        }
    }
    func setSharingDataAvailable(_ value: Bool) async throws { try await handle.setDataAvailable(value) }
    func participantAccess(_ value: GraphCloudParticipantAccess? = nil) async throws -> GraphCloudParticipantAccess? {
        guard let access = adapter.participantAccess else { throw GraphCloudSharingError.unavailable }
        let id = id
        return try await handle.controlTransaction { try access($0, id, value) }
    }
    func destroy(storeID: String) async throws {
        await syncSession?.retire()
        try await handle.destroy(graphID: id.rawValue, storeID: storeID)
    }

    func validateCloudBinding(_ initialize: @escaping @Sendable (NSManagedObjectContext, GraphID, Bool) throws -> Void) async throws {
        let id = id
        try await handle.read { try initialize($0, id, false) }
    }

    func lease(onClose: @escaping @Sendable () async throws -> Void) async throws -> GraphStore {
        let lease = try await handle.newLease()
        return GraphStore.attached(id: id, handle: lease, adapter: adapter,
                                   ownerLease: GraphCoordinatorLease(handle: lease, sync: syncSession, onClose: onClose))
    }

    func localCommitFeed() async throws -> StoreInvalidationFeed {
        try await handle.invalidationFeed(localCommitsOnly: true)
    }

    func close() async throws {
        await syncSession?.retire()
        try await handle.close()
    }
}

/// Keep failed initialization cleanup and its native claims alive in the manager entry.
struct GraphCoordinatorQuarantine: Error {
    let owner: GraphCoordinator
    let failure: any Error
}

/// One consumer release; cancellation never abandons native cleanup or manager release.
actor GraphCoordinatorLease {
    private let handle: StoreHandle
    private let onClose: @Sendable () async throws -> Void
    private var closing: Task<Void, any Error>?
    private let sync: GraphSyncSession?

    init(handle: StoreHandle, sync: GraphSyncSession?, onClose: @escaping @Sendable () async throws -> Void) {
        self.handle = handle; self.sync = sync; self.onClose = onClose
    }

    func session() async throws -> GraphSyncSession {
        guard closing == nil else { throw GraphStoreError.closed }
        _ = try await handle.snapshot()
        guard closing == nil else { throw GraphStoreError.closed }
        guard let sync else { throw GraphSyncError.unavailable }
        return sync
    }

    func close() async throws {
        if let closing { return try await closing.value }
        let handle = handle, onClose = onClose
        let task = Task { try await handle.close(); try await onClose() }
        closing = task
        try await task.value
    }

    deinit {
        guard closing == nil else { return }
        let handle = handle, onClose = onClose
        Task { try? await handle.close(); try? await onClose() }
    }
}
