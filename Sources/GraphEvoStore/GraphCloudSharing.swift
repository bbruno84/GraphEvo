import CloudKit
import Foundation
import GraphEvoModel

package enum GraphCloudSharePermission: String, Codable, Sendable { case readOnly, readWrite }
package enum GraphCloudSharingError: Error, Equatable {
    case invalidInvitation, invalidParticipant, ownerRequired, metadataPending, nonemptyReplica, unavailable
}

/// A private capability. Hosts must protect its transport; never log identities or URLs.
package struct GraphCloudInvitation: Codable, Equatable, Sendable {
    package let container: String
    package let environment: GraphCloudEnvironment
    package let graphID: GraphID
    package let owner: String
    package let zoneName: String
    package let recipient: String
    package let url: URL
    func validate() throws {
        guard !container.isEmpty, !owner.isEmpty, !zoneName.isEmpty, !recipient.isEmpty,
              owner != recipient, url.scheme == "https", url.host?.isEmpty == false,
              url.absoluteString.utf8.count <= 4096 else { throw GraphCloudSharingError.invalidInvitation }
    }
    package var zone: GraphCloudZone { .init(scope: .shared, owner: owner, name: zoneName) }
}

/// Stored only in reserved local metadata. Absence means an ordinary local/owner graph.
package struct GraphCloudParticipantAccess: Codable, Equatable, Sendable {
    package let binding: GraphCloudBinding
    package let account: String
    package let permission: GraphCloudSharePermission?
    package let accepted: Bool
    package init(binding: GraphCloudBinding, account: String, permission: GraphCloudSharePermission?, accepted: Bool) {
        self.binding = binding; self.account = account; self.permission = permission; self.accepted = accepted
    }
    package var writable: Bool { accepted && permission == .readWrite }
}

struct GraphCloudSharingService: Sendable {
    let invite: @Sendable (GraphCloudConfiguration, GraphCloudBinding, String, String, GraphCloudSharePermission, Bool) async throws -> GraphCloudInvitation
    let accept: @Sendable (GraphCloudConfiguration, GraphCloudInvitation, String) async throws -> GraphCloudSharePermission
}

extension GraphCloudSharingService {
    static let live = GraphCloudSharingService(invite: { config, binding, account, recipient, permission, mayCreate in
        guard binding.zone.scope == .private,
              binding.zone.owner == CKCurrentUserDefaultName || binding.zone.owner == account else { throw GraphCloudSharingError.ownerRequired }
        guard !recipient.isEmpty, recipient != account else { throw GraphCloudSharingError.invalidParticipant }
        let container = CKContainer(identifier: config.containerIdentifier), database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: binding.zone.name, ownerName: binding.zone.owner)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare
        do {
            guard let found = try await database.record(for: shareID) as? CKShare else { throw GraphCloudSharingError.invalidInvitation }
            share = found
        } catch let error as CKError where error.code == .unknownItem {
            guard mayCreate else { throw GraphCloudSharingError.metadataPending }
            // The zone must already exist. Sharing does not publish pending graph data.
            _ = try await database.recordZone(for: zoneID)
            share = CKShare(recordZoneID: zoneID)
        }
        guard share.currentUserParticipant?.role == .owner else { throw GraphCloudSharingError.ownerRequired }
        let recipientID = CKRecord.ID(recordName: recipient)
        let results = try await container.shareParticipants(forUserRecordIDs: [recipientID])
        guard let result = results[recipientID] else { throw GraphCloudSharingError.invalidParticipant }
        let participant = try result.get()
        guard participant.userIdentity.userRecordID?.recordName == recipient else { throw GraphCloudSharingError.invalidParticipant }
        let nativePermission: CKShare.ParticipantPermission = permission == .readWrite ? .readWrite : .readOnly
        if let existing = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == recipient }) {
            existing.permission = nativePermission
        } else {
            participant.role = .privateUser; participant.permission = nativePermission; share.addParticipant(participant)
        }
        share.publicPermission = .none
        guard let saved = try await database.save(share) as? CKShare, let url = saved.url else { throw GraphCloudSharingError.metadataPending }
        let invitation = GraphCloudInvitation(container: config.containerIdentifier, environment: config.environment,
            graphID: binding.graphID, owner: account, zoneName: binding.zone.name, recipient: recipient, url: url)
        try invitation.validate(); return invitation
    }, accept: { config, invitation, account in
        try invitation.validate()
        guard invitation.container == config.containerIdentifier, invitation.environment == config.environment else { throw GraphCloudSharingError.invalidInvitation }
        guard invitation.recipient == account else { throw GraphCloudSharingError.invalidParticipant }
        let container = CKContainer(identifier: config.containerIdentifier)
        let metadata = try await container.shareMetadata(for: invitation.url)
        let share = metadata.share
        guard metadata.containerIdentifier == config.containerIdentifier,
              share.recordID.recordName == CKRecordNameZoneWideShare,
              share.recordID.zoneID.zoneName == invitation.zoneName,
              share.recordID.zoneID.ownerName == invitation.owner,
              metadata.ownerIdentity.userRecordID?.recordName == invitation.owner,
              share.publicPermission == .none,
              metadata.participantRole == .privateUser else { throw GraphCloudSharingError.invalidInvitation }
        guard metadata.participantStatus == .pending || metadata.participantStatus == .accepted else { throw GraphCloudSharingError.invalidInvitation }
        let permission: GraphCloudSharePermission
        switch metadata.participantPermission {
        case .readOnly: permission = .readOnly
        case .readWrite: permission = .readWrite
        default: throw GraphCloudSharingError.invalidInvitation
        }
        if metadata.participantStatus == .pending { _ = try await container.accept(metadata) }
        return permission
    })
}

/// CKShare is control metadata, never a GraphEvoNode or application payload.
enum GraphCloudShareControl {
    static func isControl(_ incoming: GraphCloudIncoming) -> Bool { incoming.recordType == CKRecord.SystemType.share }
    static func permission(_ incoming: GraphCloudIncoming, binding: GraphCloudBinding) throws -> GraphCloudSharePermission? {
        guard incoming.zone == binding.zone, incoming.recordName == CKRecordNameZoneWideShare,
              isControl(incoming), incoming.kind == .recordChanged || incoming.kind == .recordDeleted else {
            throw GraphCloudSharingError.invalidInvitation
        }
        if incoming.kind == .recordDeleted { return nil }
        try GraphCloudRecordCodec.validate(incoming)
        guard let bytes = incoming.recordArchive, let share = try GraphCloudRecordCodec.restore(bytes) as? CKShare,
              share.publicPermission == .none else { throw GraphCloudSharingError.invalidInvitation }
        if binding.zone.scope == .private {
            guard share.currentUserParticipant?.role == .owner else { throw GraphCloudSharingError.ownerRequired }
            return .readWrite
        }
        guard let participant = share.currentUserParticipant, participant.role == .privateUser,
              participant.acceptanceStatus == .accepted else { return nil }
        switch participant.permission { case .readOnly: return .readOnly; case .readWrite: return .readWrite; default: return nil }
    }
}
