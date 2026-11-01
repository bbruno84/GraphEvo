import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Reuses PH primitive reconstruction without publishing a checkpoint or touching the source queue.
enum GraphMigrationNativeWorkspace {
    static let sealKey = GraphTypedStoreAdapter.prefix + "workspaceSeal"
    static func hasSeal(_ root: Entity) -> Bool {
        root.node.propertySet.contains { $0.name == sealKey }
    }
    static func baselineAuthor(_ id: UUID) -> String { "GraphEvo.v2.workspace.\(id.uuidString).baseline" }
    static func sealAuthor(_ id: UUID) -> String { "GraphEvo.v2.workspace.\(id.uuidString).seal" }

    static let adapter = GraphMigrationWorkspaceAdapter(validateSource: { context, id, boundary in
        try GraphMigrationHistory.validateSource(context, boundary: boundary)
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        let start = GraphSyncCheckpointAdapter.Checkpoint(graphID: id, storeID: boundary.storeID,
            epoch: UUID(), token: boundary.token)
        var value = GraphSyncCheckpointAdapter.Loaded(root: root, original: start, state: start)
        try GraphSyncCheckpointAdapter.reconcile(context, value: &value, limits: .init(),
            workspace: true, requiredAuthor: GraphSyncCheckpointAdapter.metadataAuthor)
        guard value.state.pending.isEmpty else { throw GraphMigrationWorkspaceError.staleSource }
    }, inspect: { context, descriptor, limits in
        try validateAnchor(context, descriptor)
        try GraphCoordinatorFactory.validateGraph(context, id: descriptor.graphID)
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: descriptor.graphID)
        if hasSeal(root) {
            guard let bytes = root[dynamicMember: sealKey] as? Data else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            guard bytes.count <= limits.maximumEncodedBytes else { throw GraphMigrationWorkspaceError.encodedLimit }
            let seal = try JSONDecoder().decode(GraphMigrationChangeSet.self, from: bytes)
            guard seal.format == 1, seal.workspaceID == descriptor.id, seal.graphID == descriptor.graphID,
                  seal.baseline == descriptor.baseline else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            try validateTail(context, descriptor: descriptor, seal: seal)
            let reconstructed = try reduce(context, descriptor, limits: limits, sealed: true)
            guard reconstructed == seal else { throw GraphMigrationWorkspaceError.invalidWorkspace }
            return seal
        }
        _ = try reduce(context, descriptor, limits: limits, sealed: false)
        return nil
    }, seal: { context, descriptor, limits in
        try validateAnchor(context, descriptor)
        try GraphCoordinatorFactory.validateGraph(context, id: descriptor.graphID)
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: descriptor.graphID)
        guard !hasSeal(root) else { throw GraphMigrationWorkspaceError.sealed }
        let result = try reduce(context, descriptor, limits: limits, sealed: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(result)
        guard bytes.count <= limits.maximumEncodedBytes else { throw GraphMigrationWorkspaceError.encodedLimit }
        root[dynamicMember: sealKey] = bytes
        context.transactionAuthor = sealAuthor(descriptor.id)
        return result
    })

    private static func validateAnchor(_ context: NSManagedObjectContext, _ descriptor: GraphMigrationWorkspaceDescriptor) throws {
        try GraphSyncCheckpointAdapter.requirePurpose(context, graphID: descriptor.graphID)
        guard descriptor.format == 2, let coordinator = context.persistentStoreCoordinator,
              let store = coordinator.persistentStores.first,
              coordinator.metadata(for: store)[StoreNativeContext.workspaceKey] as? String == descriptor.id.uuidString,
              coordinator.metadata(for: store)[NSStoreUUIDKey] as? String == descriptor.baseline.storeID else {
            throw GraphMigrationWorkspaceError.invalidWorkspace
        }
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: descriptor.graphID)
        guard root[dynamicMember: GraphTypedStoreAdapter.prefix + "workspaceBoundary"] as? String == descriptor.id.uuidString,
              root[dynamicMember: GraphSyncCheckpointAdapter.stateKey] == nil,
              root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] == nil,
              try GraphCloudAccessMetadata.read(root) == nil else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        let rows = try GraphMigrationHistory.transactions(context, after: nil, maximum: 2, author: baselineAuthor(descriptor.id))
        guard rows.count == 1, let anchor = rows.first, anchor.storeID == descriptor.baseline.storeID,
              anchor.transactionNumber == descriptor.baseline.transaction,
              anchor.token.isEqual(try GraphMigrationHistory.token(descriptor.baseline.token)) else {
            throw GraphMigrationWorkspaceError.historyUnavailable
        }
    }

    private static func reduce(_ context: NSManagedObjectContext, _ descriptor: GraphMigrationWorkspaceDescriptor,
                               limits: GraphMigrationWorkspaceLimits, sealed: Bool) throws -> GraphMigrationChangeSet {
        try limits.validate()
        guard let number = descriptor.baseline.transaction, number > 0 else { throw GraphMigrationWorkspaceError.historyUnavailable }
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: descriptor.graphID)
        let start = GraphSyncCheckpointAdapter.Checkpoint(graphID: descriptor.graphID, storeID: descriptor.baseline.storeID,
            epoch: descriptor.id, token: descriptor.baseline.token, transaction: number)
        var value = GraphSyncCheckpointAdapter.Loaded(root: root, original: start, state: start)
        let inserted = try GraphSyncCheckpointAdapter.reconcile(context, value: &value,
            limits: .init(maximumTransactions: limits.maximumTransactions, maximumChanges: limits.maximumNativeChanges,
                          maximumPending: limits.maximumNativeChanges), workspace: true,
            excludingAuthor: sealed ? sealAuthor(descriptor.id) : nil)
        let changes = try value.state.pending.filter { !($0.operation == .delete && inserted.contains($0.id)) }.map { item in
            let kind: GraphMigrationPrimitive
            switch item.nativeKind {
            case ModelIdentifier.entityName: kind = .entity
            case ModelIdentifier.relationshipName: kind = .relationship
            case ModelIdentifier.actionName: kind = .action
            default: throw GraphSyncError.unresolvedChange
            }
            return GraphMigrationChange(id: item.id, kind: kind, operation: item.operation)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        guard changes.count <= limits.maximumLogicalChanges else { throw GraphMigrationWorkspaceError.changeLimit }
        guard let endToken = value.state.token else { throw GraphMigrationWorkspaceError.historyUnavailable }
        let end = GraphMigrationBoundary(storeID: descriptor.baseline.storeID, transaction: value.state.transaction, token: endToken)
        if !sealed {
            let current = try GraphMigrationBoundary.capture(context)
            guard try GraphMigrationHistory.token(current.token).isEqual(GraphMigrationHistory.token(end.token)) else {
                throw GraphMigrationWorkspaceError.historyUnavailable
            }
        }
        return GraphMigrationChangeSet(workspaceID: descriptor.id, graphID: descriptor.graphID,
            baseline: descriptor.baseline, end: end, changes: changes)
    }

    private static func validateTail(_ context: NSManagedObjectContext, descriptor: GraphMigrationWorkspaceDescriptor,
                                     seal: GraphMigrationChangeSet) throws {
        let rows = try GraphMigrationHistory.transactions(context, after: GraphMigrationHistory.token(seal.end.token), maximum: 2)
        let current = try GraphMigrationBoundary.capture(context)
        guard rows.count == 1, let transaction = rows.first,
              transaction.storeID == descriptor.baseline.storeID, transaction.author == sealAuthor(descriptor.id),
              transaction.token.isEqual(try GraphMigrationHistory.token(current.token)) else {
            throw GraphMigrationWorkspaceError.historyUnavailable
        }
    }
}
