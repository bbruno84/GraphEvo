import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

/// Ordinary replica bootstrap has its own provenance; it is never a v1 conversion.
enum GraphPrivateReplicaNative {
    static let key = GraphTypedStoreAdapter.prefix + "privateReplica"
    static func read(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphPrivateReplicaState? {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        guard let raw = root[dynamicMember: key] else { return nil }
        guard let bytes = raw as? Data, bytes.count <= 16 * 1024 else { throw GraphCloudError.invalidState }
        let state = try JSONDecoder().decode(GraphPrivateReplicaState.self, from: bytes)
        guard state.format == 1, state.binding.route.graphID == id, state.binding.route.zone.scope == .private,
              state.storeID == (try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state.storeID) else {
            throw GraphCloudError.invalidState
        }
        return state
    }
    static let adapter = GraphPrivateReplicaAdapter(read: { try read($0, id: $1) }, prepare: { context, id, binding, operation in
        if let prior = try read(context, id: id) {
            guard prior.binding == binding else { throw GraphCloudError.ownershipConflict }
            return prior
        }
        let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
        guard session.nodes.isEmpty, try GraphCloudActivationNative.read(context, id) == nil else {
            throw GraphCloudSharingError.nonemptyReplica
        }
        let state = GraphPrivateReplicaState(operationID: operation, binding: binding,
            storeID: try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state.storeID, ready: false)
        session.root?[dynamicMember: key] = try JSONEncoder().encode(state)
        context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
        return state
    }, complete: { context, id, operation in
        guard var state = try read(context, id: id), state.operationID == operation else { throw GraphCloudError.invalidState }
        state.ready = true
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        root[dynamicMember: key] = try JSONEncoder().encode(state)
        context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
    }, ids: { context, id in
        Set(try GraphTypedStoreAdapter.Session(context, id, database: true).nodes.keys)
    })
}
