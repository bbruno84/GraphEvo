import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// A successful conversion and its separate ordinary-opening outcome.
/// A failed opening never implies that committed conversion effects were rolled back.
package struct GraphNativeV1BootstrapResult: Sendable {
    package let conversion: GraphV1ConversionResult
    package let opening: Result<GraphStore, any Error>
}

extension GraphContextManager {
    /// Uses native staged conversion where supported; the retained bounded recipe
    /// remains explicit through the overload that takes limits.
    package func openGraph(convertingLocalV1 request: GraphStoreMigrationRequest) async throws -> GraphNativeV1BootstrapResult {
        if #available(iOS 17, macOS 14, *), adapter.nativeV1Migration != nil {
            return try await openGraph(migratingNativeV1: request)
        }
        return try await openGraph(convertingLocalV1: request, limits: .init())
    }

    /// Explicitly converts or recovers one stopped local v1 source and opens its distinct native target.
    /// The caller retains request IDs/current URLs and must not configure cloud for this graph concurrently.
    /// No handle is exposed until verified conversion and ordinary native opening both succeed.
    package func openGraph(convertingLocalV1 request: GraphStoreMigrationRequest,
                           limits: GraphV1ConversionLimits) async throws -> GraphNativeV1BootstrapResult {
        try Task.checkCancellation()
        try limits.validate()
        guard let conversion = adapter.v1Conversion, schema.identifier == conversion.targetSchemaIdentifier else {
            throw GraphV1ConversionError.unavailable
        }
        let resolved = try StoreRegistry.resolve(.init(location: .sqlite(request.destinationURL), exclusiveGraphID: request.graphID.rawValue, contextOwnerID: contextOwnerID))
        guard !blockedSharingGraphs.contains(request.graphID) else { throw GraphCloudError.zoneUnavailable }
        guard localV1Bootstraps[request.graphID] == nil, !migratingStores.contains(request.graphID), entries[request.graphID] == nil,
              !localV1Bootstraps.values.contains(where: { $0.key == resolved.key }) else { throw GraphV1ConversionError.busy }
        guard !entries.values.contains(where: { $0.key == resolved.key }),
              !locations.contains(where: { $0.key != request.graphID && $0.value.key == resolved.key }),
              locations[request.graphID] == nil || locations[request.graphID]?.key == resolved.key else {
            throw GraphStoreError.ownershipConflict
        }
        try await claimContextGraph(request.graphID, resolved: resolved)
        let token = UUID()
        localV1Bootstraps[request.graphID] = .init(token: token, key: resolved.key)
        defer {
            if localV1Bootstraps[request.graphID]?.token == token { localV1Bootstraps.removeValue(forKey: request.graphID) }
        }
        try await requireUnboundBootstrap(request.graphID)
        let result = try await performStoreMigration(using: conversion.migration, request: request, limits: limits)
        // From here the receipt proves commit. Preserve it even after cancellation,
        // failed native cleanup or unsuccessful post-conversion availability checks.
        var graph: GraphStore?
        do {
            try Task.checkCancellation()
            try await requireUnboundBootstrap(request.graphID)
            let opened = try await openBootstrappedGraph(id: request.graphID, at: request.destinationURL, permit: token)
            graph = opened
            // Ordinary opening can retain a stored participation's data gate.
            // Verify consumer read admission before reporting local availability.
            try await opened.read { _ in () }
            try await requireUnboundBootstrap(request.graphID)
            return .init(conversion: result, opening: .success(opened))
        } catch {
            let openingFailure = error
            do { try await graph?.close() }
            catch {
                return .init(conversion: result, opening: .failure(GraphStoreMigrationCleanupFailure(
                    operationID: request.operationID, failure: openingFailure, cleanupFailure: error)))
            }
            return .init(conversion: result, opening: .failure(openingFailure))
        }
    }
}
