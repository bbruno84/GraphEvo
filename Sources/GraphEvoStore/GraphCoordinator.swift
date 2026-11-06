import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Facade-owned initialization; the runtime transaction owns the single save.
package struct GraphCoordinatorAdapter: Sendable {
    package var activation: GraphCloudActivationAdapter? = nil
    package var account: GraphCloudAccountNativeAdapter? = nil
    package let migrationSource: GraphStoreMigrationSource?
    package let v1Conversion: GraphV1ConversionAdapter?
    package var nativeV1Migration: GraphNativeV1MigrationAdapter?
    package let publication: GraphMigrationPublicationAdapter?
    package let workspace: GraphMigrationWorkspaceAdapter?
    package let prepareWorkspace: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)?
    package let initializePolicy: (@Sendable (NSManagedObjectContext, GraphID, GraphConflictPolicy) throws -> Void)?
    package let validateBackup: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)?
    package let graph: GraphStoreAdapter
    package let sync: GraphSyncAdapter?
    package let initialize: @Sendable (NSManagedObjectContext, GraphID, Bool) throws -> Void

    package init(graph: GraphStoreAdapter, sync: GraphSyncAdapter? = nil, v1Conversion: GraphV1ConversionAdapter? = nil, migrationSource: GraphStoreMigrationSource? = nil,
                 initializePolicy: (@Sendable (NSManagedObjectContext, GraphID, GraphConflictPolicy) throws -> Void)? = nil,
                 publication: GraphMigrationPublicationAdapter? = nil,
                 workspace: GraphMigrationWorkspaceAdapter? = nil,
                 prepareWorkspace: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)? = nil,
                 validateBackup: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)? = nil,
                 account: GraphCloudAccountNativeAdapter? = nil,
                 initialize: @escaping @Sendable (NSManagedObjectContext, GraphID, Bool) throws -> Void) {
        self.account = account; self.graph = graph; self.sync = sync; self.v1Conversion = v1Conversion; self.migrationSource = migrationSource; self.initialize = initialize; self.initializePolicy = initializePolicy; self.validateBackup = validateBackup; self.prepareWorkspace = prepareWorkspace; self.workspace = workspace; self.publication = publication
    }
}

/// Owns exactly one local graph. Consumer handles carry independent runtime leases.
package actor GraphCoordinator {
    package nonisolated let id: GraphID
    private let handle: StoreHandle
    private let storeURL: URL
    private let adapter: GraphStoreAdapter
    private let syncSession: GraphSyncSession?
    private let workspace: GraphMigrationWorkspaceAdapter?
    private let activation: GraphCloudActivationAdapter?
    private let account: GraphCloudAccountNativeAdapter?
    private let publication: GraphMigrationPublicationAdapter?

    private init(id: GraphID, handle: StoreHandle, storeURL: URL, adapter: GraphStoreAdapter, sync: GraphSyncAdapter?, workspace: GraphMigrationWorkspaceAdapter? = nil, publication: GraphMigrationPublicationAdapter? = nil, activation: GraphCloudActivationAdapter? = nil, account: GraphCloudAccountNativeAdapter? = nil) {
        self.id = id; self.handle = handle; self.storeURL = storeURL; self.adapter = adapter; self.workspace = workspace; self.publication = publication; self.activation = activation; self.account = account
        self.syncSession = sync.map { GraphSyncSession(graphID: id, handle: handle, adapter: $0) }
    }

    static func open(id: GraphID, configuration: StoreConfiguration, creating: Bool,
                     registry: StoreRegistry, schema: StoreSchema, adapter: GraphCoordinatorAdapter,
                     conflictPolicy: GraphConflictPolicy = .lastEditWins, initiallyBlocked: Bool = false,
                     initialParticipant: GraphCloudParticipantAccess? = nil, appGroupLocalOnly: Bool = false,
                     appGroupPrivateCloud: Bool = false) async throws -> GraphCoordinator {
        guard case .sqlite(let url) = configuration.location else { throw GraphStoreError.unsupportedLayout }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if creating && exists { throw GraphStoreError.duplicateIdentity }
        if !creating && !exists { throw GraphStoreError.missingStore }
        let handle = try await registry.open(configuration, schema: schema, mode: creating ? .new : .existing)
        let owner = GraphCoordinator(id: id, handle: handle, storeURL: url.standardizedFileURL.resolvingSymlinksInPath(),
            adapter: adapter.graph, sync: adapter.sync, workspace: adapter.workspace,
            publication: adapter.publication, activation: adapter.activation, account: adapter.account)
        do {
            if creating {
                try await handle.transaction {
                    try adapter.initialize($0, id, true)
                    try adapter.initializePolicy?($0, id, conflictPolicy)
                    if let initialParticipant {
                        guard let write = adapter.graph.participantAccess, let claim = adapter.account?.claim,
                              let identity = initialParticipant.identity else { throw GraphCloudError.invalidConfiguration }
                        _ = try write($0, id, initialParticipant)
                        try claim($0, id, identity)
                    }
                }
            } else {
                try await handle.read { try adapter.initialize($0, id, false) }
            }
            if initiallyBlocked || initialParticipant != nil { try await handle.setDataAvailable(false) }
            if !creating, let access = adapter.graph.participantAccess {
                if let value = try await handle.controlRead({ try access($0, id, nil) }) {
                    if appGroupLocalOnly {
                        throw value.blocked ? GraphStoreError.resourceReserved : GraphStoreError.accountIsolated
                    }
                    try await handle.setDataAvailable(false, terminal: value.blocked)
                }
            }
            if let activation = adapter.activation, let value = try await handle.controlRead({ try activation.read($0, id) }) {
                if appGroupLocalOnly { throw GraphStoreError.resourceReserved }
                if value.blocksWrites { try await handle.restrictActivation(value.authority.activationID, reads: value.peer) }
            }
            if try await owner.accountIdentity() != nil {
                if appGroupLocalOnly && !appGroupPrivateCloud { throw GraphStoreError.accountIsolated }
                try await handle.setAccountStatus(.isolated(.verificationRequired), revision: 0)
            }
            return owner
        } catch {
            let original = error
            do { try await owner.close() }
            catch { throw GraphCoordinatorQuarantine(owner: owner, failure: error) }
            throw original
        }
    }

    func accountControl() async throws -> StoreAccountControl { try await handle.accountControl() }
    func accountIdentity() async throws -> GraphCloudSessionIdentity? {
        guard let account else { return nil }; let id = id
        return try await handle.accountControlRead { try account.read($0, id) }
    }
    func scopedAccountCheck(_ expected: GraphCloudSessionIdentity?) -> @Sendable (NSManagedObjectContext) throws -> Void {
        let account = account, id = id
        return { context in
            guard try account?.read(context, id) == expected else { throw GraphStoreError.accountIsolated }
        }
    }
    func claimAccount(_ identity: GraphCloudSessionIdentity) async throws {
        guard let account else { throw GraphCloudError.invalidConfiguration }; let id = id
        if let existing = try await accountIdentity() {
            guard existing == identity else { throw GraphCloudError.ownershipConflict }
            return
        }
        try await handle.accountControlTransaction { try account.claim($0, id, identity) }
    }
    func setAccountStatus(_ status: StoreAccountStatus, revision: UInt64) async throws {
        try await handle.setAccountStatus(status, revision: revision)
    }

    func activationDocument() async throws -> GraphCloudActivationDocument? {
        guard let activation else { return nil }; let id = id
        return try await handle.accountControlRead { try activation.read($0, id) }
    }
    func requiresCloudActivation() async throws -> Bool {
        guard let activation else { return false }; let id = id
        return try await handle.accountControlRead { try activation.requiresActivation($0, id) }
    }
    func prepareActivation(_ binding: GraphCloudTransportBinding, operation: UUID, declaration: GraphCloudCutoverDeclaration,
                           limits: GraphCloudActivationLimits) async throws -> GraphCloudActivationDocument {
        guard let activation else { throw GraphCloudActivationError.unavailable }
        return try await handle.controlTransaction { try activation.prepare($0, binding, operation, declaration, limits) }
    }
    func persistActivation(_ value: GraphCloudActivationDocument) async throws {
        guard let activation else { throw GraphCloudActivationError.unavailable }; let id = id
        try await handle.controlTransaction { try activation.write($0, id, value) }
    }
    func prepareActivationPeer(_ binding: GraphCloudTransportBinding, authority: GraphCloudAuthority,
                               limits: GraphCloudActivationLimits) async throws -> GraphCloudActivationDocument {
        guard let activation else { throw GraphCloudActivationError.unavailable }
        return try await handle.controlTransaction { try activation.peer($0, binding, authority, limits) }
    }
    func activationAccess(_ id: UUID, peer: Bool = false, release: Bool = false) async throws {
        try await handle.restrictActivation(id, reads: peer, release: release)
    }
    func validateActivationReplica() async throws -> Int {
        guard let validate = adapter.validateIntegrity else { throw GraphCloudActivationError.unavailable }; let id = id
        return try await handle.controlRead { try validate($0, id) }
    }
    func activationReplicaIDs() async throws -> Set<GraphNodeID> {
        guard let activation else { throw GraphCloudActivationError.unavailable }; let id = id
        return try await handle.controlRead { try activation.replicaIDs($0, id) }
    }

    static func recoverForPurge(id: GraphID, configuration: StoreConfiguration, storeID: String, registry: StoreRegistry,
                                schema: StoreSchema, adapter: GraphCoordinatorAdapter) async throws -> GraphCoordinator {
        guard case .sqlite(let url) = configuration.location else { throw GraphStoreError.unsupportedLayout }
        let mode: StoreOpeningMode = configuration.appGroup == nil ? .existing : .appGroupPurgeRecovery(storeID: storeID)
        let handle = try await registry.open(configuration, schema: schema, mode: mode)
        do { try await handle.setDataAvailable(false, terminal: true) }
        catch {
            let original = error
            try await handle.close()
            throw original
        }
        return GraphCoordinator(id: id, handle: handle, storeURL: url.standardizedFileURL.resolvingSymlinksInPath(),
            adapter: adapter.graph, sync: adapter.sync, workspace: adapter.workspace, publication: adapter.publication)
    }
    func publicationReceipt(for workspace: UUID) async throws -> GraphMigrationPublicationReceipt? {
        guard let publication else { return nil }
        let id = id
        return try await handle.controlRead { try publication.receipt($0, id, workspace) }
    }
    func preflightPublication(_ descriptor: GraphMigrationWorkspaceDescriptor, seal: GraphMigrationChangeSet) async throws {
        guard let publication else { throw GraphMigrationPublicationError.unavailable }
        try await handle.controlRead { try publication.preflight($0, descriptor, seal) }
    }
    func publish(_ descriptor: GraphMigrationWorkspaceDescriptor, seal: GraphMigrationChangeSet,
                 intent: GraphMigrationPublicationIntent, items: [GraphMigrationPublicationItem], reservation: StoreReservation) async throws -> GraphMigrationPublicationReceipt {
        guard let publication else { throw GraphMigrationPublicationError.unavailable }
        return try await handle.publicationTransaction(graphID: id.rawValue, reservation: reservation) {
            try publication.apply($0, descriptor, seal, intent, items)
        }
    }
    func validateMigrationSource(_ boundary: GraphMigrationBoundary) async throws {
        guard let workspace else { throw GraphMigrationWorkspaceError.unavailable }
        let id = id
        try await handle.controlRead { try workspace.validateSource($0, id, boundary) }
    }
    func validateUntouchedJoin(_ expected: GraphCloudParticipantAccess) async throws {
        guard let read = adapter.participantAccess, let validate = adapter.validateIntegrity else { throw GraphCloudError.invalidState }
        let id = id
        try await handle.controlRead { context in
            guard try read(context, id, nil) == expected, try validate(context, id) == 0 else { throw GraphCloudDiscoveryError.invalidJoin }
        }
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
    func blockSharingData() async throws { try await handle.setDataAvailable(false, terminal: true) }
    func suspendLocalWrites() async throws -> StoreReservation { try await handle.suspendWrites() }
    func reserveMaintenance() async throws -> StoreReservation { try await handle.reserveMaintenance() }
    func copyStore(to url: URL, reservation: StoreReservation, storeID: String) async throws -> GraphMigrationBoundary {
        let storeURL = storeURL
        return try await handle.copyStore(to: url, reservation: reservation) { context, target, check in
            let boundary = try GraphMigrationBoundary.capture(context)
            guard boundary.storeID == storeID else { throw GraphMigrationWorkspaceError.staleSource }
            let spool = try GraphCloudAssetSpool(root: GraphCloudAssetSpool.outgoingRoot(storeURL: storeURL, storeID: storeID))
            try spool.copyOwnedRoot(to: GraphCloudAssetSpool.outgoingRoot(storeURL: target, storeID: storeID), check: check)
            return boundary
        }
    }
    func participantAccess(_ value: GraphCloudParticipantAccess? = nil) async throws -> GraphCloudParticipantAccess? {
        guard let access = adapter.participantAccess else { throw GraphCloudSharingError.unavailable }
        let id = id
        if let value { return try await handle.controlTransaction { try access($0, id, value) } }
        return try await handle.controlRead { try access($0, id, nil) }
    }
    func destroy(storeID: String) async throws -> StoreDestructionOutcome {
        await syncSession?.retire()
        return try await handle.destroy(graphID: id.rawValue, storeID: storeID)
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
