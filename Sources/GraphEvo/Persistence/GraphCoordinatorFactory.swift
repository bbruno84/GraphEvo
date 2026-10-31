import CoreData
import Foundation
import GraphEvoRuntime
import GraphEvoStore

/// Internal production entry point; public opening remains a later increment.
enum GraphCoordinatorFactory {
    static let shared = GraphContextManager(schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)

    static var adapter: GraphCoordinatorAdapter { makeAdapter() }

    static func makeAdapter(clock: @escaping @Sendable () -> Date = { Date() }) -> GraphCoordinatorAdapter {
        let native = GraphNativeIdentityDatabaseAdapter.database
        var graph = native.graph
        graph.beginMutation = { context, id in
            try GraphCloudAccessMetadata.requireConsumerWrite(context, id: id)
            GraphMutationMetadata.begin(context)
        }
        graph.participantAccess = GraphCloudAccessMetadata.access
        graph.finishMutation = { context, id in try GraphMutationMetadata.finish(context, graphID: id, clock: clock) }
        var sync = GraphSyncCheckpointAdapter.adapter
        sync.policy = { (context: NSManagedObjectContext, id: GraphID, policy: GraphConflictPolicy?) in
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            if let policy {
                root[dynamicMember: GraphMutationMetadata.policyKey] = policy.rawValue
                context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
            }
            return try GraphMutationMetadata.policy(root)
        }
        return GraphCoordinatorAdapter(graph: graph, sync: sync, initializePolicy: { context, id, policy in
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            root[dynamicMember: GraphMutationMetadata.policyKey] = policy.rawValue
        }) { context, id, creating in
            guard !(context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer),
                  context.persistentStoreCoordinator?.persistentStores.count == 1 else {
                throw GraphStoreError.unsupportedLayout
            }
            if creating {
                guard try native.catalog(context).isEmpty else { throw GraphStoreError.duplicateIdentity }
                try native.create(context, id)
            } else {
                let ids = try native.catalog(context)
                guard ids == [id] else {
                    if ids.isEmpty { throw GraphStoreError.missingGraph }
                    throw GraphStoreError.foreignGraph
                }
            }
            // Graph-scoped reads alone would hide orphan rows from another graph.
            let graph = GraphTypedStoreAdapter.facade(context)
            for node in try GraphTypedStoreAdapter.allNodes(graph) {
                guard node.node.value(forKey: GraphNativeIdentityColumns.graphAttribute) as? String == id.rawValue.uuidString else {
                    throw GraphStoreError.foreignGraph
                }
            }
            _ = try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: id)
            if creating { try GraphSyncCheckpointAdapter.reservePurpose(context, graphID: id) }
            else { try GraphSyncCheckpointAdapter.requirePurpose(context, graphID: id) }
        }
    }
}
