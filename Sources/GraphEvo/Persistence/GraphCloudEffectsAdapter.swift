import CloudKit
import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

extension GraphSyncCheckpointAdapter {
    static let transportKey = GraphTypedStoreAdapter.prefix + "cloudTransport"
    private struct Transport: Codable {
        var format = 1
        let binding: GraphCloudTransportBinding
        let storeID: String
        let epoch: UUID
        var metadata: [String: Data] = [:]
        var attempt: GraphCloudOutgoingBatch?
        var receipts: [String: String] = [:]
        var zoneDeleted = false
    }
    private static func loadTransport(_ value: Loaded, binding: GraphCloudTransportBinding) throws -> Transport {
        guard !binding.identity.container.isEmpty, !binding.identity.account.isEmpty,
              !binding.route.zone.name.isEmpty, !binding.route.zone.owner.isEmpty else { throw GraphCloudError.invalidState }
        guard binding.route.graphID == value.state.graphID else { throw GraphCloudNodeError.foreignGraph }
        let state: Transport
        if let raw = value.root[dynamicMember: transportKey] {
            guard let bytes = raw as? Data, bytes.count <= 32 * 1024 * 1024 else { throw GraphCloudError.invalidState }
            do { state = try JSONDecoder().decode(Transport.self, from: bytes) }
            catch { throw GraphCloudError.invalidState }
        } else { state = Transport(binding: binding, storeID: value.state.storeID, epoch: value.state.epoch) }
        guard state.format == 1, state.binding == binding, state.storeID == value.state.storeID,
              state.epoch == value.state.epoch, state.metadata.count <= 100_000, state.receipts.count <= 4096,
              state.metadata.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              state.receipts.allSatisfy({ UUID(uuidString: $0.key)?.uuidString == $0.key && $0.value.utf8.count == 64 &&
                  $0.value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else { throw GraphCloudError.invalidState }
        if let attempt = state.attempt {
            guard attempt.graphID == binding.route.graphID, attempt.zone == binding.route.zone, attempt.items.count <= 100,
                  Set(attempt.items.map { $0.change.id }).count == attempt.items.count else { throw GraphCloudError.invalidState }
        }
        if let attempt = state.attempt {
            for item in attempt.items {
                guard item.change.id.graphID == binding.route.graphID, item.change.generation > 0,
                      item.change.generation <= value.state.transaction,
                      item.recordName == (try GraphCloudNodeCodec.recordID(for: item.change.id, binding: binding.route)).recordName,
                      ["ManagedEntity", "ManagedRelationship", "ManagedAction"].contains(item.change.nativeKind) else { throw GraphCloudError.invalidState }
                if item.change.operation == .save {
                    let record = try original(item, route: binding.route)
                    guard record.id == item.change.id else { throw GraphCloudError.invalidState }
                    let kind: String
                    switch record.endpoints { case .entity: kind = "ManagedEntity"; case .relationship: kind = "ManagedRelationship"; case .action: kind = "ManagedAction" }
                    guard kind == item.change.nativeKind else { throw GraphCloudError.invalidState }
                } else { guard item.recordArchive == nil else { throw GraphCloudError.invalidState } }
            }
        }
        return state
    }
    private static func persistTransport(_ context: NSManagedObjectContext, root: Entity, state: Transport) throws {
        guard state.metadata.count <= 100_000, state.receipts.count <= 4096 else { throw GraphCloudError.inboxLimit }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        guard bytes.count <= 32 * 1024 * 1024 else { throw GraphCloudError.inboxLimit }
        root[dynamicMember: transportKey] = bytes
        context.transactionAuthor = metadataAuthor
    }
    private static func original(_ item: GraphCloudOutgoingNode, route: GraphCloudBinding) throws -> GraphRecord {
        guard let bytes = item.recordArchive, let native = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes) else { throw GraphCloudError.invalidState }
        return try GraphCloudNodeCodec.decode(native, binding: route).record
    }
    private static func affected(_ context: NSManagedObjectContext, id: GraphID) throws -> Set<GraphNodeID> {
        var result = Set<GraphNodeID>()
        for row in context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects) {
            if [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName].contains(row.entity.name ?? "") {
                if let value = try identity(row, graphID: id) { result.insert(value) }
            } else if row.entity.relationshipsByName["node"] != nil, let owner = row.value(forKey: "node") as? NSManagedObject,
                      let value = try identity(owner, graphID: id) { result.insert(value) }
        }
        return result
    }
    static let cloudAdapter = GraphCloudStoreAdapter(prepare: { context, id, binding, maximum, limits in
        try GraphValueDecodingDiagnostics.checking {
            guard maximum > 0, maximum <= 100 else { throw GraphCloudError.invalidConfiguration }
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var state = try loadTransport(value, binding: binding)
            guard !state.zoneDeleted else { throw GraphCloudError.zoneUnavailable }
            if let attempt = state.attempt { return attempt }
            var items: [GraphSyncItem] = []
            for change in value.state.pending.sorted(by: ordered).prefix(maximum) {
                let record = change.operation == .save ? try GraphNativeIdentityDatabaseAdapter.database.graph.fetch(context, id, change.id) : nil
                guard change.operation == .delete || record != nil else { throw GraphSyncError.unresolvedChange }
                items.append(GraphSyncItem(change: change, record: record))
            }
            let batch = GraphSyncBatch(id: UUID(), graphID: id, items: items, epoch: value.state.epoch)
            let metadata = Dictionary(uniqueKeysWithValues: state.metadata.map { (GraphNodeID(graphID: id, rawValue: UUID(uuidString: $0.key)!), $0.value) })
            let encoded = try GraphCloudNodeCodec.encode(batch, binding: binding.route, systemFields: metadata)
            if !encoded.items.isEmpty { state.attempt = encoded }
            try persist(context, value)
            try persistTransport(context, root: value.root, state: state)
            return encoded
        }
    }, sent: { context, id, binding, receipt, limits in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var state = try loadTransport(value, binding: binding)
            let digest = try GraphCloudFingerprint.of(receipt), key = receipt.id.uuidString
            if let previous = state.receipts[key] {
                guard previous == digest else { throw GraphCloudError.invalidState }; return
            }
            guard receipt.graphID == id, receipt.zone == binding.route.zone,
                  let attempt = state.attempt, attempt.id == receipt.batchID else { throw GraphSyncError.staleBatch }
            let sent = Dictionary(uniqueKeysWithValues: attempt.items.map { ($0.recordName, $0) })
            var succeeded = Set<String>()
            for incoming in receipt.saved {
                guard incoming.zone == receipt.zone, let name = incoming.recordName,
                      let item = sent[name], item.change.operation == .save,
                      case .save(let decoded) = try GraphCloudNodeCodec.decode(incoming, binding: binding.route),
                      decoded.record == (try original(item, route: binding.route)), succeeded.insert(name).inserted else { throw GraphCloudError.invalidState }
                state.metadata[item.change.id.rawValue.uuidString] = decoded.systemFields
            }
            for name in receipt.deletedNames {
                guard let item = sent[name], item.change.operation == .delete, succeeded.insert(name).inserted else { throw GraphCloudError.invalidState }
                state.metadata.removeValue(forKey: item.change.id.rawValue.uuidString)
            }
            guard Set(receipt.failures.map(\.recordName)).count == receipt.failures.count,
                  receipt.failures.allSatisfy({ sent[$0.recordName] != nil && !succeeded.contains($0.recordName) }) else { throw GraphCloudError.invalidState }
            let successes = Dictionary(uniqueKeysWithValues: succeeded.compactMap { sent[$0] }.map { ($0.change.id, $0.change) })
            value.state.pending.removeAll { successes[$0.id] == $0 }
            let remaining = attempt.items.filter { !succeeded.contains($0.recordName) }
            state.attempt = remaining.isEmpty ? nil : GraphCloudOutgoingBatch(id: attempt.id, graphID: id, zone: attempt.zone, items: remaining)
            state.receipts[key] = digest
            try persist(context, value)
            try persistTransport(context, root: value.root, state: state)
        }
    }, apply: { context, id, binding, effects, limits in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var state = try loadTransport(value, binding: binding)
            guard Set(effects.map(\.id)).count == effects.count, effects.allSatisfy({ $0.route == binding.route }) else { throw GraphCloudError.invalidState }
            var fresh: [GraphCloudEffect] = []
            for effect in effects {
                if let digest = state.receipts[effect.id.uuidString] {
                    guard digest == effect.fingerprint else { throw GraphCloudError.invalidState }
                } else { fresh.append(effect) }
            }
            if fresh.isEmpty { return }
            guard !state.zoneDeleted || fresh.allSatisfy({ if case .zoneDeleted = $0.event { return true }; return false }) else { throw GraphCloudError.zoneUnavailable }
            let pending = Set(value.state.pending.map(\.id))
            var latest: [GraphNodeID: GraphCloudDecodedEvent] = [:]
            for effect in fresh {
                switch effect.event {
                case .save(let decoded): latest[decoded.record.id] = effect.event
                case .delete(let deleted): latest[deleted] = effect.event
                case .zoneChanged: break
                case .zoneDeleted: state.zoneDeleted = true
                }
            }
            for (target, event) in latest {
                if case .save(let decoded) = event, let metadata = state.metadata[target.rawValue.uuidString] {
                    let previous = try GraphCloudNodeCodec.changeTag(metadata, for: target, binding: binding.route)
                    let incoming = try GraphCloudNodeCodec.changeTag(decoded.systemFields, for: target, binding: binding.route)
                    if GraphCloudNodeCodec.sameServerVersion(previous, incoming) { latest.removeValue(forKey: target) }
                }
            }
            guard Set(latest.keys).isDisjoint(with: pending) else { throw GraphSyncError.pendingImport }
            guard latest.keys.allSatisfy({ $0.graphID == id }) else { throw GraphCloudNodeError.foreignGraph }
            if !state.zoneDeleted {
                let native = GraphNativeIdentityDatabaseAdapter.database.graph
                for (target, event) in latest {
                    if case .delete = event {
                        if try native.fetch(context, id, target) != nil { try native.delete(context, id, target) }
                        state.metadata.removeValue(forKey: target.rawValue.uuidString)
                    }
                }
                let saves = latest.values.compactMap { event -> GraphCloudDecodedNode? in if case .save(let node) = event { return node }; return nil }
                    .sorted { a, b in
                        func rank(_ endpoints: GraphEndpoints) -> Int { switch endpoints { case .entity: return 0; case .relationship: return 1; case .action: return 2 } }
                        let ar = rank(a.record.endpoints), br = rank(b.record.endpoints)
                        return ar == br ? a.record.id.rawValue.uuidString < b.record.id.rawValue.uuidString : ar < br
                    }
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                for decoded in saves {
                    let record = decoded.record
                    if let old = try session.record(record.id) {
                        guard old.type == record.type, old.endpoints.kind == record.endpoints.kind else { throw GraphCloudNodeError.invalidRecord }
                        var changes = record.properties.mapValues { GraphPropertyChange.set($0) }
                        for key in old.properties.keys where record.properties[key] == nil { changes[key] = .remove }
                        _ = try session.patch(GraphRecordPatch(id: record.id, properties: changes,
                            addingTags: record.tags.subtracting(old.tags), removingTags: old.tags.subtracting(record.tags),
                            addingGroups: record.groups.subtracting(old.groups), removingGroups: old.groups.subtracting(record.groups), endpoints: record.endpoints))
                    } else { try session.insert(record) }
                    try session.node(record.id)?.setImportedCreatedDate(record.createdDate)
                    state.metadata[record.id.rawValue.uuidString] = decoded.systemFields
                }
                context.processPendingChanges()
                guard pending.isDisjoint(with: try affected(context, id: id)) else { throw GraphSyncError.pendingImport }
                _ = try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: id)
            }
            for effect in fresh { state.receipts[effect.id.uuidString] = effect.fingerprint }
            try persist(context, value)
            try persistTransport(context, root: value.root, state: state)
            context.transactionAuthor = importAuthor
        }
    }, trim: { context, id, binding, cleanup in
        try GraphValueDecodingDiagnostics.checking {
            let value = try load(context, id: id, limits: .init())
            guard value.root[dynamicMember: transportKey] != nil else { return }
            var state = try loadTransport(value, binding: binding)
            let previous = state.receipts
            switch cleanup {
            case .consumed(let ids): for receipt in ids { state.receipts.removeValue(forKey: receipt.uuidString) }
            case .retain(let ids): state.receipts = state.receipts.filter { key, _ in ids.contains(UUID(uuidString: key)!) }
            }
            if previous != state.receipts { try persistTransport(context, root: value.root, state: state) }
        }
    })
}
