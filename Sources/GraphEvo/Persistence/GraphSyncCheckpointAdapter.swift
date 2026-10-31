import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Native PH discovery and atomic pending/checkpoint publication, confined to one writer context.
enum GraphSyncCheckpointAdapter {
    static let stateKey = GraphTypedStoreAdapter.prefix + "syncCheckpoint"
    static let localAuthor = "GraphEvo.v2.local"
    static let importAuthor = "GraphEvo.v2.import"
    static let metadataAuthor = "GraphEvo.v2.syncMetadata"
    private static let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    struct Checkpoint: Codable, Equatable {
        var format = 1
        let graphID: GraphID
        let storeID: String
        let epoch: UUID
        var token: Data?
        var transaction: Int64 = 0
        var pending: [GraphSyncChange] = []
    }
    struct Loaded {
        let root: Entity
        let original: Checkpoint?
        var state: Checkpoint
    }
    private struct OwnerGroup: Hashable {
        let transaction: Int
        let kind: String
        let relation: String
    }

    static func requirePurpose(_ context: NSManagedObjectContext, graphID: GraphID) throws {
        guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
              let store = coordinator.persistentStores.first,
              coordinator.metadata(for: store)[StoreNativeContext.historySyncGraphKey] as? String == graphID.rawValue.uuidString else {
            throw GraphSyncError.unavailable
        }
    }

    /// Reserve only for a newly created coordinated resource, never infer a prior mirror's purpose.
    static func reservePurpose(_ context: NSManagedObjectContext, graphID: GraphID) throws {
        guard let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first else { throw GraphSyncError.invalidState }
        var metadata = coordinator.metadata(for: store)
        guard metadata[StoreNativeContext.historySyncGraphKey] == nil else { throw GraphSyncError.invalidState }
        metadata[StoreNativeContext.historySyncGraphKey] = graphID.rawValue.uuidString
        coordinator.setMetadata(metadata, for: store)
    }

    static let adapter = GraphSyncAdapter(cloud: cloudAdapter, collect: { context, id, limits in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            try persist(context, value)
            return value.state.pending.count
        }
    }, prepare: { context, id, limits, maximum in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var items: [GraphSyncItem] = []
            for change in value.state.pending.sorted(by: ordered).prefix(maximum) {
                let record: GraphRecord?
                if change.operation == .save {
                    guard let found = try GraphNativeIdentityDatabaseAdapter.database.graph.fetch(context, id, change.id),
                          nativeKind(found.endpoints.kind) == change.nativeKind else { throw GraphSyncError.unresolvedChange }
                    record = found
                } else { record = nil }
                items.append(GraphSyncItem(change: change, record: record))
            }
            try persist(context, value)
            return GraphSyncPrepared(epoch: value.state.epoch, items: items)
        }
    }, acknowledge: { context, id, limits, epoch, sent in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            guard value.root[dynamicMember: transportKey] == nil else { throw GraphSyncError.unavailable }
            guard value.state.epoch == epoch else { throw GraphSyncError.staleBatch }
            try reconcile(context, value: &value, limits: limits)
            let receipts = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, $0) })
            let before = value.state.pending.count
            value.state.pending.removeAll { receipts[$0.id] == $0 }
            try persist(context, value)
            return before - value.state.pending.count
        }
    }, importPatches: { context, id, limits, patches in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            guard value.root[dynamicMember: transportKey] == nil else { throw GraphSyncError.unavailable }
            try reconcile(context, value: &value, limits: limits)
            let pending = Set(value.state.pending.map(\.id))
            var affected = Set<GraphNodeID>()
            for patch in patches {
                guard patch.id.graphID == id else { throw GraphStoreError.foreignGraph }
                affected.insert(patch.id)
                _ = try GraphNativeIdentityDatabaseAdapter.database.graph.patch(context, id, patch)
            }
            context.processPendingChanges()
            // Include inverse-node changes; conservative conflicts are preferable to overwriting pending work.
            for row in context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects) {
                if kinds.contains(row.entity.name ?? "") {
                    if let target = try identity(row, graphID: id) { affected.insert(target) }
                } else if row.entity.relationshipsByName["node"] != nil,
                          let owner = row.value(forKey: "node") as? NSManagedObject,
                          let target = try identity(owner, graphID: id) { affected.insert(target) }
            }
            guard pending.isDisjoint(with: affected) else { throw GraphSyncError.pendingImport }
            try persist(context, value)
            context.transactionAuthor = importAuthor
        }
    })

    private static func nativeKind(_ kind: GraphNodeKind) -> String {
        switch kind { case .entity: return ModelIdentifier.entityName; case .relationship: return ModelIdentifier.relationshipName; case .action: return ModelIdentifier.actionName }
    }

    static func ordered(_ a: GraphSyncChange, _ b: GraphSyncChange) -> Bool {
        if a.generation != b.generation { return a.generation < b.generation }
        return a.id.rawValue.uuidString < b.id.rawValue.uuidString
    }

    static func load(_ context: NSManagedObjectContext, id: GraphID, limits: GraphSyncLimits) throws -> Loaded {
        guard limits.maximumTransactions > 0, limits.maximumChanges > 0, limits.maximumPending > 0 else { throw GraphSyncError.invalidLimit }
        guard !(context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer),
              let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
              coordinator.managedObjectModel.versionIdentifiers == [AnyHashable(GraphRuntimeSchema.nativeModelIdentifier)],
              coordinator.managedObjectModel.entityVersionHashesByName == GraphRuntimeSchema.nativeIdentity.entityVersionHashes,
              let store = coordinator.persistentStores.first,
              let storeID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
              try GraphNativeIdentityDatabaseAdapter.database.catalog(context) == [id] else { throw GraphSyncError.invalidState }
        try requirePurpose(context, graphID: id)
        let graph = GraphTypedStoreAdapter.facade(context)
        let roots = Search<Entity>(graph: graph).where(.type(GraphTypedStoreAdapter.rootType)).sync()
        if let error = graph.snapshotReadError { throw error }
        guard roots.count == 1, let root = roots.first else { throw GraphSyncError.invalidState }
        let raw = root[dynamicMember: stateKey]
        let original: Checkpoint?
        if let raw {
            guard let bytes = raw as? Data else { throw GraphSyncError.invalidState }
            do { original = try JSONDecoder().decode(Checkpoint.self, from: bytes) }
            catch { throw GraphSyncError.invalidState }
        } else { original = nil }
        let state = original ?? Checkpoint(graphID: id, storeID: storeID, epoch: UUID())
        guard state.format == 1, state.graphID == id, state.storeID == storeID,
              state.transaction >= 0, (state.transaction == 0) == (state.token == nil),
              Set(state.pending.map(\.id)).count == state.pending.count,
              state.pending.allSatisfy({ $0.id.graphID == id && kinds.contains($0.nativeKind) && $0.generation > 0 && $0.generation <= state.transaction }) else {
            throw GraphSyncError.invalidState
        }
        guard state.pending.count <= limits.maximumPending else { throw GraphSyncError.pendingLimit }
        return Loaded(root: root, original: original, state: state)
    }

    static func persist(_ context: NSManagedObjectContext, _ value: Loaded) throws {
        guard value.original != value.state else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        value.root[dynamicMember: stateKey] = try encoder.encode(value.state)
        context.transactionAuthor = metadataAuthor
    }

    static func identity(_ row: NSManagedObject, graphID: GraphID) throws -> GraphNodeID? {
        guard let text = row.value(forKey: "ge2GraphID") as? String, text == graphID.rawValue.uuidString else { throw GraphStoreError.foreignGraph }
        guard let node = row.value(forKey: "ge2NodeID") else {
            guard let type = row.value(forKey: "type") as? String,
                  type == GraphTypedStoreAdapter.rootType || type == GraphTypedStoreAdapter.membersType else { throw GraphSyncError.unresolvedChange }
            return nil
        }
        guard let text = node as? String, let uuid = UUID(uuidString: text) else { throw GraphSyncError.unresolvedChange }
        return GraphNodeID(graphID: graphID, rawValue: uuid)
    }

    private static func detail(_ name: String) throws -> (kind: String, relation: String) {
        for (suffix, relation) in [("Property", "propertySet"), ("Tag", "tagSet"), ("Group", "groupSet")] where name.hasSuffix(suffix) {
            let owner = String(name.dropLast(suffix.count))
            guard kinds.contains(owner) else { break }
            return (owner, relation)
        }
        throw GraphSyncError.unresolvedChange
    }

    static func reconcile(_ context: NSManagedObjectContext, value: inout Loaded, limits: GraphSyncLimits) throws {
        let check = StoreNativeContext.cancellationCheck(in: context)
        // Tokens remain context-confined; only their secure Data representation is persisted/transferred.
        let token: NSPersistentHistoryToken?
        do { token = try value.state.token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0) } }
        catch { throw GraphSyncError.invalidState }
        if value.state.token != nil && token == nil { throw GraphSyncError.invalidState }
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        request.resultType = .transactionsAndChanges
        guard let fetch = NSPersistentHistoryTransaction.fetchRequest else { throw GraphSyncError.historyUnavailable }
        // Excluding bookkeeping at fetch avoids a checkpoint-write -> history -> checkpoint-write loop.
        fetch.predicate = NSPredicate(format: "author == nil OR author != %@", metadataAuthor)
        request.fetchRequest = fetch
        request.affectedStores = context.persistentStoreCoordinator?.persistentStores
        let transactions: [NSPersistentHistoryTransaction]
        do {
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let rows = result.result as? [NSPersistentHistoryTransaction] else { throw GraphSyncError.historyUnavailable }
            transactions = rows.sorted { $0.transactionNumber < $1.transactionNumber }
        } catch { throw GraphSyncError.historyUnavailable }
        guard transactions.count <= limits.maximumTransactions else { throw GraphSyncError.historyLimit }
        if value.original == nil && transactions.first?.transactionNumber != 1 { throw GraphSyncError.historyUnavailable }
        var count = 0
        for transaction in transactions {
            try check()
            guard transaction.author == localAuthor || transaction.author == importAuthor,
                  transaction.transactionNumber > value.state.transaction,
                  let changes = transaction.changes else { throw GraphSyncError.unknownAuthor }
            guard changes.count <= limits.maximumChanges - count else { throw GraphSyncError.historyLimit }
            count += changes.count
        }

        // Correlate a complete retained cut before reducing it; pages must not silently lose deleted owners.
        var ids: [NSManagedObjectID: GraphNodeID] = [:]
        var controls = Set<NSManagedObjectID>()
        var detailDeletes: [NSManagedObjectID: Int] = [:]
        for (index, transaction) in transactions.enumerated() {
            for change in transaction.changes ?? [] {
                try check()
                guard let name = change.changedObjectID.entity.name else { throw GraphSyncError.unresolvedChange }
                if kinds.contains(name), change.changeType == .delete {
                    guard let graph = change.tombstone?["ge2GraphID"] as? String,
                          graph == value.state.graphID.rawValue.uuidString else { throw GraphSyncError.unresolvedChange }
                    if let node = change.tombstone?["ge2NodeID"] {
                        guard let text = node as? String, let uuid = UUID(uuidString: text) else { throw GraphSyncError.unresolvedChange }
                        ids[change.changedObjectID] = GraphNodeID(graphID: value.state.graphID, rawValue: uuid)
                    } else { controls.insert(change.changedObjectID) }
                } else if !kinds.contains(name), change.changeType == .delete {
                    _ = try detail(name)
                    detailDeletes[change.changedObjectID] = index
                }
            }
        }
        for transaction in transactions {
            for change in transaction.changes ?? [] where kinds.contains(change.changedObjectID.entity.name ?? "") {
                try check()
                if ids[change.changedObjectID] != nil || controls.contains(change.changedObjectID) { continue }
                guard let row = try? context.existingObject(with: change.changedObjectID) else { throw GraphSyncError.unresolvedChange }
                if let id = try identity(row, graphID: value.state.graphID) { ids[change.changedObjectID] = id }
                else { controls.insert(change.changedObjectID) }
            }
        }
        var ownerGroups: [OwnerGroup: Set<GraphNodeID>] = [:]
        for (index, transaction) in transactions.enumerated() {
            for owner in transaction.changes ?? [] {
                guard let kind = owner.changedObjectID.entity.name, kinds.contains(kind) else { continue }
                let relations = ["propertySet", "tagSet", "groupSet"].filter { relation in
                    owner.changeType == .delete || owner.changeType == .insert ||
                        (owner.updatedProperties ?? []).contains { $0.name == relation }
                }
                for relation in relations {
                    let key = OwnerGroup(transaction: index, kind: kind, relation: relation)
                    if ownerGroups[key] == nil { ownerGroups[key] = [] }
                    if let id = ids[owner.changedObjectID] { ownerGroups[key]?.insert(id) }
                    else if !controls.contains(owner.changedObjectID) { throw GraphSyncError.unresolvedChange }
                }
            }
        }
        func groupOfDeletedDetail(_ change: NSPersistentHistoryChange) throws -> OwnerGroup {
            guard let index = detailDeletes[change.changedObjectID], let name = change.changedObjectID.entity.name else { throw GraphSyncError.unresolvedChange }
            let descriptor = try detail(name)
            let key = OwnerGroup(transaction: index, kind: descriptor.kind, relation: descriptor.relation)
            guard ownerGroups[key] != nil else { throw GraphSyncError.unresolvedChange }
            return key
        }
        var pending = Dictionary(uniqueKeysWithValues: value.state.pending.map { ($0.id, $0) })
        for transaction in transactions {
            var saves: [GraphNodeID: String] = [:], deletes: [GraphNodeID: String] = [:]
            var appliedGroups = Set<OwnerGroup>()
            for change in transaction.changes ?? [] {
                try check()
                guard let name = change.changedObjectID.entity.name else { throw GraphSyncError.unresolvedChange }
                if kinds.contains(name) {
                    if let id = ids[change.changedObjectID] {
                        if change.changeType == .delete { deletes[id] = name } else { saves[id] = name }
                    } else if !controls.contains(change.changedObjectID) { throw GraphSyncError.unresolvedChange }
                } else {
                    let descriptor = try detail(name)
                    if change.changeType != .delete, let row = try? context.existingObject(with: change.changedObjectID),
                       let owner = row.value(forKey: "node") as? NSManagedObject {
                        if let id = try identity(owner, graphID: value.state.graphID) { saves[id] = descriptor.kind }
                    } else {
                        let key = try groupOfDeletedDetail(change)
                        if appliedGroups.insert(key).inserted {
                            for id in ownerGroups[key] ?? [] { saves[id] = descriptor.kind }
                        }
                    }
                }
            }
            if transaction.author == importAuthor {
                guard Set(saves.keys).union(deletes.keys).isDisjoint(with: Set(pending.keys)) else { throw GraphSyncError.pendingImport }
            } else {
                for (id, kind) in saves { pending[id] = GraphSyncChange(id: id, nativeKind: kind, operation: .save, generation: transaction.transactionNumber) }
                for (id, kind) in deletes { pending[id] = GraphSyncChange(id: id, nativeKind: kind, operation: .delete, generation: transaction.transactionNumber) }
                guard pending.count <= limits.maximumPending else { throw GraphSyncError.pendingLimit }
            }
            value.state.transaction = transaction.transactionNumber
            value.state.token = try NSKeyedArchiver.archivedData(withRootObject: transaction.token, requiringSecureCoding: true)
        }
        value.state.pending = pending.values.sorted(by: ordered)
    }
}
