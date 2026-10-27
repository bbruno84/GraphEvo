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
    case metadataUnavailable(underlying: any Error)
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

    /// Opens one native owner with explicitly reserved private and shared SQLite resources.
    public static func openMirrored(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                                    containerIdentifier: String) async throws -> GraphDatabase {
        try await open(configuration: .init(location: .sqlite(privateURL), cloudKitContainerIdentifier: containerIdentifier,
                                            sharedStoreURL: sharedURL),
                       schema: GraphRuntimeSchema.current, adapter: GraphTypedStoreAdapter.database)
    }

    /// Prepares an owner-only zone using the public persistent-container sharing API.
    /// A persisted request with unavailable native metadata is pending and must not create another share.
    /// Success confirms share persistence/export only; graph objects and other devices may still be pending.
    public func prepareMirroring(for id: GraphID) async throws -> GraphMirrorBoundary {
        let setup = try await nativeSetup()
        guard setup.configured else { throw GraphMirroringError.localDatabase }
        guard setup.storeCount > 0, setup.readyStoreCount == setup.storeCount else {
            throw GraphMirroringError.metadataUnavailable(underlying: GraphSharingError.metadataPending)
        }
        return try await nativeOperation { native in
            guard let container = native as? NSPersistentCloudKitContainer else { throw GraphMirroringError.localDatabase }
            let prepared = try await container.performBackgroundTask { context -> (NSManagedObjectID, Bool) in
                GraphSharingNative.prepare(context, container: container)
                let root = try GraphTypedStoreAdapter.mirroringRoot(context, id: id)
                guard !StoreNativeContext.isShared(root.runtimeObjectID.persistentStore, in: context) else {
                    throw GraphStoreError.permissionDenied
                }
                let requestKey = GraphTypedStoreAdapter.prefix + "shareRequest"
                let firstRequest = root[dynamicMember: requestKey] == nil
                return (root.runtimeObjectID, firstRequest)
            }
            let objectID = prepared.0
            let mapped: CKShare?
            do { mapped = try container.fetchShares(matching: [objectID])[objectID] }
            catch { throw GraphMirroringError.metadataUnavailable(underlying: error) }
            let share: CKShare
            if let existing = mapped {
                share = existing
            } else {
                guard prepared.1 else { throw GraphMirroringError.preparationPending }
                try await container.performBackgroundTask { context in
                    GraphSharingNative.prepare(context, container: container)
                    let root = try GraphTypedStoreAdapter.mirroringRoot(context, id: id)
                    let requestKey = GraphTypedStoreAdapter.prefix + "shareRequest"
                    guard root[dynamicMember: requestKey] == nil else { throw GraphMirroringError.preparationPending }
                    root[dynamicMember: requestKey] = "requested"
                    if let store = root.runtimeObjectID.persistentStore { try root.runtimeAssignOwnedObjects(to: store, in: context) }
                    try context.save()
                }
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

/// Counts only completed native setup events. It is not an import or synchronization certificate.
public struct GraphCloudSetup: Sendable {
    public let storeCount: Int
    public let readyStoreCount: Int
    public let latestFailureDomain: String?
    public let latestFailureCode: Int?
}

extension GraphDatabase {
    public func cloudSetupStatus() async throws -> GraphCloudSetup {
        let status = try await nativeSetup()
        guard status.configured else { throw GraphMirroringError.localDatabase }
        return GraphCloudSetup(storeCount: status.storeCount, readyStoreCount: status.readyStoreCount,
                               latestFailureDomain: status.latestFailureDomain, latestFailureCode: status.latestFailureCode)
    }
}
