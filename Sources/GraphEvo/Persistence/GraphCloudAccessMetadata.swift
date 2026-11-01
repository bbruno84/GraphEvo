import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

/// Permission bookkeeping never becomes application data or a consumer edit.
enum GraphCloudAccessMetadata {
    static let key = GraphTypedStoreAdapter.prefix + "participantAccess"
    static func read(_ root: Entity) throws -> GraphCloudParticipantAccess? {
        guard let raw = root[dynamicMember: key] else { return nil }
        guard let data = raw as? Data, data.count <= 64 * 1024 else { throw GraphCloudError.invalidState }
        let value: GraphCloudParticipantAccess
        do { value = try JSONDecoder().decode(GraphCloudParticipantAccess.self, from: data) }
        catch { throw GraphCloudError.invalidState }
        guard value.format == 2, value.binding.zone.scope == .shared, !value.account.isEmpty,
              !value.binding.zone.owner.isEmpty, !value.binding.zone.name.isEmpty,
              value.accepted || value.permission == nil else { throw GraphCloudError.invalidState }
        return value
    }
    static func requireConsumerWrite(_ context: NSManagedObjectContext, id: GraphID) throws {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        if let raw = root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] {
            guard let data = raw as? Data, data.count <= 32 * 1024 * 1024 else { throw GraphCloudError.invalidState }
            struct Header: Decodable { let zoneDeleted: Bool }
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.zoneDeleted { throw GraphCloudError.zoneUnavailable }
        }
        if let value = try read(root) {
            guard value.binding.graphID == id else { throw GraphCloudError.invalidState }
            if !value.writable { throw GraphStoreError.permissionDenied }
        }
    }
    static func access(_ context: NSManagedObjectContext, id: GraphID,
                       value: GraphCloudParticipantAccess?) throws -> GraphCloudParticipantAccess? {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        let prior = try read(root)
        if let prior, prior.binding.graphID != id { throw GraphCloudError.invalidState }
        guard let value else { return prior }
        guard value.binding.graphID == id, value.binding.zone.scope == .shared,
              !value.account.isEmpty, !value.binding.zone.owner.isEmpty, !value.binding.zone.name.isEmpty,
              value.accepted || value.permission == nil else { throw GraphCloudError.invalidState }
        if let prior {
            guard prior.binding == value.binding, prior.account == value.account,
                  prior.identity == value.identity, prior.generation == value.generation,
                  !prior.blocked || value.blocked else { throw GraphCloudError.ownershipConflict }
        } else {
            // An invitation can claim only an untouched, explicitly created local replica.
            let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
            guard session.nodes.isEmpty, try GraphMutationMetadata.deletedIDs(root).isEmpty, root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] == nil,
                  try GraphSyncCheckpointAdapter.load(context, id: id, limits: .init()).state.pending.isEmpty else {
                throw GraphCloudSharingError.nonemptyReplica
            }
        }
        if prior != value {
            let data = try JSONEncoder().encode(value)
            guard data.count <= 64 * 1024 else { throw GraphCloudError.inboxLimit }
            root[dynamicMember: key] = data
            context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
        }
        return value
    }
}
