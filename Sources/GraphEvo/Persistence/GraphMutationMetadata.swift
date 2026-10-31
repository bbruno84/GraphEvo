import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

/// Scope-confined tracking; imports and bookkeeping never install this tracker.
enum GraphMutationMetadata {
    static let modifiedKey = GraphTypedStoreAdapter.prefix + "modifiedAt"
    static let policyKey = GraphTypedStoreAdapter.prefix + "conflictPolicy"
    static let deletedKey = GraphTypedStoreAdapter.prefix + "deletedNodeIDs"
    private static let trackerKey = "GraphEvo.consumerMutation"
    private final class Tracker {
        var touched: [GraphNodeID: Node] = [:]
        var deleted = Set<GraphNodeID>()
    }
    static func begin(_ context: NSManagedObjectContext) { context.userInfo[trackerKey] = Tracker() }
    static func touch(_ context: NSManagedObjectContext, _ node: Node, id: GraphNodeID) {
        (context.userInfo[trackerKey] as? Tracker)?.touched[id] = node
    }
    static func deleted(_ context: NSManagedObjectContext, id: GraphNodeID) {
        (context.userInfo[trackerKey] as? Tracker)?.deleted.insert(id)
    }
    static func isDeleted(_ context: NSManagedObjectContext, id: GraphNodeID) -> Bool {
        (context.userInfo[trackerKey] as? Tracker)?.deleted.contains(id) == true
    }
    static func finish(_ context: NSManagedObjectContext, graphID: GraphID, clock: @Sendable () -> Date) throws {
        guard let tracker = context.userInfo[trackerKey] as? Tracker else { return }
        context.userInfo.removeObject(forKey: trackerKey)
        if !tracker.touched.isEmpty {
            let date = clock()
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw GraphSyncError.invalidState }
            for (id, node) in tracker.touched where !tracker.deleted.contains(id) {
                node[dynamicMember: modifiedKey] = date
            }
        }
        if !tracker.deleted.isEmpty {
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: graphID)
            var ids = try deletedIDs(root)
            ids.formUnion(tracker.deleted.map { $0.rawValue.uuidString })
            try setDeletedIDs(ids, root: root)
        }
    }
    static func modifiedAt(_ node: Node) throws -> Date? {
        guard let raw = node[dynamicMember: modifiedKey] else { return nil }
        guard let date = raw as? Date, date.timeIntervalSinceReferenceDate.isFinite else { throw GraphSyncError.invalidState }
        return date
    }
    static func policy(_ root: Entity) throws -> GraphConflictPolicy {
        guard let raw = root[dynamicMember: policyKey] else { return .lastEditWins }
        guard let text = raw as? String, let value = GraphConflictPolicy(rawValue: text) else { throw GraphSyncError.invalidState }
        return value
    }
    static func deletedIDs(_ root: Entity) throws -> Set<String> {
        guard let raw = root[dynamicMember: deletedKey] else { return [] }
        guard let bytes = raw as? Data, bytes.count <= 32 * 1024 * 1024,
              let ids = try? JSONDecoder().decode([String].self, from: bytes), ids.count <= 100_000,
              Set(ids).count == ids.count, ids.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }) else { throw GraphSyncError.invalidState }
        return Set(ids)
    }
    static func setDeletedIDs(_ ids: Set<String>, root: Entity) throws {
        guard ids.count <= 100_000 else { throw GraphSyncError.pendingLimit }
        let bytes = try JSONEncoder().encode(ids.sorted())
        if (root[dynamicMember: deletedKey] as? Data) == bytes || (ids.isEmpty && root[dynamicMember: deletedKey] == nil) { return }
        let transportBytes = (root[dynamicMember: GraphSyncCheckpointAdapter.transportKey] as? Data)?.count ?? 0
        guard bytes.count <= 32 * 1024 * 1024 - transportBytes else { throw GraphSyncError.pendingLimit }
        root[dynamicMember: deletedKey] = bytes
    }
}
