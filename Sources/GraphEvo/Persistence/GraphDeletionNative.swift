import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

enum GraphDeletionNative {
    static let key = GraphTypedStoreAdapter.prefix + "deletion"
    static let adapter = GraphDeletionAdapter { context, id, proposed in
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        let prior: GraphDeletionIntent?
        if let raw = root[dynamicMember: key] {
            guard let bytes = raw as? Data, bytes.count <= 16 * 1024 else { throw GraphCloudError.invalidState }
            prior = try JSONDecoder().decode(GraphDeletionIntent.self, from: bytes)
            guard prior?.valid == true, prior?.graphID == id else { throw GraphCloudError.invalidState }
        } else { prior = nil }
        if let value = proposed {
            guard let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first,
                  coordinator.metadata(for: store)[StoreNativeContext.workspaceKey] == nil else { throw GraphStoreError.resourceReserved }
            guard value.valid, value.graphID == id,
                  value.storeID == (try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state.storeID),
                  prior.map({ $0.matches(value) }) ?? true else { throw GraphCloudError.ownershipConflict }
            root[dynamicMember: key] = try JSONEncoder().encode(value)
            context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
            return value
        }
        return prior
    }
}
