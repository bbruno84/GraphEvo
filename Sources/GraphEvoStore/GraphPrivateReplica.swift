import CoreData
import Foundation
import GraphEvoModel

package struct GraphPrivateReplicaState: Codable, Sendable, Equatable {
    package var format = 1
    package let operationID: UUID
    package let binding: GraphCloudTransportBinding
    package let storeID: String
    package var ready: Bool
    package init(operationID: UUID, binding: GraphCloudTransportBinding, storeID: String, ready: Bool) {
        self.operationID = operationID; self.binding = binding; self.storeID = storeID; self.ready = ready
    }
}

package struct GraphPrivateReplicaAdapter: Sendable {
    package let read: @Sendable (NSManagedObjectContext, GraphID) throws -> GraphPrivateReplicaState?
    package let prepare: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, UUID) throws -> GraphPrivateReplicaState
    package let complete: @Sendable (NSManagedObjectContext, GraphID, UUID) throws -> Void
    package let ids: @Sendable (NSManagedObjectContext, GraphID) throws -> Set<GraphNodeID>
    package init(read: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> GraphPrivateReplicaState?,
                 prepare: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, UUID) throws -> GraphPrivateReplicaState,
                 complete: @escaping @Sendable (NSManagedObjectContext, GraphID, UUID) throws -> Void,
                 ids: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> Set<GraphNodeID>) {
        self.read = read; self.prepare = prepare; self.complete = complete; self.ids = ids
    }
}
