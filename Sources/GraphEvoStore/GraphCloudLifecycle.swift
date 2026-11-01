import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel

package enum GraphCloudSharingPhase: String, Codable, Sendable { case joining, active, accessUnverified, leaving, purging, removed }
package enum GraphCloudSharingRole: String, Codable, Sendable { case owner, participant }
package enum GraphCloudRemovalReason: String, Codable, Sendable { case left, accessLost }
package struct GraphCloudParticipant: Equatable, Sendable {
    package let identity: String?
    package let permission: GraphCloudSharePermission?
    package let accepted: Bool
    package let owner: Bool
}
package struct GraphCloudSharingStatus: Equatable, Sendable {
    package let graphID: GraphID
    package let generation: UUID
    package let role: GraphCloudSharingRole
    package let phase: GraphCloudSharingPhase
    package let permission: GraphCloudSharePermission?
    package let reason: GraphCloudRemovalReason?
    package let remoteOperationPending: Bool
    package let failure: String?
}
struct GraphCloudShareSnapshot: Sendable {
    let identity: String
    let role: GraphCloudSharingRole
    let permission: GraphCloudSharePermission
    let participants: [GraphCloudParticipant]
}
enum GraphCloudShareCommand: Codable, Equatable, Sendable {
    case permission(String, GraphCloudSharePermission), remove(String), stop, leave
}
struct GraphCloudControlIntent: Codable, Equatable, Sendable {
    let id: UUID
    let command: GraphCloudShareCommand
    let shareIdentity: String
}
struct GraphCloudMembership: Codable, Equatable, Sendable {
    let binding: GraphCloudBinding
    let identity: GraphCloudSessionIdentity
    let generation: UUID
    let role: GraphCloudSharingRole
    var phase: GraphCloudSharingPhase
    var permission: GraphCloudSharePermission?
    var storeID: String?
    var hadAccess = false
    var shareIdentity: String?
    var reason: GraphCloudRemovalReason?
    var pending: GraphCloudControlIntent?
    var failure: String?
    var terminal: Bool { phase == .purging || phase == .removed || phase == .leaving }
    var status: GraphCloudSharingStatus {
        .init(graphID: binding.graphID, generation: generation, role: role, phase: phase,
              permission: permission, reason: reason, remoteOperationPending: pending != nil, failure: failure)
    }
}
struct GraphCloudSharingOperations: Sendable {
    let inspect: @Sendable (GraphCloudConfiguration, GraphCloudBinding, String) async throws -> GraphCloudShareSnapshot?
    let execute: @Sendable (GraphCloudConfiguration, GraphCloudBinding, String, GraphCloudControlIntent) async throws -> Void
}

enum GraphCloudShareIdentity {
    static func of(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension GraphCloudSharingOperations {
    private static func fetch(_ config: GraphCloudConfiguration, _ binding: GraphCloudBinding, _ account: String) async throws -> CKShare? {
        let container = CKContainer(identifier: config.containerIdentifier)
        let database = binding.zone.scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        let zone = CKRecordZone.ID(zoneName: binding.zone.name, ownerName: binding.zone.owner)
        do {
            _ = try await database.recordZone(for: zone)
            guard let share = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)) as? CKShare,
                  share.publicPermission == .none, share.url != nil else { throw GraphCloudSharingError.invalidInvitation }
            if binding.zone.scope == .private {
                guard binding.zone.owner == CKCurrentUserDefaultName || binding.zone.owner == account,
                      share.currentUserParticipant?.role == .owner else { throw GraphCloudSharingError.ownerRequired }
            } else {
                guard share.currentUserParticipant?.role == .privateUser,
                      share.currentUserParticipant?.acceptanceStatus == .accepted else { return nil }
            }
            return share
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }
    static let live = GraphCloudSharingOperations(inspect: { config, binding, account in
        guard let share = try await fetch(config, binding, account) else { return nil }
        let permission: GraphCloudSharePermission
        switch share.currentUserParticipant?.permission {
        case .readOnly: permission = .readOnly
        case .readWrite: permission = .readWrite
        default: if binding.zone.scope == .private { permission = .readWrite } else { return nil }
        }
        let participants = share.participants.map { participant -> GraphCloudParticipant in
            let name = participant.userIdentity.userRecordID?.recordName ?? (participant.role == .owner && binding.zone.scope == .private ? account : nil)
            let permission: GraphCloudSharePermission? = participant.permission == .readWrite ? .readWrite : participant.permission == .readOnly ? .readOnly : nil
            return GraphCloudParticipant(identity: name, permission: permission, accepted: participant.acceptanceStatus == .accepted, owner: participant.role == .owner)
        }
        guard participants.count <= 100 else { throw GraphCloudError.inboxLimit }
        return GraphCloudShareSnapshot(identity: GraphCloudShareIdentity.of(share.url!), role: binding.zone.scope == .private ? .owner : .participant,
                                       permission: permission, participants: participants)
    }, execute: { config, binding, account, intent in
        let container = CKContainer(identifier: config.containerIdentifier)
        let database = binding.zone.scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        for attempt in 0..<2 {
            guard let share = try await fetch(config, binding, account) else {
                if case .permission = intent.command { throw GraphCloudSharingError.superseded }
                return
            }
            guard GraphCloudShareIdentity.of(share.url!) == intent.shareIdentity else { throw GraphCloudSharingError.superseded }
            switch intent.command {
            case .leave:
                guard binding.zone.scope == .shared else { throw GraphCloudSharingError.invalidParticipant }
                _ = try await database.deleteRecord(withID: share.recordID); return
            case .stop:
                guard binding.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
                _ = try await database.deleteRecord(withID: share.recordID); return
            case .permission(let recipient, let permission):
                guard binding.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
                guard let participant = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == recipient }),
                      participant.role != .owner else { throw GraphCloudSharingError.invalidParticipant }
                participant.permission = permission == .readWrite ? .readWrite : .readOnly
            case .remove(let recipient):
                guard binding.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
                guard let participant = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == recipient }) else { return }
                guard participant.role != .owner else { throw GraphCloudSharingError.invalidParticipant }
                share.removeParticipant(participant)
            }
            do { _ = try await database.save(share); return }
            catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 { continue }
        }
    })
}
