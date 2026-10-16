import CloudKit
import CoreData

/// Misuse or unavailable infrastructure, distinct from a normally absent CloudKit mapping.
public enum GraphCloudRecordIdentityError: Error, Equatable, LocalizedError {
    case unavailableContext
    case foreignContext
    case unavailableContainer
    case inconsistentContainer

    public var errorDescription: String? {
        switch self {
        case .unavailableContext: return "The graph or node context is unavailable."
        case .foreignContext: return "The node belongs to a different Graph context."
        case .unavailableContainer: return "The persistent container is unavailable for identity lookup."
        case .inconsistentContainer: return "The node store and Graph container do not match."
        }
    }
}

internal protocol GraphCloudRecordIDReading {
    func recordIDs(for ids: [NSManagedObjectID], in container: NSPersistentCloudKitContainer) -> [NSManagedObjectID: CKRecord.ID]
}

internal struct AppleGraphCloudRecordIDReader: GraphCloudRecordIDReading {
    func recordIDs(for ids: [NSManagedObjectID], in container: NSPersistentCloudKitContainer) -> [NSManagedObjectID: CKRecord.ID] {
        container.recordIDs(for: ids)
    }
}

public extension Graph {
    /// Returns the main node's complete CloudKit record identity, when currently available.
    /// Call on this Graph's context queue with a node belonging to that context.
    /// This does not save, obtain permanent IDs, request export, or cache results.
    func cloudRecordID(for node: Node) throws -> CKRecord.ID? {
        try cloudRecordIDs(for: [node])[0]
    }

    /// Returns one optional identity per input node, preserving order and duplicates.
    /// Empty input returns an empty array. Invalid input fails the entire lookup.
    /// Local/fallback stores, unsaved or pending-deletion nodes, and missing mappings return nil.
    /// In a readSnapshot, CloudKit metadata is not promised to share the pinned data generation.
    /// Record identity does not certify export or synchronization completion. Container,
    /// environment, database and account remain external context for comparing identities.
    func cloudRecordIDs(for nodes: [Node]) throws -> [CKRecord.ID?] {
        guard !nodes.isEmpty else { return [] }
        guard let context = managedObjectContext else { throw GraphCloudRecordIdentityError.unavailableContext }
        return try context.performAndWait {
            // Validate all inputs, including on local stores, before returning absent mappings.
            for node in nodes {
                guard let owner = node.node.managedObjectContext else { throw GraphCloudRecordIdentityError.unavailableContext }
                guard owner === context else { throw GraphCloudRecordIdentityError.foreignContext }
            }
            guard let coordinator = context.persistentStoreCoordinator, !coordinator.persistentStores.isEmpty else {
                throw GraphCloudRecordIdentityError.unavailableContext
            }
            guard let container = persistentContainer ?? scopedIdentityContainer else {
                throw GraphCloudRecordIdentityError.unavailableContainer
            }
            guard container.persistentStoreCoordinator === coordinator else {
                throw GraphCloudRecordIdentityError.inconsistentContainer
            }
            for node in nodes where !node.node.objectID.isTemporaryID {
                guard let store = node.node.objectID.persistentStore,
                      coordinator.persistentStores.contains(where: { $0 === store }) else {
                    throw GraphCloudRecordIdentityError.inconsistentContainer
                }
            }
            let absent = [CKRecord.ID?](repeating: nil, count: nodes.count)
            guard let cloud = container as? NSPersistentCloudKitContainer else { return absent }
            let ids = nodes.map { node -> NSManagedObjectID? in
                let object = node.node
                guard !object.isInserted, !object.isDeleted, !object.objectID.isTemporaryID else { return nil }
                return object.objectID
            }
            let requested = Array(Set(ids.compactMap { $0 }))
            guard !requested.isEmpty else { return absent }
            let mapping = cloudRecordIDReader.recordIDs(for: requested, in: cloud)
            return ids.map { $0.flatMap { mapping[$0] } }
        }
    }
}
