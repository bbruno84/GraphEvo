import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Final records are applied through the existing scoped facades; PH remains native and local-authored.
enum GraphMigrationNativePublication {
    static let receiptKey = GraphTypedStoreAdapter.prefix + "migrationPublication"
    static let adapter = GraphMigrationPublicationAdapter(snapshot: { context, descriptor, seal, limits in
        try limits.validate()
        guard seal.changes.count <= limits.maximumRecords else { throw GraphMigrationPublicationError.recordLimit }
        guard try GraphMigrationNativeWorkspace.adapter.inspect(context, descriptor,
            .init(maximumTransactions: 100_000, maximumNativeChanges: 1_000_000, maximumLogicalChanges: 100_000,
                  maximumEncodedBytes: 8 * 1024 * 1024)) == seal else { throw GraphMigrationWorkspaceError.invalidWorkspace }
        let session = try GraphTypedStoreAdapter.Session(context, descriptor.graphID, database: true)
        var remaining = limits.maximumPayloadBytes
        return try seal.changes.map { change in
            try StoreNativeContext.cancellationCheck(in: context)()
            let record: GraphRecord?, modified: Date?
            if change.operation == .save {
                guard let node = try session.node(change.id) else { throw GraphStoreError.missingNode }
                record = try session.snapshot(node, id: change.id); modified = try GraphMutationMetadata.modifiedAt(node)
            } else { record = nil; modified = nil }
            do {
                try GraphQueryStoredCost.charge(64, remaining: &remaining)
                if let record {
                    try GraphQueryStoredCost.charge(record.type.utf8.count, remaining: &remaining)
                    try GraphQueryStoredCost.charge(.object(record.properties), remaining: &remaining)
                    for text in record.tags { try GraphQueryStoredCost.charge(text.utf8.count, remaining: &remaining) }
                    for text in record.groups { try GraphQueryStoredCost.charge(text.utf8.count, remaining: &remaining) }
                    switch record.endpoints {
                    case .entity: break
                    case .relationship: try GraphQueryStoredCost.charge(64, remaining: &remaining)
                    case .action(let subjects, let objects):
                        for _ in subjects { try GraphQueryStoredCost.charge(32, remaining: &remaining) }
                        for _ in objects { try GraphQueryStoredCost.charge(32, remaining: &remaining) }
                    }
                }
            } catch { throw GraphMigrationPublicationError.payloadLimit }
            return GraphMigrationPublicationItem(change: change, record: record, modifiedAt: modified)
        }
    }, receipt: { context, id, workspace in
        guard let value = try receipt(context, id: id), value.workspaceID == workspace else { return nil }
        return value
    }, preflight: { context, descriptor, seal in
        try preflight(context, descriptor: descriptor, seal: seal)
    }, apply: { context, descriptor, seal, intent, items in
        try GraphValueDecodingDiagnostics.checking {
            try intent.validate(seal)
            if let existing = try receipt(context, id: descriptor.graphID), existing.workspaceID == descriptor.id {
                try existing.validate(seal, storeID: descriptor.source.storeID)
                guard existing.backupID == intent.backupID else { throw GraphMigrationPublicationError.receiptConflict }
                return existing
            }
            try preflight(context, descriptor: descriptor, seal: seal)
            guard items.map(\.change) == seal.changes else { throw GraphMigrationPublicationError.invalidIntent }
            let id = descriptor.graphID
            let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
            GraphMutationMetadata.begin(context)
            func rank(_ item: GraphMigrationPublicationItem) -> Int {
                guard let record = item.record else { return 0 }
                return record.type == GraphAttachmentPayload.graphType ? 2 : (record.endpoints.kind == .entity ? 0 : 1)
            }
            let saves = items.filter { $0.change.operation == .save }
            for item in saves.sorted(by: { rank($0) == rank($1) ? $0.change.id.rawValue.uuidString < $1.change.id.rawValue.uuidString : rank($0) < rank($1) }) {
                try StoreNativeContext.cancellationCheck(in: context)()
                guard let record = item.record, record.id == item.change.id else { throw GraphMigrationPublicationError.invalidIntent }
                if let current = try session.record(record.id) {
                    guard current.type == record.type, current.endpoints.kind == record.endpoints.kind else { throw GraphMigrationPublicationError.unsupportedStructure }
                    var properties = record.properties.mapValues { GraphPropertyChange.set($0) }
                    for key in current.properties.keys where record.properties[key] == nil { properties[key] = .remove }
                    _ = try session.patch(GraphRecordPatch(id: record.id, properties: properties,
                        addingTags: record.tags.subtracting(current.tags), removingTags: current.tags.subtracting(record.tags),
                        addingGroups: record.groups.subtracting(current.groups), removingGroups: current.groups.subtracting(record.groups),
                        endpoints: record.endpoints))
                } else { try session.insert(record) }
                guard let node = try session.node(record.id) else { throw GraphStoreError.missingNode }
                node.setImportedCreatedDate(record.createdDate)
            }
            // Surviving actions/edges have their final endpoints before old entities are removed.
            let deletes = items.filter { $0.change.operation == .delete }
            for item in deletes.sorted(by: { ($0.change.kind == .entity ? 1 : 0) < ($1.change.kind == .entity ? 1 : 0) }) {
                try StoreNativeContext.cancellationCheck(in: context)()
                if try session.node(item.change.id) != nil { try session.delete(item.change.id) }
            }
            try GraphMutationMetadata.finish(context, graphID: id, clock: { Date() })
            for item in saves {
                guard let node = try session.node(item.change.id) else { throw GraphMigrationPublicationError.unsupportedStructure }
                node[dynamicMember: GraphMutationMetadata.modifiedKey] = item.modifiedAt
                guard try session.snapshot(node, id: item.change.id) == item.record else { throw GraphMigrationPublicationError.unsupportedStructure }
            }
            context.processPendingChanges()
            let allowed = Set(items.map { $0.change.id })
            for row in context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects) {
                let owner: NSManagedObject?
                if [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName].contains(row.entity.name ?? "") { owner = row }
                else if row.entity.relationshipsByName["node"] != nil { owner = row.value(forKey: "node") as? NSManagedObject }
                else { owner = nil }
                if let owner, let changed = try GraphSyncCheckpointAdapter.identity(owner, graphID: id), !allowed.contains(changed) {
                    throw GraphMigrationPublicationError.unsupportedStructure
                }
            }
            try GraphCoordinatorFactory.validateGraph(context, id: id)
            let result = GraphMigrationPublicationReceipt(intent: intent, storeID: descriptor.source.storeID)
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            let data = try JSONEncoder().encode(result)
            guard data.count <= 4096 else { throw GraphMigrationPublicationError.invalidIntent }
            root[dynamicMember: receiptKey] = data
            context.processPendingChanges()
            guard context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects).count <= GraphSyncLimits().maximumChanges else {
                throw GraphSyncError.historyLimit
            }
            context.transactionAuthor = GraphSyncCheckpointAdapter.localAuthor
            return result
        }
    })

    private static func receipt(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphMigrationPublicationReceipt? {
        try GraphValueDecodingDiagnostics.checking {
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            guard root.node.propertySet.contains(where: { $0.name == receiptKey }) else { return nil }
            guard let data = root[dynamicMember: receiptKey] as? Data, data.count <= 4096,
                  let result = try? JSONDecoder().decode(GraphMigrationPublicationReceipt.self, from: data),
                  result.format == 1, result.graphID == id, result.selectedChanges >= 0, result.selectedChanges <= 100_000,
                  result.sealDigest.utf8.count == 64, result.sealDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first,
                  coordinator.metadata(for: store)[NSStoreUUIDKey] as? String == result.storeID else {
                throw GraphMigrationPublicationError.receiptConflict
            }
            return result
        }
    }
    private static func preflight(_ context: NSManagedObjectContext, descriptor: GraphMigrationWorkspaceDescriptor, seal: GraphMigrationChangeSet) throws {
        try GraphValueDecodingDiagnostics.checking {
            try GraphSyncCheckpointAdapter.requirePurpose(context, graphID: descriptor.graphID)
            try GraphMigrationNativeWorkspace.adapter.validateSource(context, descriptor.graphID, descriptor.source)
            try GraphCloudAccessMetadata.requireConsumerWrite(context, id: descriptor.graphID)
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: descriptor.graphID)
            guard try GraphCloudAccessMetadata.read(root) == nil else { throw GraphMigrationWorkspaceError.participantUnsupported }
            for key in [GraphSyncCheckpointAdapter.stateKey, GraphSyncCheckpointAdapter.transportKey, GraphMutationMetadata.policyKey] {
                if root.node.propertySet.contains(where: { $0.name == key }), root[dynamicMember: key] == nil { throw GraphSyncError.invalidState }
            }
            _ = try GraphMutationMetadata.policy(root)
            var pending = try GraphSyncCheckpointAdapter.load(context, id: descriptor.graphID, limits: .init())
            try GraphSyncCheckpointAdapter.reconcile(context, value: &pending, limits: .init())
            let projected = Set(pending.state.pending.map(\.id)).union(seal.changes.map(\.id))
            guard projected.count <= GraphSyncLimits().maximumPending else { throw GraphSyncError.pendingLimit }
            var deleted = try GraphMutationMetadata.deletedIDs(root)
            deleted.formUnion(seal.changes.filter { $0.operation == .delete }.map { $0.id.rawValue.uuidString })
            guard deleted.count <= 100_000 else { throw GraphSyncError.pendingLimit }
        }
    }
}
