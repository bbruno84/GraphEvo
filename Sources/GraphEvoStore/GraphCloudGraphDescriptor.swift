import CloudKit
import CoreFoundation
import Foundation
import GraphEvoModel

/// Errors in native invitation discovery; none authorizes local deletion.
public enum GraphCloudDiscoveryError: Error, Sendable, Equatable {
    case invalidDescriptor, unsupportedDescriptor, metadataPending, invalidInvitation, busy, graphPaused, limitExceeded, invalidJoin, sessionUpgradeRequired
}

/// A cloud control record, independent of application data and MF10 authority.
enum GraphCloudGraphDescriptor {
    static let recordType = "GraphEvoGraph"
    static let recordName = "graphevo.graph"
    static let maximumBytes = 16 * 1024
    static func id(in zone: GraphCloudZone) -> CKRecord.ID {
        .init(recordName: recordName, zoneID: .init(zoneName: zone.name, ownerName: zone.owner))
    }
    static func isControl(_ event: GraphCloudIncoming) -> Bool {
        event.recordName == recordName || event.recordType == recordType
    }
    static func encode(_ binding: GraphCloudBinding, supportsFiles: Bool = false) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: id(in: binding.zone))
        record["format"] = NSNumber(value: 3)
        record["files"] = NSNumber(value: supportsFiles ? 1 : 0)
        record["graphID"] = binding.graphID.rawValue.uuidString.lowercased() as CKRecordValue
        return record
    }
    static func decode(_ record: CKRecord, zone: GraphCloudZone, supportsFiles: Bool = false) throws -> GraphID {
        guard record.recordType == recordType, record.recordID == id(in: zone),
              record.encryptedValues.allKeys().isEmpty,
              let format = record["format"] as? NSNumber,
              CFGetTypeID(format) != CFBooleanGetTypeID() else { throw GraphCloudDiscoveryError.invalidDescriptor }
        guard format == NSNumber(value: 3), let files = record["files"] as? NSNumber,
              (files.doubleValue == 0 || files.doubleValue == 1), supportsFiles || !files.boolValue else { throw GraphCloudDiscoveryError.unsupportedDescriptor }
        guard let raw = record["graphID"] as? String, let uuid = UUID(uuidString: raw),
              raw == uuid.uuidString.lowercased() else { throw GraphCloudDiscoveryError.invalidDescriptor }
        // Bound the entire field archive, including optional future keys, without loading assets.
        guard record.allKeys().allSatisfy({ !(record[$0] is CKAsset) }),
              let bytes = try GraphCloudRecordCodec.archive(record, scope: zone.scope).recordArchive,
              bytes.count <= maximumBytes else { throw GraphCloudDiscoveryError.invalidDescriptor }
        return GraphID(rawValue: uuid)
    }
    static func validate(_ event: GraphCloudIncoming, binding: GraphCloudBinding, supportsFiles: Bool = false) throws {
        guard event.kind == .recordChanged, event.zone == binding.zone, event.assetReference == nil,
              let bytes = event.recordArchive, bytes.count <= maximumBytes,
              try decode(GraphCloudRecordCodec.restore(bytes), zone: binding.zone, supportsFiles: supportsFiles) == binding.graphID else {
            throw GraphCloudDiscoveryError.invalidDescriptor
        }
    }
}

/// Detached, verified native metadata. URLs and account references are never diagnostics.
struct GraphCloudNativeInvitation: Codable, Equatable, Sendable {
    let url: URL
    let zone: GraphCloudZone
    let owner: String
    let permission: GraphCloudSharePermission
    let accepted: Bool
}

/// Native operations return detached archives; mutable CKShare values stay in platform adapters.
struct GraphCloudNativeSharingService: Sendable {
    let prepare: @Sendable (GraphCloudConfiguration, GraphCloudBinding, String, Bool, @escaping @Sendable () async throws -> Void) async throws -> Data
    let inspect: @Sendable (GraphCloudConfiguration, URL, String) async throws -> GraphCloudNativeInvitation
    let accept: @Sendable (GraphCloudConfiguration, GraphCloudNativeInvitation, String) async throws -> Void
    let discover: @Sendable (GraphCloudConfiguration, GraphCloudZone) async throws -> GraphID
    let discard: @Sendable (GraphCloudConfiguration, GraphCloudNativeInvitation, String) async throws -> Void
}

extension GraphCloudNativeSharingService {
    private static func metadata(_ config: GraphCloudConfiguration, url: URL, account: String) async throws -> CKShare.Metadata {
        guard url.scheme == "https", url.host?.isEmpty == false, url.absoluteString.utf8.count <= 4096 else {
            throw GraphCloudDiscoveryError.invalidInvitation
        }
        let value = try await CKContainer(identifier: config.containerIdentifier).shareMetadata(for: url)
        let share = value.share
        guard value.containerIdentifier == config.containerIdentifier,
              share.recordID.recordName == CKRecordNameZoneWideShare, share.publicPermission == .none,
              value.participantRole == .privateUser,
              value.participantStatus == .pending || value.participantStatus == .accepted,
              value.participantPermission == .readOnly || value.participantPermission == .readWrite,
              !share.recordID.zoneID.ownerName.isEmpty,
              share.recordID.zoneID.ownerName != CKCurrentUserDefaultName,
              share.recordID.zoneID.ownerName != account,
              share.url != nil else { throw GraphCloudDiscoveryError.invalidInvitation }
        if let owner = value.ownerIdentity.userRecordID?.recordName, owner != share.recordID.zoneID.ownerName {
            throw GraphCloudDiscoveryError.invalidInvitation
        }
        return value
    }
    static let live = Self(prepare: { config, binding, title, mayCreate, beforeCreate in
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let zoneID = GraphCloudGraphDescriptor.id(in: binding.zone).zoneID
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        do {
            let record = try await database.record(for: GraphCloudGraphDescriptor.id(in: binding.zone))
            guard try GraphCloudGraphDescriptor.decode(record, zone: binding.zone, supportsFiles: config.supportsFiles) == binding.graphID else {
                throw GraphCloudDiscoveryError.invalidDescriptor
            }
        } catch let error as CKError where error.code == .unknownItem {
            let record = GraphCloudGraphDescriptor.encode(binding, supportsFiles: config.supportsFiles)
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let saved = result.saveResults[record.recordID] else { throw GraphCloudDiscoveryError.metadataPending }
                guard try GraphCloudGraphDescriptor.decode(saved.get(), zone: binding.zone, supportsFiles: config.supportsFiles) == binding.graphID else { throw GraphCloudDiscoveryError.invalidDescriptor }
            } catch let error as CKError where error.code == .serverRecordChanged {
                guard try GraphCloudGraphDescriptor.decode(await database.record(for: record.recordID), zone: binding.zone, supportsFiles: config.supportsFiles) == binding.graphID else {
                    throw GraphCloudDiscoveryError.invalidDescriptor
                }
            }
        }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare
        do {
            guard let existing = try await database.record(for: shareID) as? CKShare else { throw GraphCloudDiscoveryError.invalidInvitation }
            share = existing
        } catch let error as CKError where error.code == .unknownItem {
            guard mayCreate else { throw GraphCloudSharingError.metadataPending }
            try await beforeCreate()
            let created = CKShare(recordZoneID: zoneID)
            created.publicPermission = .none
            created[CKShare.SystemFieldKey.title] = title as CKRecordValue
            guard let saved = try await database.save(created) as? CKShare else { throw GraphCloudDiscoveryError.metadataPending }
            share = saved
        }
        guard share.currentUserParticipant?.role == .owner, share.publicPermission == .none,
              share.url != nil,
              let bytes = try GraphCloudRecordCodec.archive(share, scope: .private).recordArchive else {
            throw GraphCloudDiscoveryError.invalidInvitation
        }
        return bytes
    }, inspect: { config, url, account in
        let value = try await metadata(config, url: url, account: account)
        let zone = value.share.recordID.zoneID
        return .init(url: value.share.url!, zone: .init(scope: .shared, owner: zone.ownerName, name: zone.zoneName), owner: zone.ownerName,
                     permission: value.participantPermission == .readWrite ? .readWrite : .readOnly,
                     accepted: value.participantStatus == .accepted)
    }, accept: { config, expected, account in
        let value = try await metadata(config, url: expected.url, account: account)
        guard value.share.url == expected.url, value.share.recordID.zoneID == GraphCloudGraphDescriptor.id(in: expected.zone).zoneID else {
            throw GraphCloudDiscoveryError.invalidInvitation
        }
        if value.participantStatus == .pending { _ = try await CKContainer(identifier: config.containerIdentifier).accept(value) }
    }, discover: { config, zone in
        let record = try await CKContainer(identifier: config.containerIdentifier).sharedCloudDatabase.record(for: GraphCloudGraphDescriptor.id(in: zone))
        return try GraphCloudGraphDescriptor.decode(record, zone: zone, supportsFiles: config.supportsFiles)
    }, discard: { config, expected, account in
        let value = try await metadata(config, url: expected.url, account: account)
        guard value.share.url == expected.url, value.share.recordID.zoneID == GraphCloudGraphDescriptor.id(in: expected.zone).zoneID else { throw GraphCloudDiscoveryError.invalidInvitation }
        if value.participantStatus == .accepted {
            _ = try await CKContainer(identifier: config.containerIdentifier).sharedCloudDatabase.deleteRecord(withID: value.share.recordID)
        }
    })
}
