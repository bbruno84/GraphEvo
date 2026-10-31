import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

public enum GraphStoreError: Error {
    case closed
    case readOnly
    case synchronizationUnavailableInExtension
    case ownershipConflict
    case expiredScope
    case foreignGraph
    case duplicateIdentity
    case corruptIdentity
    case missingNode
    case missingGraph
    case missingStore
    case permissionDenied
    case sharedInsertionRequiresPreparation
    case pendingNativeOperation
    case unresolvedReference
    case legacyStoreRequiresAdoption
    case unsupportedLayout
    case reservedName
    case persistence(underlying: any Error)
}

/// A local adoption report. Old IDs are lookup keys, never the new identity representation.
public struct GraphV1AdoptionReport: Sendable {
    public let graphID: GraphID
    public let nodeIDs: [String: GraphNodeID]
    public let backupURL: URL?
    package init(graphID: GraphID, nodeIDs: [String: GraphNodeID], backupURL: URL?) {
        self.graphID = graphID; self.nodeIDs = nodeIDs; self.backupURL = backupURL
    }
}

/// Privileged callbacks implemented by the current Graph facade adapter.
package struct GraphStoreAdapter: Sendable {
    package var participantAccess: (@Sendable (NSManagedObjectContext, GraphID, GraphCloudParticipantAccess?) throws -> GraphCloudParticipantAccess?)?
    package var beginMutation: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)?
    package var finishMutation: (@Sendable (NSManagedObjectContext, GraphID) throws -> Void)?
    package let initialize: @Sendable (NSManagedObjectContext, URL?) throws -> GraphV1AdoptionReport
    package let fetch: @Sendable (NSManagedObjectContext, GraphID, GraphNodeID) throws -> GraphRecord?
    package let fetchAll: @Sendable (NSManagedObjectContext, GraphID, String, GraphNodeKind) throws -> [GraphRecord]
    package let insert: @Sendable (NSManagedObjectContext, GraphID, GraphRecord) throws -> Void
    package let patch: @Sendable (NSManagedObjectContext, GraphID, GraphRecordPatch) throws -> GraphRecord
    package let delete: @Sendable (NSManagedObjectContext, GraphID, GraphNodeID) throws -> Void
    package let attachmentMetadata: (@Sendable (NSManagedObjectContext, GraphID) throws -> [GraphAttachmentMetadata])?
    package let query: (@Sendable (NSManagedObjectContext, GraphID, GraphQueryRequest) throws -> GraphQueryOutput)?

    package init(
        initialize: @escaping @Sendable (NSManagedObjectContext, URL?) throws -> GraphV1AdoptionReport,
        fetch: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphNodeID) throws -> GraphRecord?,
        fetchAll: @escaping @Sendable (NSManagedObjectContext, GraphID, String, GraphNodeKind) throws -> [GraphRecord],
        insert: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphRecord) throws -> Void,
        patch: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphRecordPatch) throws -> GraphRecord,
        delete: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphNodeID) throws -> Void,
        attachmentMetadata: (@Sendable (NSManagedObjectContext, GraphID) throws -> [GraphAttachmentMetadata])? = nil,
        query: (@Sendable (NSManagedObjectContext, GraphID, GraphQueryRequest) throws -> GraphQueryOutput)? = nil
    ) {
        self.initialize = initialize; self.fetch = fetch; self.fetchAll = fetchAll
        self.insert = insert; self.patch = patch; self.delete = delete; self.query = query; self.attachmentMetadata = attachmentMetadata
    }
}

/// Independently closeable local graph handle. Public operations never expose native contexts.
public actor GraphStore {
    public nonisolated let id: GraphID
    private let handle: StoreHandle
    private let adapter: GraphStoreAdapter
    private let ownerLease: GraphCoordinatorLease?
    private var observationCoordinator: GraphObservationCoordinator?

    private init(id: GraphID, handle: StoreHandle, adapter: GraphStoreAdapter, ownerLease: GraphCoordinatorLease? = nil) {
        self.id = id; self.handle = handle; self.adapter = adapter; self.ownerLease = ownerLease
    }

    static func attached(id: GraphID, handle: StoreHandle, adapter: GraphStoreAdapter, ownerLease: GraphCoordinatorLease) -> GraphStore {
        GraphStore(id: id, handle: handle, adapter: adapter, ownerLease: ownerLease)
    }

    package static func attached(id: GraphID, handle: StoreHandle, adapter: GraphStoreAdapter) -> GraphStore {
        GraphStore(id: id, handle: handle, adapter: adapter)
    }

    package static func open(configuration: StoreConfiguration, schema: StoreSchema, adapter: GraphStoreAdapter,
                             adoptionBackupRoot: URL? = nil) async throws -> (GraphStore, GraphV1AdoptionReport) {
        do {
            let handle = try await StoreRegistry.shared.open(configuration, schema: schema)
            do {
                let report = try await handle.transaction { try adapter.initialize($0, adoptionBackupRoot) }
                return (GraphStore(id: report.graphID, handle: handle, adapter: adapter), report)
            } catch {
                try await handle.close()
                throw error
            }
        } catch { throw translate(error) }
    }

    /// Trusted platform adapter operations retain this logical handle's native owner.
    package func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        do { return try await handle.nativeOperation(body) }
        catch { throw Self.translate(error) }
    }

    package func observationFeed() async throws -> StoreInvalidationFeed {
        do { return try await handle.invalidationFeed() }
        catch { throw Self.translate(error) }
    }

    package func participantAccess(_ value: GraphCloudParticipantAccess? = nil) async throws -> GraphCloudParticipantAccess? {
        guard let access = adapter.participantAccess else { throw GraphCloudSharingError.unavailable }
        let id = id
        return try await handle.transaction { try access($0, id, value) }
    }

    // Created on this actor before suspension; concurrent first subscribers share one coordinator.
    func queryObservationCoordinator() -> GraphObservationCoordinator {
        if let observationCoordinator { return observationCoordinator }
        let coordinator = GraphObservationCoordinator(graph: self)
        observationCoordinator = coordinator
        return coordinator
    }

    package var sharedObservationDiagnostics: GraphSharedObservationSnapshot {
        get async {
            guard let observationCoordinator else { return GraphSharedObservationSnapshot() }
            return await observationCoordinator.diagnostics
        }
    }

    /// Admission only, without opening another feed.
    package func observationAdmission() async throws {
        do { _ = try await handle.snapshot() } catch { throw Self.translate(error) }
    }

    public nonisolated func makeNodeID() -> GraphNodeID { GraphNodeID(graphID: id) }

    private func syncSession() async throws -> GraphSyncSession {
        guard let ownerLease else { throw GraphSyncError.unavailable }
        return try await ownerLease.session()
    }

    package func collectSyncChanges(limits: GraphSyncLimits = .init()) async throws -> Int {
        try await syncSession().collect(limits: limits)
    }

    package func prepareSyncBatch(maximumRecords: Int, limits: GraphSyncLimits = .init()) async throws -> GraphSyncBatch {
        try await syncSession().prepare(maximumRecords: maximumRecords, limits: limits)
    }

    package func acknowledgeSyncBatch(_ id: UUID, succeeded: Set<GraphNodeID>, limits: GraphSyncLimits = .init()) async throws -> Int {
        try await syncSession().acknowledge(id, succeeded: succeeded, limits: limits)
    }

    package func abandonSyncBatch(_ id: UUID) async throws { try await syncSession().abandon(id) }

    package func applyImportedPatches(_ patches: [GraphRecordPatch], limits: GraphSyncLimits = .init()) async throws {
        try await syncSession().importPatches(patches, limits: limits)
    }

    /// Convert one immutable PH attempt; failed encoding releases only that attempt, never pending work.
    package func prepareCloudBatch(maximumRecords: Int, binding: GraphCloudBinding,
                                   systemFields: [GraphNodeID: Data] = [:],
                                   discoveryLimits: GraphSyncLimits = .init(),
                                   encodingLimits: GraphCloudNodeLimits = .init()) async throws -> GraphCloudOutgoingBatch {
        guard binding.graphID == id else { throw GraphCloudNodeError.foreignGraph }
        let session = try await syncSession()
        let batch = try await session.prepare(maximumRecords: maximumRecords, limits: discoveryLimits)
        do { return try GraphCloudNodeCodec.encode(batch, binding: binding, systemFields: systemFields, limits: encodingLimits) }
        catch {
            await session.discardPreparation(batch.id)
            throw error
        }
    }

    package func prepareTransport(_ binding: GraphCloudTransportBinding, maximum: Int = 100, limits: GraphSyncLimits = .init(), onlyIDs: Set<GraphNodeID>? = nil) async throws -> GraphCloudOutgoingBatch {
        try await syncSession().prepareTransport(binding, maximum: maximum, limits: limits, onlyIDs: onlyIDs)
    }
    package func commitTransport(_ binding: GraphCloudTransportBinding, receipt: GraphCloudSentReceipt, limits: GraphSyncLimits = .init()) async throws {
        _ = try await syncSession().commitTransport(binding, receipts: [receipt], limits: limits)
    }
    package func commitTransport(_ binding: GraphCloudTransportBinding, receipts: [GraphCloudSentReceipt], limits: GraphSyncLimits = .init()) async throws -> GraphCloudResolution {
        try await syncSession().commitTransport(binding, receipts: receipts, limits: limits)
    }
    @discardableResult package func applyTransport(_ binding: GraphCloudTransportBinding, effects: [GraphCloudEffect], limits: GraphSyncLimits = .init()) async throws -> GraphCloudResolution {
        try await syncSession().applyTransport(binding, effects: effects, limits: limits)
    }
    package func trimTransport(_ binding: GraphCloudTransportBinding, receipts: Set<UUID>) async throws {
        try await syncSession().trimTransport(binding, receipts: receipts)
    }

    package func pruneTransport(_ binding: GraphCloudTransportBinding, retained: Set<UUID>) async throws {
        try await syncSession().pruneTransport(binding, retained: retained)
    }

    package var conflictPolicy: GraphConflictPolicy {
        get async throws { try await syncSession().conflictPolicy(nil) }
    }
    package func setConflictPolicy(_ policy: GraphConflictPolicy) async throws {
        _ = try await syncSession().conflictPolicy(policy)
    }

    public func close() async throws {
        do {
            if let ownerLease { try await ownerLease.close() }
            else { try await handle.close() }
        } catch { throw Self.translate(error) }
    }

    public func read<Value: Sendable>(
        _ body: @escaping @Sendable (GraphReadScope) throws -> Value
    ) async throws -> Value {
        let adapter = adapter, id = id
        do {
            return try await handle.read { context in
                let scope = GraphReadScope(context: context, graphID: id, adapter: adapter)
                defer { scope.invalidate() }
                return try body(scope)
            }
        } catch { throw Self.translate(error) }
    }

    public func transaction<Value: Sendable>(
        _ body: @escaping @Sendable (GraphMutation) throws -> Value
    ) async throws -> Value {
        let adapter = adapter, id = id
        do {
            return try await handle.transaction { context in
                let scope = GraphMutation(context: context, graphID: id, adapter: adapter)
                defer { scope.invalidate() }
                try adapter.beginMutation?(context, id)
                let result = try body(scope)
                try adapter.finishMutation?(context, id)
                return result
            }
        } catch { throw Self.translate(error) }
    }

    public func fetch<Model: GraphModel>(_ id: GraphNodeID, as type: Model.Type = Model.self) async throws -> Model? {
        try await read { try $0.fetch(id, as: type) }
    }

    public func fetchAll<Model: GraphModel>(_ type: Model.Type) async throws -> [Model] {
        try await read { try $0.fetchAll(type) }
    }

    @discardableResult public func insert<Model: GraphModel>(_ model: Model) async throws -> GraphNodeID {
        try await transaction { try $0.insert(model) }
    }

    public func patch<Model: GraphModel>(_ patch: GraphRecordPatch, as type: Model.Type) async throws -> Model {
        try await transaction { try $0.patch(patch, as: type) }
    }

    public func delete(_ id: GraphNodeID) async throws { try await transaction { try $0.delete(id) } }

    package static func translate(_ error: any Error) -> any Error {
        guard let runtime = error as? StoreRuntimeError else { return error }
        switch runtime {
        case .missingStore: return GraphStoreError.missingStore
        case .readOnlyStore: return GraphStoreError.readOnly
        case .synchronizationUnavailableInExtension: return GraphStoreError.synchronizationUnavailableInExtension
        case .closedHandle: return GraphStoreError.closed
        case .configurationConflict: return GraphStoreError.ownershipConflict
        default: return GraphStoreError.persistence(underlying: error)
        }
    }
}

extension GraphStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingStore: return "The local store is unavailable until the containing app initializes it."
        case .readOnly: return "The graph store is open for local reading only."
        case .synchronizationUnavailableInExtension: return "Cloud synchronization must be owned by the containing app; use local read-only access in the extension."
        case .ownershipConflict: return "The store has an incompatible persistence owner."
        case .closed: return "The graph store handle is closed."
        case .expiredScope: return "The graph operation scope has expired."
        case .foreignGraph: return "The node belongs to another graph."
        case .duplicateIdentity: return "The graph contains a duplicate logical node identity."
        case .corruptIdentity: return "The graph's persisted identity metadata is invalid."
        case .permissionDenied: return "The current sharing metadata does not permit this write."
        case .sharedInsertionRequiresPreparation: return "New shared objects require an awaited native assignment operation."
        case .pendingNativeOperation: return "A previous native graph operation is still pending."
        case .missingGraph: return "The requested logical graph is not present in the local catalog."
        case .missingNode: return "The requested graph node does not exist."
        case .unresolvedReference: return "A graph endpoint does not resolve to an entity in this graph."
        case .legacyStoreRequiresAdoption: return "The local v1 store requires explicit adoption with a backup."
        case .unsupportedLayout: return "The graph store layout version is unsupported."
        case .reservedName: return "The graph operation uses a reserved type or property name."
        case .persistence: return "The graph persistence operation failed."
        }
    }
}
