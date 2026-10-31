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
                     conflictPolicy: GraphConflictPolicy = .lastEditWins) async throws -> GraphCoordinator {
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
            return owner
        } catch {
            let original = error
            do { try await owner.close() }
            catch { throw GraphCoordinatorQuarantine(owner: owner, failure: error) }
            throw original
        }
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
