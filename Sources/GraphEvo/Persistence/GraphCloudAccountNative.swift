import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Local identity ownership is independent of transport progress and survives closed sessions.
enum GraphCloudAccountNative {
    static let key = GraphTypedStoreAdapter.prefix + "cloudAccount"
    private struct Record: Codable {
        var format = 1
        let graphID: GraphID
        let identity: GraphCloudSessionIdentity
    }
    static func read(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphCloudSessionIdentity? {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        var identities: [GraphCloudSessionIdentity] = []
        if let raw = root[dynamicMember: key] {
            guard let bytes = raw as? Data, bytes.count <= 64 * 1024 else { throw GraphCloudError.invalidState }
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.format == 1, record.graphID == id else { throw GraphCloudError.invalidState }
            identities.append(record.identity)
        }
        if let identity = try GraphSyncCheckpointAdapter.existingCloudIdentity(context, id: id) { identities.append(identity) }
        if let access = try GraphCloudAccessMetadata.read(root) {
            guard let identity = access.identity, identity.account == access.account else { throw GraphCloudError.invalidState }
            identities.append(identity)
        }
        if let activation = try GraphCloudActivationNative.adapter.read(context, id) { identities.append(activation.binding.identity) }
        guard let identity = identities.first else { return nil }
        guard !identity.container.isEmpty, !identity.account.isEmpty, identities.allSatisfy({ $0 == identity }) else { throw GraphCloudError.invalidState }
        return identity
    }
    static let adapter = GraphCloudAccountNativeAdapter(read: { try read($0, id: $1) }, claim: { context, id, identity in
        guard !identity.container.isEmpty, !identity.account.isEmpty else { throw GraphCloudError.invalidState }
        if let existing = try read(context, id: id) {
            guard existing == identity else { throw GraphCloudError.ownershipConflict }
        }
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        if root[dynamicMember: key] != nil { return }
        root[dynamicMember: key] = try JSONEncoder().encode(Record(graphID: id, identity: identity))
        context.transactionAuthor = GraphSyncCheckpointAdapter.metadataAuthor
    })
}
