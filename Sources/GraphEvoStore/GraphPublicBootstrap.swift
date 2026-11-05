import CloudKit
import Foundation
import GraphEvoModel

/// An explicit supported v1 source, separate destination and recoverable operation identity.
public struct GraphV1BootstrapRequest: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let graphID: GraphID
    public let operationID: UUID
    public let backupRoot: URL
    public let reason: String
    /// Records caller-selected locations and identifiers without performing I/O.
    public init(sourceURL: URL, destinationURL: URL, graphID: GraphID, operationID: UUID, backupRoot: URL, reason: String) {
        self.sourceURL = sourceURL; self.destinationURL = destinationURL; self.graphID = graphID
        self.operationID = operationID; self.backupRoot = backupRoot; self.reason = reason
    }
    var native: GraphStoreMigrationRequest {
        .init(sourceURL: sourceURL, destinationURL: destinationURL, graphID: graphID,
              operationID: operationID, backupRoot: backupRoot, reason: reason)
    }
}

/// Committed conversion provenance and identity map, without native filesystem identities.
public struct GraphV1BootstrapReceipt: Sendable, Equatable {
    public let operationID: UUID
    public let graphID: GraphID
    public let sourceStoreID: String
    public let targetStoreID: String
    public let fingerprint: String
    public let nodeIDs: [String: GraphNodeID]
    init(_ receipt: GraphV1ConversionReceipt) {
        operationID = receipt.intent.operationID; graphID = receipt.intent.graphID
        sourceStoreID = receipt.intent.sourceStoreID; targetStoreID = receipt.targetStoreID
        fingerprint = receipt.intent.fingerprint; nodeIDs = receipt.nodeIDs
    }
}

/// A durable conversion outcome; cleanup warnings do not undo the committed receipt.
public struct GraphV1BootstrapConversion: Sendable {
    public let receipt: GraphV1BootstrapReceipt
    public let backupURL: URL
    public let cleanupPending: Bool
    public let cleanupFailure: (any Error)?
    init(_ result: GraphV1ConversionResult) {
        receipt = .init(result.receipt); backupURL = result.backupURL
        cleanupPending = result.cleanupPending; cleanupFailure = result.cleanupFailure
    }
}

/// Conversion commit and ordinary opening are independent outcomes.
public struct GraphV1BootstrapResult: Sendable {
    public let conversion: GraphV1BootstrapConversion
    public let opening: Result<GraphStore, any Error>
}

@available(iOS 17, macOS 14, *)
extension GraphContext {
    /// Converts a stopped supported source through native staged Core Data migration.
    /// Data remains a value; attachment optimization belongs to the consumer.
    public func openGraph(convertingLocalV1 request: GraphV1BootstrapRequest) async throws -> GraphV1BootstrapResult {
        try await openGraph(convertingLocalV1: request, recoveringOfflineGeneration: nil)
    }

    /// Supply an exact recovery generation only after stopping every process using the destination.
    public func openGraph(convertingLocalV1 request: GraphV1BootstrapRequest,
                          recoveringOfflineGeneration: UUID?) async throws -> GraphV1BootstrapResult {
        try Self.validateStoreURL(request.destinationURL)
        await manager.setLocalAccountAdapter(adapterForBootstrap)
        do {
            let result = try await manager.openPublicV1(request.native, recoveringOfflineGeneration: recoveringOfflineGeneration)
            if case .success(let graph) = result.opening { await graph.retainPublicContext(self, identity: identityForBootstrap) }
            await manager.releaseContextGraphIfIdle(request.graphID)
            return .init(conversion: .init(result.conversion), opening: result.opening)
        } catch {
            await manager.releaseContextGraphIfIdle(request.graphID)
            throw error
        }
    }
}

extension GraphContextManager {
    @available(iOS 17, macOS 14, *)
    func openPublicV1(_ request: GraphStoreMigrationRequest, recoveringOfflineGeneration: UUID? = nil) async throws -> GraphNativeV1BootstrapResult {
        guard adapter.nativeV1Migration != nil else { throw GraphStoreMigrationError.unavailable }
        return try await openGraph(migratingNativeV1: request, recoveringOfflineGeneration: recoveringOfflineGeneration)
    }
}

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    /// Prepares an immutable authoritative conversion seed from an explicit host cutover declaration.
    public func prepareActivation(for graphID: GraphID, activationID: UUID, zoneName: String,
                                  declaration: GraphCloudCutoverDeclaration) async throws -> GraphCloudActivationStatus {
        let config = try await ready()
        return try await operation {
            try await owningContext.manager.prepareCloudActivation(for: graphID, activationID: activationID,
                zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: zoneName), configuration: config, declaration: declaration)
        }
    }
    /// Advances recoverable server claim, bounded seed upload and authoritative publication.
    public func advanceActivation(for graphID: GraphID) async throws -> GraphCloudActivationResult {
        let config = try await ready()
        return try await operation { try await owningContext.manager.advanceCloudActivation(for: graphID, configuration: config) }
    }
    /// Returns durable activation phase separately from connection or peer readiness.
    public func activationStatus(for graphID: GraphID) async throws -> GraphCloudActivationStatus? {
        _ = try await ready()
        return try await operation { try await owningContext.manager.cloudActivationStatus(for: graphID) }
    }
    /// Recovers an exact authority into an empty or already-marked replica, preserving logical IDs.
    public func openReplica(id: GraphID, at storeURL: URL, zoneName: String) async throws -> GraphCloudReplicaResult {
        try GraphContext.validateStoreURL(storeURL)
        let config = try await ready()
        do {
            let result = try await owningContext.manager.openCloudReplica(id: id, at: storeURL,
                zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: zoneName), configuration: config)
            if case .success(let graph) = result.opening {
                await graph.retainPublicContext(owningContext, identity: owningContext.identityForBootstrap)
            }
            await owningContext.manager.releaseContextGraphIfIdle(id)
            return result
        } catch {
            await owningContext.manager.releaseContextGraphIfIdle(id)
            throw GraphCloudConnectionError.translate(error)
        }
    }
}
