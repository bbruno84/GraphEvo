import CoreData
import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel
import os

package struct GraphCloudSessionIdentity: Codable, Equatable, Sendable {
    package let container: String
    package let environment: GraphCloudEnvironment
    package let account: String
    package init(container: String, environment: GraphCloudEnvironment, account: String) {
        self.container = container; self.environment = environment; self.account = account
    }
}
package struct GraphCloudTransportBinding: Codable, Equatable, Sendable {
    package let identity: GraphCloudSessionIdentity
    package let route: GraphCloudBinding
    package init(identity: GraphCloudSessionIdentity, route: GraphCloudBinding) { self.identity = identity; self.route = route }
}
package struct GraphCloudRecordFailure: Codable, Equatable, Sendable {
    package let recordName: String
    package let code: Int
    package let serverRecord: GraphCloudIncoming?
    package init(recordName: String, code: Int, serverRecord: GraphCloudIncoming? = nil) {
        self.recordName = recordName; self.code = code; self.serverRecord = serverRecord
    }
}
package struct GraphCloudSentReceipt: Codable, Equatable, Sendable {
    var membershipGeneration: UUID? = nil
    package let id: UUID
    package let batchID: UUID
    package let graphID: GraphID
    package let zone: GraphCloudZone
    package let saved: [GraphCloudIncoming]
    package let deletedNames: [String]
    package let failures: [GraphCloudRecordFailure]
    package init(id: UUID = UUID(), batchID: UUID, graphID: GraphID, zone: GraphCloudZone,
                 saved: [GraphCloudIncoming], deletedNames: [String], failures: [GraphCloudRecordFailure]) {
        self.id = id; self.batchID = batchID; self.graphID = graphID; self.zone = zone
        self.saved = saved; self.deletedNames = deletedNames; self.failures = failures
    }
}
package struct GraphCloudEffect: Sendable {
    package let id: UUID
    package let fingerprint: String
    package let route: GraphCloudBinding
    package let event: GraphCloudDecodedEvent
    package init(_ entry: GraphCloudInboxEntry, binding: GraphCloudBinding, assetData: Data? = nil) throws {
        id = entry.id; fingerprint = try GraphCloudFingerprint.of(entry); route = binding
        event = try GraphCloudNodeCodec.decode(entry.change, binding: binding, assetData: assetData)
    }
}
package struct GraphCloudSendReport: Sendable {
    package let succeeded: Int
    package let failures: [GraphCloudRecordFailure]
    package let cleanupPending: Bool
    package let transportError: (any Error)?
    package let retryAfter: TimeInterval?
    let retryIDs: Set<GraphNodeID>
    // Nil means no receipt transaction was settled; an empty set means the committed queue is empty.
    let pendingIDs: Set<GraphNodeID>?
    package let resolvedConflicts: Int
    package let pendingRetry: Bool
    package init(succeeded: Int, failures: [GraphCloudRecordFailure], cleanupPending: Bool, transportError: (any Error)?, resolvedConflicts: Int = 0, pendingRetry: Bool = false, retryIDs: Set<GraphNodeID> = [], pendingIDs: Set<GraphNodeID>? = nil, retryAfter: TimeInterval? = nil) {
        self.succeeded = succeeded; self.failures = failures; self.cleanupPending = cleanupPending
        self.retryAfter = retryAfter
        self.transportError = transportError; self.resolvedConflicts = resolvedConflicts; self.pendingRetry = pendingRetry; self.retryIDs = retryIDs
        self.pendingIDs = pendingIDs
    }
}
package enum GraphCloudFingerprint {
    package static func of<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
package enum GraphCloudReceiptCleanup: Sendable { case consumed(Set<UUID>), retain(Set<UUID>) }

package struct GraphCloudPreparedOutgoing: Sendable {
    package let batch: GraphCloudOutgoingBatch
    package let storeID: String
    package let epoch: UUID
    let previousAssets: [GraphCloudAssetReference]
    package init(batch: GraphCloudOutgoingBatch, storeID: String, epoch: UUID,
                 previousAssets: [GraphCloudAssetReference] = []) {
        self.batch = batch; self.storeID = storeID; self.epoch = epoch
        self.previousAssets = previousAssets
    }
}

package struct GraphCloudStoreAdapter: Sendable {
    package let prepare: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, Int, GraphSyncLimits, Set<GraphNodeID>?) throws -> GraphCloudPreparedOutgoing
    package let finishPrepared: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudOutgoingBatch, GraphSyncLimits) throws -> Void
    package let currentAttempt: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphSyncLimits) throws -> GraphCloudPreparedOutgoing?
    package let sent: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudSentReceipt], [String: Data], [String: Data], GraphSyncLimits) throws -> GraphCloudResolution
    package let apply: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudEffect], GraphSyncLimits) throws -> GraphCloudResolution
    package let trim: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudReceiptCleanup) throws -> Void
    package init(
        prepare: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, Int, GraphSyncLimits, Set<GraphNodeID>?) throws -> GraphCloudPreparedOutgoing,
        finishPrepared: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudOutgoingBatch, GraphSyncLimits) throws -> Void,
        currentAttempt: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphSyncLimits) throws -> GraphCloudPreparedOutgoing?,
        sent: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudSentReceipt], [String: Data], [String: Data], GraphSyncLimits) throws -> GraphCloudResolution,
        apply: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudEffect], GraphSyncLimits) throws -> GraphCloudResolution,
        trim: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudReceiptCleanup) throws -> Void
    ) { self.prepare = prepare; self.finishPrepared = finishPrepared; self.currentAttempt = currentAttempt
        self.sent = sent; self.apply = apply; self.trim = trim }
}

package struct GraphCloudApplyReport: Sendable {
    package let applied: Int
    package let cleanupPending: Bool
    let retryIDs: Set<GraphNodeID>
    package let resolvedConflicts: Int
    package let pendingRetry: Bool
    package init(applied: Int, cleanupPending: Bool, resolvedConflicts: Int = 0, pendingRetry: Bool = false, retryIDs: Set<GraphNodeID> = []) {
        self.applied = applied; self.cleanupPending = cleanupPending; self.resolvedConflicts = resolvedConflicts; self.pendingRetry = pendingRetry; self.retryIDs = retryIDs
    }
}

package struct GraphCloudResolution: Sendable {
    package init() {}
    package var resolved = 0
    package var rebased = Set<GraphNodeID>()
    package var pendingIDs = Set<GraphNodeID>()
    package var failures: [GraphCloudRecordFailure] = []
}

/// An old driver's offers stay revoked; recovery creates a new native driver.
final class GraphCloudNativeAccountFence: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func invalidate() { state.withLock { $0 = true } }
    func check() throws { if state.withLock({ $0 }) { throw GraphCloudError.accountChanged } }
}

@available(iOS 17, macOS 14, *)
actor GraphCloudNativeOutbox {
    nonisolated let accountFence = GraphCloudNativeAccountFence()
    private var batch: GraphCloudOutgoingBatch?
    private var offered = false
    private var zoneError: Int?
    private var staging: URL?
    func begin(_ value: GraphCloudOutgoingBatch) throws {
        try accountFence.check()
        guard batch == nil else { throw GraphCloudError.busy }
        batch = value; offered = false; zoneError = nil
    }
    func current() throws -> GraphCloudOutgoingBatch {
        try accountFence.check()
        guard let batch else { throw GraphCloudError.unexpectedUpload }; return batch
    }
    func matchesFrozenServer(_ server: CloudKit.CKRecord, item: GraphCloudOutgoingNode,
                             binding: GraphCloudBinding) async -> Bool {
        guard (try? accountFence.check()) != nil else { return false }
        guard let reference = item.assetReference else {
            return GraphCloudNodeCodec.matchesFrozenServer(server, item: item, binding: binding)
        }
        guard let root = batch?.assetRoot, let spool = try? GraphCloudAssetSpool(root: root),
              let data = try? await spool.read(reference, role: .outgoing, identity: reference.identity,
                                               binding: binding, recordName: item.recordName,
                                               storeID: reference.storeID, epoch: reference.epoch) else { return false }
        guard (try? accountFence.check()) != nil else { return false }
        return GraphCloudNodeCodec.matchesFrozenServer(server, item: item, binding: binding, originalData: data)
    }
    func next(_ options: CloudKit.CKSyncEngine.SendChangesOptions) async throws -> CloudKit.CKSyncEngine.RecordZoneChangeBatch? {
        try accountFence.check()
        guard !offered, let batch else { return nil }
        offered = true
        var saves: [CloudKit.CKRecord] = [], deletes: [CloudKit.CKRecord.ID] = []
        let route = GraphCloudBinding(zone: batch.zone, graphID: batch.graphID)
        for item in batch.items {
            let id = try GraphCloudNodeCodec.recordID(for: item.change.id, binding: route)
            guard options.scope.contains(id) else { continue }
            guard item.recordName == id.recordName, (item.change.operation == .save) == (item.recordArchive != nil) else { throw GraphCloudError.invalidState }
            if let bytes = item.recordArchive {
                let record = try GraphCloudRecordCodec.restore(bytes)
                guard record.recordID == id else { throw GraphCloudError.invalidState }
                if let reference = item.assetReference {
                    guard let root = batch.assetRoot else { throw GraphCloudError.invalidState }
                    let spool = try GraphCloudAssetSpool(root: root)
                    try GraphCloudNodeCodec.validateReferenceArchive(record, reference: reference, binding: route)
                    let data = try await spool.read(reference, role: .outgoing, identity: reference.identity,
                                                    binding: route, recordName: item.recordName,
                                                    storeID: reference.storeID, epoch: reference.epoch)
                    try accountFence.check()
                    record["asset"] = data as CKRecordValue
                    _ = try GraphCloudNodeCodec.decode(record, binding: route)
                    let path = root.appendingPathComponent(reference.namespace.uuidString).appendingPathComponent(reference.file.uuidString)
                    record["asset"] = CKAsset(fileURL: path)
                } else if record["asset"] != nil {
                    _ = try GraphCloudNodeCodec.decode(record, binding: route)
                    if staging == nil {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvoAssetSend-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                        staging = directory
                    }
                    try GraphCloudAsset.materialize(record, directory: staging!)
                } else { _ = try GraphCloudNodeCodec.decode(record, binding: route) }
                saves.append(record)
            } else { deletes.append(id) }
        }
        try accountFence.check()
        return saves.isEmpty && deletes.isEmpty ? nil : .init(recordsToSave: saves, recordIDsToDelete: deletes)
    }
    func zoneFailed(_ code: Int) { zoneError = code }
    func finish() throws {
        defer {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            staging = nil; batch = nil; offered = false; zoneError = nil
        }
        if let zoneError { throw GraphCloudNativeSendError.zoneFailure(zoneError) }
    }
}
package enum GraphCloudNativeSendError: Error { case zoneFailure(Int) }
