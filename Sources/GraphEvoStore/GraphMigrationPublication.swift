import CoreData
import CryptoKit
import Foundation
import GraphEvoModel

package enum GraphMigrationPublicationError: Error, Equatable {
    case unavailable, busy, invalidLimit, recordLimit, payloadLimit, invalidIntent, receiptConflict, unsupportedStructure
}

/// One bounded atomic local commit. This allowance is not total heap, I/O or remote-work sizing.
package struct GraphMigrationPublicationLimits: Sendable {
    package let maximumRecords: Int
    package let maximumPayloadBytes: Int
    package init(maximumRecords: Int = 10_000, maximumPayloadBytes: Int = 32 * 1024 * 1024) {
        self.maximumRecords = maximumRecords; self.maximumPayloadBytes = maximumPayloadBytes
    }
    package func validate() throws {
        guard (1...10_000).contains(maximumRecords), (1...512 * 1024 * 1024).contains(maximumPayloadBytes) else {
            throw GraphMigrationPublicationError.invalidLimit
        }
    }
}

package struct GraphMigrationPublicationItem: Sendable {
    package let change: GraphMigrationChange
    package let record: GraphRecord?
    package let modifiedAt: Date?
    package init(change: GraphMigrationChange, record: GraphRecord?, modifiedAt: Date?) {
        self.change = change; self.record = record; self.modifiedAt = modifiedAt
    }
}

/// Immutable workspace-side intent. Backup locations are supplied afresh, never serialized.
package struct GraphMigrationPublicationIntent: Codable, Sendable, Equatable {
    package let format: Int
    package let workspaceID: UUID
    package let graphID: GraphID
    package let sealDigest: String
    package let backupID: UUID
    package let reason: String
    package let selectedChanges: Int
    package init(seal: GraphMigrationChangeSet, reason: String?) throws {
        self.format = 1; self.workspaceID = seal.workspaceID; self.graphID = seal.graphID
        self.sealDigest = try Self.digest(seal); self.backupID = UUID(); self.selectedChanges = seal.changes.count
        self.reason = reason ?? "Before migration publication \(seal.workspaceID.uuidString)"
        guard !self.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.reason.utf8.count <= 4096 else { throw GraphBackupError.invalidReason }
    }
    package static func digest(_ seal: GraphMigrationChangeSet) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(seal)).map { String(format: "%02x", $0) }.joined()
    }
    package func validate(_ seal: GraphMigrationChangeSet) throws {
        guard format == 1, workspaceID == seal.workspaceID, graphID == seal.graphID,
              sealDigest == (try Self.digest(seal)), selectedChanges == seal.changes.count,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.utf8.count <= 4096 else {
            throw GraphMigrationPublicationError.invalidIntent
        }
    }
    package func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 16 * 1024 else { throw GraphMigrationPublicationError.invalidIntent }
        return data
    }
}

/// Source-side proof committed atomically with all application effects; not cloud acknowledgement.
package struct GraphMigrationPublicationReceipt: Codable, Sendable, Equatable {
    package let format: Int
    package let graphID: GraphID
    package let storeID: String
    package let workspaceID: UUID
    package let sealDigest: String
    package let backupID: UUID
    package let selectedChanges: Int
    package init(intent: GraphMigrationPublicationIntent, storeID: String) {
        self.format = 1; self.graphID = intent.graphID; self.storeID = storeID
        self.workspaceID = intent.workspaceID; self.sealDigest = intent.sealDigest
        self.backupID = intent.backupID; self.selectedChanges = intent.selectedChanges
    }
    package func validate(_ seal: GraphMigrationChangeSet, storeID: String) throws {
        guard format == 1, self.storeID == storeID, graphID == seal.graphID, workspaceID == seal.workspaceID,
              sealDigest == (try GraphMigrationPublicationIntent.digest(seal)), selectedChanges == seal.changes.count else {
            throw GraphMigrationPublicationError.receiptConflict
        }
    }
}

package struct GraphMigrationPublicationResult: Sendable {
    package let receipt: GraphMigrationPublicationReceipt
    package let backupURL: URL
    package let backupRetentionPending: Bool
    package init(receipt: GraphMigrationPublicationReceipt, backupURL: URL, backupRetentionPending: Bool) {
        self.receipt = receipt; self.backupURL = backupURL; self.backupRetentionPending = backupRetentionPending
    }
}

package struct GraphMigrationPublicationAdapter: Sendable {
    package let snapshot: @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet, GraphMigrationPublicationLimits) throws -> [GraphMigrationPublicationItem]
    package let receipt: @Sendable (NSManagedObjectContext, GraphID, UUID) throws -> GraphMigrationPublicationReceipt?
    package let preflight: @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet) throws -> Void
    package let apply: @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet, GraphMigrationPublicationIntent, [GraphMigrationPublicationItem]) throws -> GraphMigrationPublicationReceipt
    package init(snapshot: @escaping @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet, GraphMigrationPublicationLimits) throws -> [GraphMigrationPublicationItem],
                 receipt: @escaping @Sendable (NSManagedObjectContext, GraphID, UUID) throws -> GraphMigrationPublicationReceipt?,
                 preflight: @escaping @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet) throws -> Void,
                 apply: @escaping @Sendable (NSManagedObjectContext, GraphMigrationWorkspaceDescriptor, GraphMigrationChangeSet, GraphMigrationPublicationIntent, [GraphMigrationPublicationItem]) throws -> GraphMigrationPublicationReceipt) {
        self.snapshot = snapshot; self.receipt = receipt; self.preflight = preflight; self.apply = apply
    }
}
