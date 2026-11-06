import CloudKit
import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

extension GraphSyncCheckpointAdapter {
    static let transportKey = GraphTypedStoreAdapter.prefix + "cloudTransport"
    private struct Transport: Codable {
        var format = 3
        let binding: GraphCloudTransportBinding
        let storeID: String
        let epoch: UUID
        var metadata: [String: Data] = [:]
        var attempt: GraphCloudOutgoingBatch?
        var sizeRejected: Set<String>?
        var receipts: [String: String] = [:]
        var zoneDeleted = false
    }
    static func existingCloudIdentity(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphCloudSessionIdentity? {
        let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
        guard let raw = root[dynamicMember: transportKey] else { return nil }
        guard let bytes = raw as? Data, bytes.count <= 32 * 1024 * 1024 else { throw GraphCloudError.invalidState }
        let candidate = try JSONDecoder().decode(Transport.self, from: bytes)
        let value = try load(context, id: id, limits: .init())
        return try loadTransport(value, binding: candidate.binding).binding.identity
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
        guard state.format == 3, state.binding == binding, state.storeID == value.state.storeID,
              state.epoch == value.state.epoch, state.metadata.count <= 100_000, state.receipts.count <= 4096,
              state.metadata.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              state.receipts.allSatisfy({ UUID(uuidString: $0.key)?.uuidString == $0.key && $0.value.utf8.count == 64 &&
                  $0.value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else { throw GraphCloudError.invalidState }
        if let rejected = state.sizeRejected {
            guard let attempt = state.attempt, !rejected.isEmpty,
                  rejected.isSubset(of: Set(attempt.items.map(\.recordName))) else { throw GraphCloudError.invalidState }
        }
        if let attempt = state.attempt {
            guard attempt.graphID == binding.route.graphID, attempt.zone == binding.route.zone, attempt.items.count <= GraphCloudBatchSizing.engineMaximumOperations,
                  Set(attempt.items.map { $0.change.id }).count == attempt.items.count else { throw GraphCloudError.invalidState }
        }
        if let attempt = state.attempt {
            for item in attempt.items {
                guard item.change.id.graphID == binding.route.graphID, item.change.generation > 0,
                      item.change.generation <= value.state.transaction,
                      item.recordName == (try GraphCloudNodeCodec.recordID(for: item.change.id, binding: binding.route)).recordName,
                      ["ManagedEntity", "ManagedRelationship", "ManagedAction"].contains(item.change.nativeKind) else { throw GraphCloudError.invalidState }
                if item.change.operation == .save {
                    if let reference = item.assetReference {
                        try reference.validate(role: .outgoing, identity: binding.identity, binding: binding.route,
                                               recordName: item.recordName, storeID: state.storeID, epoch: state.epoch)
                        guard let archive = item.recordArchive else { throw GraphCloudError.invalidState }
                        let native = try GraphCloudRecordCodec.restore(archive)
                        try GraphCloudNodeCodec.validateReferenceArchive(native, reference: reference, binding: binding.route)
                        guard item.change.nativeKind == "ManagedEntity" else { throw GraphCloudError.invalidState }
                    } else {
                        let record = try original(item, route: binding.route)
                        guard record.type != GraphAttachmentPayload.graphType else { throw GraphCloudError.invalidState }
                        guard record.id == item.change.id else { throw GraphCloudError.invalidState }
                        let kind: String
                        switch record.endpoints { case .file: throw GraphFileError.localOnly; case .entity: kind = "ManagedEntity"; case .relationship: kind = "ManagedRelationship"; case .action: kind = "ManagedAction" }
                        guard kind == item.change.nativeKind else { throw GraphCloudError.invalidState }
                    }
                } else { guard item.recordArchive == nil, item.assetReference == nil else { throw GraphCloudError.invalidState } }
            }
        }
        return state
    }
    private static func persistTransport(_ context: NSManagedObjectContext, root: Entity, state: Transport) throws {
        guard state.metadata.count <= 100_000, state.receipts.count <= 4096 else { throw GraphCloudError.inboxLimit }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        let deletedBytes = (root[dynamicMember: GraphMutationMetadata.deletedKey] as? Data)?.count ?? 0
        guard bytes.count <= 32 * 1024 * 1024 - deletedBytes else { throw GraphCloudError.inboxLimit }
        root[dynamicMember: transportKey] = bytes
        context.transactionAuthor = metadataAuthor
    }
    private static func original(_ item: GraphCloudOutgoingNode, route: GraphCloudBinding) throws -> GraphRecord {
        guard let bytes = item.recordArchive, let native = try? GraphCloudRecordCodec.restore(bytes) else { throw GraphCloudError.invalidState }
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
    private static func originalNode(_ item: GraphCloudOutgoingNode, route: GraphCloudBinding,
                                     resolvedAssets: [String: Data] = [:]) throws -> GraphCloudDecodedNode {
        guard let bytes = item.recordArchive, let native = try? GraphCloudRecordCodec.restore(bytes) else { throw GraphCloudError.invalidState }
        if item.assetReference != nil {
            guard let data = resolvedAssets[item.recordName] else { throw GraphCloudError.invalidState }
            native["asset"] = data as CKRecordValue
        }
        return try GraphCloudNodeCodec.decode(native, binding: route)
    }

    /// Decisions and effects are recomputed under the writer gate from current local state.
    private static func resolve(_ context: NSManagedObjectContext, value: inout Loaded, state: inout Transport,
                                events: [GraphNodeID: GraphCloudDecodedEvent]) throws -> GraphCloudResolution {
        let id = value.state.graphID, policy = try GraphMutationMetadata.policy(value.root)
        var deleted = try GraphMutationMetadata.deletedIDs(value.root)
        var result = GraphCloudResolution()
        let pending = Dictionary(uniqueKeysWithValues: value.state.pending.map { ($0.id, $0) })
        var saves: [GraphCloudDecodedNode] = [], removals = Set<GraphNodeID>(), cleared = Set<GraphNodeID>()
        let native = GraphNativeIdentityDatabaseAdapter.database.graph
        for (target, event) in events {
            guard target.graphID == id else { throw GraphCloudNodeError.foreignGraph }
            switch event {
            case .delete:
                removals.insert(target); cleared.insert(target); deleted.insert(target.rawValue.uuidString)
                if pending[target] != nil { result.resolved += 1 }
            case .save(let remote):
                if let metadata = state.metadata[target.rawValue.uuidString],
                   GraphCloudNodeCodec.sameServerVersion(try GraphCloudNodeCodec.changeTag(metadata, for: target, binding: state.binding.route),
                       try GraphCloudNodeCodec.changeTag(remote.systemFields, for: target, binding: state.binding.route)) { continue }
                if deleted.contains(target.rawValue.uuidString) || pending[target]?.operation == .delete {
                    deleted.insert(target.rawValue.uuidString)
                    if pending[target]?.operation == .delete { result.rebased.insert(target); result.resolved += 1 }
                    continue
                }
                state.metadata[target.rawValue.uuidString] = remote.systemFields
                if pending[target]?.operation == .save {
                    let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                    guard let node = try session.node(target) else { throw GraphSyncError.unresolvedChange }
                    if policy.prefersLocal(local: try GraphMutationMetadata.modifiedAt(node), remote: remote.modifiedAt) {
                        result.rebased.insert(target); result.resolved += 1; continue
                    }
                    cleared.insert(target); result.resolved += 1
                }
                saves.append(remote)
            case .zoneChanged, .zoneDeleted: throw GraphCloudError.invalidState
            }
        }
        for target in removals {
            if try native.fetch(context, id, target) != nil { try native.delete(context, id, target) }
            state.metadata.removeValue(forKey: target.rawValue.uuidString)
        }
        let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
        func rank(_ node: GraphCloudDecodedNode) -> Int {
            if node.record.type == GraphAttachmentPayload.graphType { return 2 }
            return node.record.endpoints.kind == .entity ? 0 : 1
        }
        for remote in saves.sorted(by: { rank($0) == rank($1) ? $0.record.id.rawValue.uuidString < $1.record.id.rawValue.uuidString : rank($0) < rank($1) }) {
            let record = remote.record
            if let old = try session.record(record.id) {
                guard old.type == record.type, old.endpoints.kind == record.endpoints.kind else { throw GraphCloudNodeError.invalidRecord }
                var changes = record.properties.mapValues { GraphPropertyChange.set($0) }
                for key in old.properties.keys where record.properties[key] == nil { changes[key] = .remove }
                _ = try session.patch(GraphRecordPatch(id: record.id, properties: changes,
                    addingTags: record.tags.subtracting(old.tags), removingTags: old.tags.subtracting(record.tags),
                    addingGroups: record.groups.subtracting(old.groups), removingGroups: old.groups.subtracting(record.groups), endpoints: record.endpoints))
            } else { try session.insert(record) }
            if let node = try session.node(record.id) {
                node.setImportedCreatedDate(record.createdDate)
                node[dynamicMember: GraphMutationMetadata.modifiedKey] = remote.modifiedAt
            }
        }
        context.processPendingChanges()
        let protected = Set(pending.keys).subtracting(cleared)
        guard protected.isDisjoint(with: try affected(context, id: id)) else { throw GraphSyncError.pendingImport }
        for row in context.deletedObjects where [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName].contains(row.entity.name ?? "") {
            if let target = try identity(row, graphID: id) { deleted.insert(target.rawValue.uuidString) }
        }
        value.state.pending.removeAll { cleared.contains($0.id) }
        result.pendingIDs = Set(value.state.pending.map(\.id))
        if result.resolved > 0 { state.attempt = nil; state.sizeRejected = nil }
        try GraphMutationMetadata.setDeletedIDs(deleted, root: value.root)
        _ = try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: id)
        return result
    }

    static let cloudAdapter = GraphCloudStoreAdapter(prepare: { context, id, binding, maximum, limits, onlyIDs in
        try GraphValueDecodingDiagnostics.checking {
            guard maximum > 0, maximum <= GraphCloudBatchSizing.engineMaximumOperations else { throw GraphCloudError.invalidConfiguration }
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var state = try loadTransport(value, binding: binding)
            guard !state.zoneDeleted else { throw GraphCloudError.zoneUnavailable }
            if !value.state.pending.isEmpty || state.attempt != nil {
                try GraphCloudAccessMetadata.requireConsumerWrite(context, id: id)
            }
            var previousAssets: [GraphCloudAssetReference] = []
            if let attempt = state.attempt, let rejected = state.sizeRejected {
                let pending = Dictionary(uniqueKeysWithValues: value.state.pending.map { ($0.id, $0.generation) })
                let remaining = attempt.items.filter {
                    !rejected.contains($0.recordName) || (pending[$0.change.id] ?? 0) <= $0.change.generation
                }
                if remaining.count != attempt.items.count {
                    // The old attempt still owns its files until the replacement transaction commits.
                    previousAssets = attempt.items.compactMap(\.assetReference)
                    let stillRejected = rejected.intersection(remaining.map(\.recordName))
                    state.sizeRejected = stillRejected.isEmpty ? nil : stillRejected
                    state.attempt = remaining.isEmpty ? nil : GraphCloudOutgoingBatch(id: attempt.id, graphID: id,
                                                                                       zone: attempt.zone, items: remaining)
                    try persist(context, value)
                    try persistTransport(context, root: value.root, state: state)
                }
            }
            if let attempt = state.attempt {
                return GraphCloudPreparedOutgoing(batch: attempt, storeID: state.storeID, epoch: state.epoch,
                                                  previousAssets: previousAssets)
            }
            var items: [GraphCloudOutgoingNode] = []
            var sizing = GraphCloudBatchSizing()
            var remainingAssetBytes = 32 * 1024 * 1024
            let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
            for change in value.state.pending.sorted(by: ordered).filter({ onlyIDs?.contains($0.id) ?? true }).prefix(maximum) {
                let record = change.operation == .save ? try session.record(change.id) : nil
                guard change.operation == .delete || record != nil else { throw GraphSyncError.unresolvedChange }
                if let record, record.type == GraphAttachmentPayload.graphType {
                    let count = try GraphAttachmentPayload(graphRecord: record).content.data.count
                    if count > remainingAssetBytes { break }
                    remainingAssetBytes -= count
                }
                let date = try session.node(change.id).flatMap { try GraphMutationMetadata.modifiedAt($0) }
                let item = try GraphCloudNodeCodec.encode(GraphSyncItem(change: change, record: record),
                    binding: binding.route, systemFields: state.metadata[change.id.rawValue.uuidString], modifiedAt: date)
                guard try sizing.append(GraphCloudBatchSizing.estimate(item, zone: binding.route.zone)) else { break }
                items.append(item)
            }
            let encoded = GraphCloudOutgoingBatch(id: UUID(), graphID: id, zone: binding.route.zone, items: items)
            // The provisional archive is detached; only the reference-only result is persisted in finishPrepared.
            try persist(context, value)
            return GraphCloudPreparedOutgoing(batch: encoded, storeID: state.storeID, epoch: state.epoch,
                                              previousAssets: previousAssets)
        }
    }, finishPrepared: { context, id, binding, batch, limits in
        let value = try load(context, id: id, limits: limits)
        var state = try loadTransport(value, binding: binding)
        if let old = state.attempt {
            guard old.id == batch.id, old.graphID == batch.graphID, old.zone == batch.zone,
                  old.items.count == batch.items.count,
                  zip(old.items, batch.items).allSatisfy({ $0.change == $1.change && $0.recordName == $1.recordName }) else {
                throw GraphCloudError.invalidState
            }
        } else {
            if batch.items.isEmpty {
                try persistTransport(context, root: value.root, state: state)
                return
            }
            let pending = Set(value.state.pending.map(\.id))
            guard batch.graphID == id, batch.zone == binding.route.zone,
                  Set(batch.items.map { $0.change.id }).count == batch.items.count,
                  batch.items.allSatisfy({ pending.contains($0.change.id) }) else { throw GraphCloudError.invalidState }
        }
        state.attempt = batch
        try persistTransport(context, root: value.root, state: state)
    }, currentAttempt: { context, id, binding, limits in
        let value = try load(context, id: id, limits: limits)
        let state = try loadTransport(value, binding: binding)
        return state.attempt.map { GraphCloudPreparedOutgoing(batch: $0, storeID: state.storeID, epoch: state.epoch) }
    }, sent: { context, id, binding, receipts, resolvedAssets, remoteAssets, limits in
        try GraphValueDecodingDiagnostics.checking {
            var value = try load(context, id: id, limits: limits)
            try reconcile(context, value: &value, limits: limits)
            var state = try loadTransport(value, binding: binding)
            guard Set(receipts.map(\.id)).count == receipts.count else { throw GraphCloudError.invalidState }
            var fresh: [(GraphCloudSentReceipt, String)] = []
            for receipt in receipts {
                let digest = try GraphCloudFingerprint.of(receipt)
                if let previous = state.receipts[receipt.id.uuidString] {
                    guard previous == digest else { throw GraphCloudError.invalidState }
                } else { fresh.append((receipt, digest)) }
            }
            if fresh.isEmpty {
                var result = GraphCloudResolution()
                result.pendingIDs = Set(value.state.pending.map(\.id))
                return result
            }
            guard let attempt = state.attempt else { throw GraphSyncError.staleBatch }
            let sent = Dictionary(uniqueKeysWithValues: attempt.items.map { ($0.recordName, $0) })
            var succeeded = Set<String>(), seen = Set<String>(), events: [GraphNodeID: GraphCloudDecodedEvent] = [:]
            var failures: [GraphCloudRecordFailure] = []
            for (receipt, _) in fresh {
                guard receipt.graphID == id, receipt.zone == binding.route.zone, receipt.batchID == attempt.id else { throw GraphSyncError.staleBatch }
                for incoming in receipt.saved {
                    guard incoming.zone == receipt.zone, let name = incoming.recordName, let item = sent[name], item.change.operation == .save,
                          case .save(let decoded) = try GraphCloudNodeCodec.decode(incoming, binding: binding.route,
                                                                                   assetData: remoteAssets[name]), seen.insert(name).inserted else { throw GraphCloudError.invalidState }
                    let original = try originalNode(item, route: binding.route, resolvedAssets: resolvedAssets)
                    guard decoded.record == original.record, decoded.modifiedAt == original.modifiedAt else { throw GraphCloudError.invalidState }
                    state.metadata[item.change.id.rawValue.uuidString] = decoded.systemFields; succeeded.insert(name)
                }
                for name in receipt.deletedNames {
                    guard let item = sent[name], item.change.operation == .delete, seen.insert(name).inserted else { throw GraphCloudError.invalidState }
                    state.metadata.removeValue(forKey: item.change.id.rawValue.uuidString); succeeded.insert(name)
                }
                for failure in receipt.failures {
                    guard let item = sent[failure.recordName], seen.insert(failure.recordName).inserted else { throw GraphCloudError.invalidState }
                    if failure.code == CKError.Code.serverRecordChanged.rawValue, item.change.operation == .save, let server = failure.serverRecord {
                        guard server.recordName == item.recordName, case .save(let remote) = try GraphCloudNodeCodec.decode(server, binding: binding.route,
                                                                                                                        assetData: remoteAssets[item.recordName]), remote.record.id == item.change.id else { throw GraphCloudError.invalidState }
                        events[item.change.id] = .save(remote)
                    } else if failure.code == CKError.Code.unknownItem.rawValue, item.change.operation == .save,
                              try GraphCloudNodeCodec.changeTag(originalNode(item, route: binding.route, resolvedAssets: resolvedAssets).systemFields, for: item.change.id, binding: binding.route) != nil {
                        events[item.change.id] = .delete(item.change.id)
                    } else { failures.append(failure) }
                }
            }
            let successes = Dictionary(uniqueKeysWithValues: succeeded.compactMap { sent[$0] }.map { ($0.change.id, $0.change) })
            value.state.pending.removeAll { successes[$0.id] == $0 }
            let remaining = attempt.items.filter { !succeeded.contains($0.recordName) }
            state.attempt = remaining.isEmpty ? nil : GraphCloudOutgoingBatch(id: attempt.id, graphID: id, zone: attempt.zone, items: remaining)
            var result = try resolve(context, value: &value, state: &state, events: events)
            result.failures = failures
            let rejected = (state.sizeRejected ?? []).union(failures.filter {
                $0.code == CKError.Code.limitExceeded.rawValue
            }.map(\.recordName)).intersection(state.attempt?.items.map(\.recordName) ?? [])
            state.sizeRejected = rejected.isEmpty ? nil : rejected
            for (receipt, digest) in fresh { state.receipts[receipt.id.uuidString] = digest }
            try persist(context, value); try persistTransport(context, root: value.root, state: state)
            if !events.isEmpty { context.transactionAuthor = importAuthor }
            return result
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
            if fresh.isEmpty { return GraphCloudResolution() }
            guard !state.zoneDeleted || fresh.allSatisfy({ if case .zoneDeleted = $0.event { return true }; return false }) else { throw GraphCloudError.zoneUnavailable }
            var latest: [GraphNodeID: GraphCloudDecodedEvent] = [:]
            for effect in fresh {
                switch effect.event {
                case .save(let decoded):
                    // Identities cannot be reused: deletion dominates even a later stale save in this cut.
                    if case .delete? = latest[decoded.record.id] { continue }
                    latest[decoded.record.id] = effect.event
                case .delete(let id): latest[id] = effect.event
                case .zoneChanged: break
                case .zoneDeleted: state.zoneDeleted = true
                }
            }
            let result = state.zoneDeleted ? GraphCloudResolution() : try resolve(context, value: &value, state: &state, events: latest)
            for effect in fresh { state.receipts[effect.id.uuidString] = effect.fingerprint }
            try persist(context, value); try persistTransport(context, root: value.root, state: state)
            context.transactionAuthor = importAuthor
            return result
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
