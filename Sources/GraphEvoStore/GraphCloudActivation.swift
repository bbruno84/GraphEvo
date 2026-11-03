import CloudKit
import CoreData
import CryptoKit
import Foundation
import GraphEvoModel

package enum GraphCloudActivationError: Error, Equatable {
    case unavailable, invalidRequest, invalidState, busy, authorityConflict, zoneNotEmpty, limitExceeded, recoveryRequired
}

package enum GraphCloudActivationPhase: String, Codable, Sendable {
    case prepared, claiming, seeding, publishing, published, conflict, recovering
}

/// Consumer evidence is a declaration, not a library-certified distributed v1 fence.
package struct GraphCloudCutoverDeclaration: Codable, Equatable, Sendable {
    package let sourceSelection: String
    package let completeness: String
    package let stoppedWriters: String
    package let returningClients: String
    package init(sourceSelection: String, completeness: String, stoppedWriters: String, returningClients: String) {
        self.sourceSelection = sourceSelection; self.completeness = completeness
        self.stoppedWriters = stoppedWriters; self.returningClients = returningClients
    }
    package func validate() throws {
        for value in [sourceSelection, completeness, stoppedWriters, returningClients] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 2048 else {
                throw GraphCloudActivationError.invalidRequest
            }
        }
    }
}

package struct GraphCloudActivationLimits: Codable, Equatable, Sendable {
    package let maximumRecords: Int
    package let maximumPayloadBytes: Int
    package init(maximumRecords: Int = 10_000, maximumPayloadBytes: Int = 32 * 1024 * 1024) {
        self.maximumRecords = maximumRecords; self.maximumPayloadBytes = maximumPayloadBytes
    }
    package func validate() throws {
        guard (1...10_000).contains(maximumRecords), (1...32 * 1024 * 1024).contains(maximumPayloadBytes) else {
            throw GraphCloudActivationError.limitExceeded
        }
    }
}

package struct GraphCloudActivationStatus: Sendable {
    package let activationID: UUID
    package let graphID: GraphID
    package let phase: GraphCloudActivationPhase
    package let recordCount: Int
}

package struct GraphCloudSeedEntry: Codable, Equatable, Sendable {
    package let nodeID: UUID
    package let kind: String
    package let type: String
    package let digest: String
    package let assetDigest: String?
    package let assetBytes: Int
}

package struct GraphCloudSeedManifest: Codable, Equatable, Sendable {
    package let format: Int
    package let graphID: GraphID
    package let entries: [GraphCloudSeedEntry]
    package static let maximumBytes = 4 * 1024 * 1024
    package var digest: String { get throws { try GraphCloudFingerprint.of(self) } }
    package init(format: Int, graphID: GraphID, entries: [GraphCloudSeedEntry]) { self.format = format; self.graphID = graphID; self.entries = entries }

    package static func entry(_ record: CKRecord, binding: GraphCloudBinding) throws -> GraphCloudSeedEntry {
        let decoded = try GraphCloudNodeCodec.decode(record, binding: binding)
        let payload = try GraphCloudNodeCodec.encode(decoded.record, binding: binding, modifiedAt: decoded.modifiedAt)
        guard let bytes = payload["payload"] as? Data, let kind = payload["kind"] as? String else {
            throw GraphCloudActivationError.invalidState
        }
        let data = try payload["asset"].map { try GraphCloudAsset.bytes($0) }
        return .init(nodeID: decoded.record.id.rawValue, kind: kind, type: decoded.record.type,
                     digest: SHA256.hash(data: bytes).hex, assetDigest: data.map { SHA256.hash(data: $0).hex }, assetBytes: data?.count ?? 0)
    }

    package static func make(_ records: [CKRecord], binding: GraphCloudBinding, limits: GraphCloudActivationLimits) throws -> Self {
        try limits.validate()
        guard records.count <= limits.maximumRecords else { throw GraphCloudActivationError.limitExceeded }
        var remaining = limits.maximumPayloadBytes
        var entries: [GraphCloudSeedEntry] = []
        for record in records {
            try Task.checkCancellation()
            guard let payload = record["payload"] as? Data else { throw GraphCloudActivationError.invalidState }
            guard payload.count <= remaining else { throw GraphCloudActivationError.limitExceeded }
            remaining -= payload.count
            entries.append(try entry(record, binding: binding))
        }
        return try make(entries: entries, binding: binding, limits: limits)
    }

    package static func make(entries: [GraphCloudSeedEntry], binding: GraphCloudBinding,
                             limits: GraphCloudActivationLimits) throws -> Self {
        try limits.validate()
        guard entries.count <= limits.maximumRecords else { throw GraphCloudActivationError.limitExceeded }
        var entries = entries
        entries.sort { $0.nodeID.uuidString < $1.nodeID.uuidString }
        guard Set(entries.map(\.nodeID)).count == entries.count else { throw GraphCloudActivationError.invalidState }
        let result = Self(format: 1, graphID: binding.graphID, entries: entries)
        guard try JSONEncoder().encode(result).count <= maximumBytes else { throw GraphCloudActivationError.limitExceeded }
        return result
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

package struct GraphCloudAuthority: Codable, Equatable, Sendable {
    package let format: Int
    package let graphID: GraphID
    package let activationID: UUID
    package let seedDigest: String
    package let recordCount: Int
    package let conversionCommitment: String
    package var published: Bool
    package init(format: Int = 1, graphID: GraphID, activationID: UUID, seedDigest: String, recordCount: Int, conversionCommitment: String, published: Bool = false) {
        self.format = format; self.graphID = graphID; self.activationID = activationID; self.seedDigest = seedDigest
        self.recordCount = recordCount; self.conversionCommitment = conversionCommitment; self.published = published
    }
    package func matches(_ other: Self) -> Bool {
        var a = self, b = other; a.published = false; b.published = false
        return a == b
    }
}

package struct GraphCloudActivationDocument: Codable, Equatable, Sendable {
    package var format = 2
    package let binding: GraphCloudTransportBinding
    package let storeID: String
    package let fileIdentity: WorkspaceFileIdentity
    package let epoch: UUID
    package let authority: GraphCloudAuthority
    package let declaration: GraphCloudCutoverDeclaration?
    package let manifest: GraphCloudSeedManifest?
    package let limits: GraphCloudActivationLimits
    package var phase: GraphCloudActivationPhase
    package init(binding: GraphCloudTransportBinding, storeID: String, fileIdentity: WorkspaceFileIdentity, epoch: UUID, authority: GraphCloudAuthority,
                 declaration: GraphCloudCutoverDeclaration?, manifest: GraphCloudSeedManifest?, limits: GraphCloudActivationLimits, phase: GraphCloudActivationPhase) {
        self.binding = binding; self.storeID = storeID; self.fileIdentity = fileIdentity; self.epoch = epoch; self.authority = authority
        self.declaration = declaration; self.manifest = manifest; self.limits = limits; self.phase = phase
    }
    package var status: GraphCloudActivationStatus {
        .init(activationID: authority.activationID, graphID: authority.graphID, phase: phase, recordCount: authority.recordCount)
    }
    package var blocksWrites: Bool { phase != .published && phase != .conflict }
    package var peer: Bool { declaration == nil }
    package func validate(graphID: GraphID) throws {
        try limits.validate()
        guard format == 2, authority.format == 1, binding.route.graphID == graphID, authority.graphID == graphID,
              binding.route.zone.scope == .private, !storeID.isEmpty, authority.recordCount >= 0,
              authority.recordCount <= limits.maximumRecords, authority.seedDigest.count == 64,
              authority.conversionCommitment.count == 64 else { throw GraphCloudActivationError.invalidState }
        if let declaration {
            try declaration.validate()
            guard let manifest, manifest.graphID == graphID, manifest.format == 1,
                  manifest.entries.count == authority.recordCount, try manifest.digest == authority.seedDigest,
                  phase != .recovering else { throw GraphCloudActivationError.invalidState }
        } else {
            guard manifest == nil, phase == .recovering || phase == .published, authority.published else {
                throw GraphCloudActivationError.invalidState
            }
        }
    }
}

struct GraphCloudAuthorityRemote: Sendable {
    let value: GraphCloudAuthority
    let archive: Data
}

struct GraphCloudActivationRoute: Codable, Sendable {
    let binding: GraphCloudBinding
    let activationID: UUID
    let published: Bool
    let peer: Bool
}

enum GraphCloudAuthorityCodec {
    static let recordName = "graphevo.activation"
    static let recordType = "GraphEvoActivation"
    static func isControl(_ value: GraphCloudIncoming) -> Bool { value.recordName == recordName || value.recordType == recordType }
    static func id(_ binding: GraphCloudBinding) -> CKRecord.ID {
        .init(recordName: recordName, zoneID: .init(zoneName: binding.zone.name, ownerName: binding.zone.owner))
    }
    static func encode(_ value: GraphCloudAuthority, binding: GraphCloudBinding, base: GraphCloudAuthorityRemote?) throws -> CKRecord {
        guard value.graphID == binding.graphID else { throw GraphCloudActivationError.invalidState }
        let record = try base.map { try GraphCloudRecordCodec.restore($0.archive) }
            ?? CKRecord(recordType: recordType, recordID: id(binding))
        if let base {
            guard try decode(record, binding: binding).value == base.value, base.value.matches(value),
                  !base.value.published || value.published else { throw GraphCloudActivationError.authorityConflict }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        record["graphID"] = value.graphID.rawValue.uuidString.lowercased() as CKRecordValue
        record["payload"] = try encoder.encode(value) as CKRecordValue
        _ = try decode(record, binding: binding)
        return record
    }
    static func decode(_ record: CKRecord, binding: GraphCloudBinding) throws -> GraphCloudAuthorityRemote {
        guard record.recordID == id(binding), record.recordType == recordType,
              Set(record.allKeys()) == ["graphID", "payload"], record.encryptedValues.allKeys().isEmpty,
              record["graphID"] as? String == binding.graphID.rawValue.uuidString.lowercased(),
              let payload = record["payload"] as? Data, payload.count <= 16 * 1024 else { throw GraphCloudActivationError.invalidState }
        let value = try JSONDecoder().decode(GraphCloudAuthority.self, from: payload)
        guard value.format == 1, value.graphID == binding.graphID, value.recordCount >= 0, value.recordCount <= 10_000,
              value.seedDigest.utf8.count == 64, value.conversionCommitment.utf8.count == 64,
              (value.seedDigest + value.conversionCommitment).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw GraphCloudActivationError.invalidState
        }
        guard let archive = try GraphCloudRecordCodec.archive(record, scope: binding.zone.scope).recordArchive else {
            throw GraphCloudActivationError.invalidState
        }
        return .init(value: value, archive: archive)
    }
}

package struct GraphCloudActivationAdapter: Sendable {
    package let requiresActivation: @Sendable (NSManagedObjectContext, GraphID) throws -> Bool
    package let read: @Sendable (NSManagedObjectContext, GraphID) throws -> GraphCloudActivationDocument?
    package let prepare: @Sendable (NSManagedObjectContext, GraphCloudTransportBinding, UUID, GraphCloudCutoverDeclaration, GraphCloudActivationLimits) throws -> GraphCloudActivationDocument
    package let write: @Sendable (NSManagedObjectContext, GraphID, GraphCloudActivationDocument) throws -> Void
    package let peer: @Sendable (NSManagedObjectContext, GraphCloudTransportBinding, GraphCloudAuthority, GraphCloudActivationLimits) throws -> GraphCloudActivationDocument
    package let replicaIDs: @Sendable (NSManagedObjectContext, GraphID) throws -> Set<GraphNodeID>
    package init(requiresActivation: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> Bool,
                 read: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> GraphCloudActivationDocument?,
                 prepare: @escaping @Sendable (NSManagedObjectContext, GraphCloudTransportBinding, UUID, GraphCloudCutoverDeclaration, GraphCloudActivationLimits) throws -> GraphCloudActivationDocument,
                 write: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphCloudActivationDocument) throws -> Void,
                 peer: @escaping @Sendable (NSManagedObjectContext, GraphCloudTransportBinding, GraphCloudAuthority, GraphCloudActivationLimits) throws -> GraphCloudActivationDocument,
                 replicaIDs: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> Set<GraphNodeID>) {
        self.requiresActivation = requiresActivation; self.read = read; self.prepare = prepare; self.write = write; self.peer = peer; self.replicaIDs = replicaIDs
    }
}
