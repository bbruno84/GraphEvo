import CloudKit
import CoreData
import Foundation
import GraphEvoRuntime

/// Sensitive account identity for explicitly authorized invitation transport. Never log it.
public struct GraphSharingIdentity: Sendable, Codable, Equatable {
    let recordName: String
    private enum CodingKeys: String, CodingKey { case recordName }
    init(recordName: String) throws {
        guard !recordName.isEmpty else { throw GraphSharingError.invalidParticipant }
        self.recordName = recordName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordName: values.decode(String.self, forKey: .recordName))
    }
}

/// A private invitation capability. Hosts must protect its transport and avoid logging its URL.
public struct GraphInvitation: Sendable, Codable {
    public let graphID: GraphID
    let url: URL
    let recipient: GraphSharingIdentity
    private enum CodingKeys: String, CodingKey { case graphID, url, recipient }
    init(graphID: GraphID, url: URL, recipient: GraphSharingIdentity) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw GraphSharingError.invalidInvitation }
        self.graphID = graphID; self.url = url; self.recipient = recipient
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(graphID: values.decode(GraphID.self, forKey: .graphID), url: values.decode(URL.self, forKey: .url),
                      recipient: values.decode(GraphSharingIdentity.self, forKey: .recipient))
    }
}

public enum GraphSharePermission: String, Sendable, Codable { case readOnly, readWrite }
public enum GraphShareRole: Sendable, Equatable { case owner, participant, unknown }
public enum GraphSharingStoreScope: Sendable, Equatable { case privateStore, sharedStore }

public struct GraphSharingStatus: Sendable {
    public let graphID: GraphID
    public let scope: GraphSharingStoreScope
    public let role: GraphShareRole
    public let permission: GraphSharePermission?
    public let accepted: Bool
    public let metadataAvailable: Bool
    public let hasPendingOperation: Bool
}

public enum GraphSharingError: Error {
    case sharedStoreRequired
    case metadataPending
    case invalidInvitation
    case invalidParticipant
    case ownerRequired
    case participantRequired
}

/// Public framework adapter; every managed object access remains on its context queue.
enum GraphSharingNative {
    static func prepare(_ context: NSManagedObjectContext, container: NSPersistentCloudKitContainer) {
        for description in container.persistentStoreDescriptions {
            if description.cloudKitContainerOptions?.databaseScope == .shared {
                context.userInfo[StoreNativeContext.sharedURLKey] = description.url
            } else { context.userInfo[StoreNativeContext.privateURLKey] = description.url }
        }
        context.userInfo[StoreNativeContext.containerKey] = container
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = "GraphEvo.v2.sharing"
    }

    static func cloud(_ native: NSPersistentContainer) throws -> NSPersistentCloudKitContainer {
        guard let container = native as? NSPersistentCloudKitContainer else { throw GraphMirroringError.localDatabase }
        return container
    }

    static func cloudService(_ native: NSPersistentCloudKitContainer) throws -> CKContainer {
        guard let id = native.persistentStoreDescriptions.first?.cloudKitContainerOptions?.containerIdentifier else {
            throw GraphMirroringError.localDatabase
        }
        return CKContainer(identifier: id)
    }

    static func sharedStore(_ native: NSPersistentCloudKitContainer) throws -> NSPersistentStore {
        guard let url = native.persistentStoreDescriptions.first(where: { $0.cloudKitContainerOptions?.databaseScope == .shared })?.url,
              let store = native.persistentStoreCoordinator.persistentStore(for: url) else {
            throw GraphSharingError.sharedStoreRequired
        }
        return store
    }

    static func rootID(_ id: GraphID, container: NSPersistentCloudKitContainer, requiresIntegrity: Bool = true) async throws -> NSManagedObjectID {
        try await container.performBackgroundTask { context in
            prepare(context, container: container)
            let root = try requiresIntegrity ? GraphTypedStoreAdapter.mirroringRoot(context, id: id) : GraphTypedStoreAdapter.controlRoot(context, id: id)
            return root.runtimeObjectID
        }
    }

    static func share(_ id: NSManagedObjectID, container: NSPersistentCloudKitContainer) throws -> CKShare {
        guard let share = try container.fetchShares(matching: [id])[id] else { throw GraphSharingError.metadataPending }
        return share
    }

    static func requireOwner(_ id: NSManagedObjectID, share: CKShare, container: NSPersistentCloudKitContainer) throws {
        guard id.persistentStore?.url != (try? sharedStore(container).url), share.currentUserParticipant?.role == .owner else {
            throw GraphSharingError.ownerRequired
        }
    }

    static func permission(_ native: CKShare.ParticipantPermission) -> GraphSharePermission? {
        switch native { case .readOnly: return .readOnly; case .readWrite: return .readWrite; default: return nil }
    }
}

extension GraphDatabase {
    private func requireSharingSetup() async throws {
        let setup = try await nativeSetup()
        guard setup.configured else { throw GraphMirroringError.localDatabase }
        guard setup.storeCount > 0, setup.readyStoreCount == setup.storeCount else { throw GraphSharingError.metadataPending }
    }

    public func sharingIdentity() async throws -> GraphSharingIdentity {
        try await nativeOperation { native in
            let service = try GraphSharingNative.cloudService(GraphSharingNative.cloud(native))
            return try GraphSharingIdentity(recordName: await service.userRecordID().recordName)
        }
    }

    /// Adds only the explicitly supplied recipient to an already prepared personal boundary.
    public func invite(_ recipient: GraphSharingIdentity, to id: GraphID,
                       permission: GraphSharePermission = .readWrite) async throws -> GraphInvitation {
        try await requireSharingSetup()
        return try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            let rootID = try await GraphSharingNative.rootID(id, container: container)
            let share = try GraphSharingNative.share(rootID, container: container)
            try GraphSharingNative.requireOwner(rootID, share: share, container: container)
            guard let store = rootID.persistentStore,
                  recipient.recordName != (try await GraphSharingNative.cloudService(container).userRecordID().recordName) else {
                throw GraphSharingError.invalidParticipant
            }
            let lookup = CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: recipient.recordName))
            let participants = try await container.fetchParticipants(matching: [lookup], into: store)
            guard participants.count == 1, let participant = participants.first,
                  participant.userIdentity.userRecordID?.recordName == recipient.recordName else {
                throw GraphSharingError.invalidParticipant
            }
            participant.permission = permission == .readWrite ? .readWrite : .readOnly
            participant.role = .privateUser
            // A retry updates the same recipient; it does not add a different participant.
            if let existing = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == recipient.recordName }) {
                existing.permission = participant.permission
            } else { share.addParticipant(participant) }
            share.publicPermission = .none
            let saved = try await container.persistUpdatedShare(share, in: store)
            guard let url = saved.url else { throw GraphMirroringError.missingNativeResponse }
            return try GraphInvitation(graphID: id, url: url, recipient: recipient)
        }
    }

    /// Acceptance completion is separate from graph import and local graph availability.
    public func acceptInvitation(_ invitation: GraphInvitation) async throws {
        try await requireSharingSetup()
        try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            let service = try GraphSharingNative.cloudService(container)
            guard try await service.userRecordID().recordName == invitation.recipient.recordName else {
                throw GraphSharingError.invalidParticipant
            }
            let metadata = try await service.shareMetadata(for: invitation.url)
            guard metadata.containerIdentifier == service.containerIdentifier else { throw GraphSharingError.invalidInvitation }
            if metadata.participantStatus == .accepted { return }
            guard metadata.participantStatus == .pending else { throw GraphSharingError.invalidInvitation }
            _ = try await container.acceptShareInvitations(from: [metadata], into: GraphSharingNative.sharedStore(container))
        }
    }

    public func sharingStatus(for id: GraphID) async throws -> GraphSharingStatus {
        try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            return try await container.performBackgroundTask { context in
                GraphSharingNative.prepare(context, container: container)
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
                let share = try container.fetchShares(matching: [root.runtimeObjectID])[root.runtimeObjectID]
                let participant = share?.currentUserParticipant
                let role: GraphShareRole = participant?.role == .owner ? .owner : participant?.role == .privateUser ? .participant : .unknown
                return GraphSharingStatus(graphID: id,
                    scope: StoreNativeContext.isShared(root.runtimeObjectID.persistentStore, in: context) ? .sharedStore : .privateStore,
                    role: role, permission: participant.flatMap { GraphSharingNative.permission($0.permission) },
                    accepted: participant?.acceptanceStatus == .accepted, metadataAvailable: share != nil,
                    hasPendingOperation: try GraphSharedInsertionState.isPending(id: id, context: context))
            }
        }
    }

    public func setPermission(_ permission: GraphSharePermission, for recipient: GraphSharingIdentity, in id: GraphID) async throws {
        try await updateParticipant(recipient, in: id, permission: permission)
    }

    public func revoke(_ recipient: GraphSharingIdentity, from id: GraphID) async throws {
        try await updateParticipant(recipient, in: id, permission: nil)
    }

    private func updateParticipant(_ recipient: GraphSharingIdentity, in id: GraphID, permission: GraphSharePermission?) async throws {
        try await requireSharingSetup()
        try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            let root = try await GraphSharingNative.rootID(id, container: container, requiresIntegrity: permission == .readWrite)
            let share = try GraphSharingNative.share(root, container: container)
            try GraphSharingNative.requireOwner(root, share: share, container: container)
            guard let participant = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == recipient.recordName }),
                  participant.role != .owner, let store = root.persistentStore else { throw GraphSharingError.invalidParticipant }
            if let permission { participant.permission = permission == .readWrite ? .readWrite : .readOnly }
            else { share.removeParticipant(participant) }
            _ = try await container.persistUpdatedShare(share, in: store)
        }
    }

    /// Leaves only this participant's explicit shared-store zone; an owner-private store is rejected.
    public func leaveGraph(_ id: GraphID) async throws {
        try await requireSharingSetup()
        try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            let root = try await GraphSharingNative.rootID(id, container: container, requiresIntegrity: false)
            let hasPending = try await container.performBackgroundTask { context in
                GraphSharingNative.prepare(context, container: container)
                return try GraphSharedInsertionJournal.read(graphID: id, context: context) != nil
            }
            guard !hasPending else { throw GraphStoreError.pendingNativeOperation }
            let store = try GraphSharingNative.sharedStore(container)
            let share = try GraphSharingNative.share(root, container: container)
            guard root.persistentStore === store, share.currentUserParticipant?.role == .privateUser,
                  share.currentUserParticipant?.acceptanceStatus == .accepted else { throw GraphSharingError.participantRequired }
            _ = try await container.purgeObjectsAndRecordsInZone(with: share.recordID.zoneID, in: store)
        }
    }
}

enum GraphSharedInsertionState {
    static func isPending(id: GraphID, context: NSManagedObjectContext) throws -> Bool {
        if context.userInfo[StoreNativeContext.sharedURLKey] != nil,
           try GraphSharedInsertionJournal.read(graphID: id, context: context) != nil { return true }
        return try GraphTypedStoreAdapter.allNodes(GraphTypedStoreAdapter.facade(context)).contains {
            $0[dynamicMember: GraphTypedStoreAdapter.graphKey] as? String == id.rawValue.uuidString &&
            $0[dynamicMember: GraphTypedStoreAdapter.stageKey] != nil
        }
    }
}

public enum GraphSharedOperationKind: Sendable, Equatable { case insertion, patch }

/// Payload-free local intent remains inspectable even when the shared graph is no longer accessible.
public struct GraphPendingOperation: Sendable {
    public let graphID: GraphID
    public let operationID: UUID
    public let kind: GraphSharedOperationKind
    public let nodeIDs: [GraphNodeID]
}

extension GraphDatabase {
    public func pendingSharedOperations() async throws -> [GraphPendingOperation] {
        try await contextRead { context in
            guard context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer else { throw GraphMirroringError.localDatabase }
            guard let storeURL = context.userInfo[StoreNativeContext.sharedURLKey] as? URL else { throw GraphSharingError.sharedStoreRequired }
            let folder = GraphSharedInsertionJournal.folder(for: storeURL)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .compactMap { path -> GraphPendingOperation? in
                    guard let uuid = UUID(uuidString: path.lastPathComponent),
                          let plan = try GraphSharedInsertionJournal.read(graphID: GraphID(rawValue: uuid), context: context) else { return nil }
                    return GraphPendingOperation(graphID: plan.graphID, operationID: plan.operationID,
                        kind: plan.patch == nil ? .insertion : .patch,
                        nodeIDs: plan.patch.map { [$0.targetID] } ?? plan.rows.map(\.id))
                }.sorted { $0.graphID.rawValue.uuidString < $1.graphID.rawValue.uuidString }
        }
    }
}
