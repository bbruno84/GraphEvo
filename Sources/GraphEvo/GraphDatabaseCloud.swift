import CloudKit
import CoreData
import Foundation
import GraphEvoRuntime

/// Native share preparation is separate from object export and replica recovery.
public struct GraphMirrorBoundary: Sendable, Equatable {
    public let graphID: GraphID
    public let zoneName: String
    public let shareRecordName: String
}

public enum GraphMirroringError: Error {
    case localDatabase
    case preparationPending
    case invalidOwnerOnlyShare
    case missingNativeResponse
}

extension GraphDatabase {
    /// Opens an owner-private mirrored resource. The catalog may grow as native imports arrive.
    /// There is no local fallback: failure to configure this explicit cloud resource is an error.
    public static func openMirrored(at url: URL, containerIdentifier: String) async throws -> GraphDatabase {
        try await open(configuration: .init(location: .sqlite(url), cloudKitContainerIdentifier: containerIdentifier),
                       schema: GraphRuntimeSchema.current, adapter: GraphTypedStoreAdapter.database)
    }

    /// Prepares an owner-only zone using the public persistent-container sharing API.
    /// A persisted request with unavailable native metadata is pending and must not create another share.
    /// Success confirms share persistence/export only; graph objects and other devices may still be pending.
    public func prepareMirroring(for id: GraphID) async throws -> GraphMirrorBoundary {
        try await nativeOperation { native in
            guard let container = native as? NSPersistentCloudKitContainer else { throw GraphMirroringError.localDatabase }
            let prepared = try await container.performBackgroundTask { context -> (NSManagedObjectID, Bool) in
                let root = try GraphTypedStoreAdapter.mirroringRoot(context, id: id)
                let requestKey = GraphTypedStoreAdapter.prefix + "shareRequest"
                let firstRequest = root[dynamicMember: requestKey] == nil
                if firstRequest {
                    root[dynamicMember: requestKey] = "requested"
                    try context.save()
                }
                return (root.runtimeObjectID, firstRequest)
            }
            let objectID = prepared.0
            let share: CKShare
            if let existing = try container.fetchShares(matching: [objectID])[objectID] {
                share = existing
            } else {
                guard prepared.1 else { throw GraphMirroringError.preparationPending }
                // Initiate sharing on the root context's queue without escaping its managed object.
                share = try await withCheckedThrowingContinuation { continuation in
                    container.performBackgroundTask { context in
                        do {
                            let root = try context.existingObject(with: objectID)
                            container.share([root], to: nil) { _, share, _, error in
                                if let error { continuation.resume(throwing: error) }
                                else if let share { continuation.resume(returning: share) }
                                else { continuation.resume(throwing: GraphMirroringError.missingNativeResponse) }
                            }
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            guard share.publicPermission == .none,
                  share.participants.allSatisfy({ $0.role == .owner }),
                  let store = objectID.persistentStore else {
                throw GraphMirroringError.invalidOwnerOnlyShare
            }
            let saved = try await container.persistUpdatedShare(share, in: store)
            guard saved.recordID == share.recordID else { throw GraphMirroringError.missingNativeResponse }
            return GraphMirrorBoundary(graphID: id, zoneName: saved.recordID.zoneID.zoneName,
                                       shareRecordName: saved.recordID.recordName)
        }
    }
}

/// A local native mapping observation. Missing mappings do not imply lost data or completed import.
public struct GraphMirrorMembership: Sendable, Equatable {
    public let graphID: GraphID
    public let boundary: GraphMirrorBoundary?
    public let nativeObjectCount: Int
    public let pendingMappingCount: Int
    public let unexpectedZoneCount: Int
}

extension GraphDatabase {
    /// Inspects current mappings for every member and owned property/tag/group row without exporting.
    public func inspectMirroring(for id: GraphID) async throws -> GraphMirrorMembership {
        try await nativeOperation { native in
            guard let container = native as? NSPersistentCloudKitContainer else { throw GraphMirroringError.localDatabase }
            return try await container.performBackgroundTask { context in
                let root = try GraphTypedStoreAdapter.mirroringRoot(context, id: id)
                let members = try GraphTypedStoreAdapter.nativeMembers(context, id: id)
                let share = try container.fetchShares(matching: [root.runtimeObjectID])[root.runtimeObjectID]
                let boundary = share.map { GraphMirrorBoundary(graphID: id, zoneName: $0.recordID.zoneID.zoneName,
                                                               shareRecordName: $0.recordID.recordName) }
                var pending = 0, unexpected = 0
                for member in members {
                    guard let record = container.recordID(for: member) else { pending += 1; continue }
                    if let share, record.zoneID != share.recordID.zoneID { unexpected += 1 }
                }
                return GraphMirrorMembership(graphID: id, boundary: boundary, nativeObjectCount: members.count,
                                             pendingMappingCount: pending, unexpectedZoneCount: unexpected)
            }
        }
    }
}
