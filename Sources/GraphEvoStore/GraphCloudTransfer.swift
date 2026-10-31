import CoreData
import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel

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
    package init(recordName: String, code: Int) { self.recordName = recordName; self.code = code }
}
package struct GraphCloudSentReceipt: Codable, Equatable, Sendable {
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
    package init(_ entry: GraphCloudInboxEntry, binding: GraphCloudBinding) throws {
        id = entry.id; fingerprint = try GraphCloudFingerprint.of(entry); route = binding
        event = try GraphCloudNodeCodec.decode(entry.change, binding: binding)
    }
}
package struct GraphCloudSendReport: Sendable {
    package let succeeded: Int
    package let failures: [GraphCloudRecordFailure]
    package let cleanupPending: Bool
    package let transportError: (any Error)?
}
package enum GraphCloudFingerprint {
    package static func of<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
package enum GraphCloudReceiptCleanup: Sendable { case consumed(Set<UUID>), retain(Set<UUID>) }

package struct GraphCloudStoreAdapter: Sendable {
    package let prepare: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, Int, GraphSyncLimits) throws -> GraphCloudOutgoingBatch
    package let sent: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudSentReceipt, GraphSyncLimits) throws -> Void
    package let apply: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudEffect], GraphSyncLimits) throws -> Void
    package let trim: @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudReceiptCleanup) throws -> Void
    package init(
        prepare: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, Int, GraphSyncLimits) throws -> GraphCloudOutgoingBatch,
        sent: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudSentReceipt, GraphSyncLimits) throws -> Void,
        apply: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, [GraphCloudEffect], GraphSyncLimits) throws -> Void,
        trim: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudTransportBinding, GraphCloudReceiptCleanup) throws -> Void
    ) { self.prepare = prepare; self.sent = sent; self.apply = apply; self.trim = trim }
}

package struct GraphCloudApplyReport: Sendable {
    package let applied: Int
    package let cleanupPending: Bool
}

@available(iOS 17, macOS 14, *)
actor GraphCloudNativeOutbox {
    private var batch: GraphCloudOutgoingBatch?
    private var offered = false
    private var zoneError: Int?
    func begin(_ value: GraphCloudOutgoingBatch) throws {
        guard batch == nil else { throw GraphCloudError.busy }
        batch = value; offered = false; zoneError = nil
    }
    func current() throws -> GraphCloudOutgoingBatch {
        guard let batch else { throw GraphCloudError.unexpectedUpload }; return batch
    }
    func next(_ options: CloudKit.CKSyncEngine.SendChangesOptions) throws -> CloudKit.CKSyncEngine.RecordZoneChangeBatch? {
        guard !offered, let batch else { return nil }
        offered = true
        var saves: [CloudKit.CKRecord] = [], deletes: [CloudKit.CKRecord.ID] = []
        let route = GraphCloudBinding(zone: batch.zone, graphID: batch.graphID)
        for item in batch.items {
            let id = try GraphCloudNodeCodec.recordID(for: item.change.id, binding: route)
            guard options.scope.contains(id) else { continue }
            guard item.recordName == id.recordName, (item.change.operation == .save) == (item.recordArchive != nil) else { throw GraphCloudError.invalidState }
            if let bytes = item.recordArchive {
                guard let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CloudKit.CKRecord.self, from: bytes) else { throw GraphCloudError.invalidState }
                guard record.recordID == id else { throw GraphCloudError.invalidState }
                _ = try GraphCloudNodeCodec.decode(record, binding: route)
                saves.append(record)
            } else { deletes.append(id) }
        }
        return saves.isEmpty && deletes.isEmpty ? nil : .init(recordsToSave: saves, recordIDsToDelete: deletes)
    }
    func zoneFailed(_ code: Int) { zoneError = code }
    func finish() throws {
        defer { batch = nil; offered = false; zoneError = nil }
        if let zoneError { throw GraphCloudNativeSendError.zoneFailure(zoneError) }
    }
}
package enum GraphCloudNativeSendError: Error { case zoneFailure(Int) }
