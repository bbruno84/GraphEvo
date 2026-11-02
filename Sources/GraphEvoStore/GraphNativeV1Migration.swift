import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package struct GraphNativeV1MigrationAdapter: Sendable {
    package let inspect: @Sendable (NSManagedObjectContext, GraphID) throws -> GraphV1Snapshot
    package let plan: @Sendable (URL, GraphV1ConversionIntent, GraphV1Snapshot) throws -> StoreNativeMigration
    package init(inspect: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> GraphV1Snapshot,
                 plan: @escaping @Sendable (URL, GraphV1ConversionIntent, GraphV1Snapshot) throws -> StoreNativeMigration) {
        self.inspect = inspect; self.plan = plan
    }
}

extension GraphContextManager {
    /// Native staged conversion; property bytes are not accumulated into a graph-sized snapshot.
    @available(iOS 17, macOS 14, *)
    package func openGraph(migratingNativeV1 request: GraphStoreMigrationRequest) async throws -> GraphV1BootstrapResult {
        try Task.checkCancellation()
        guard let native = adapter.nativeV1Migration, let conversion = adapter.v1Conversion,
              schema.identifier == conversion.targetSchemaIdentifier else { throw GraphV1ConversionError.unavailable }
        let destination = try StoreRegistry.resolve(.init(location: .sqlite(request.destinationURL), exclusiveGraphID: request.graphID.rawValue))
        let source = try StoreRegistry.resolve(conversion.migrationSource.configuration(at: request.sourceURL))
        guard source.key != destination.key,
              case .sqlite(let sourceURL) = source.configuration.location,
              case .sqlite(let destinationURL) = destination.configuration.location else { throw GraphV1ConversionError.invalidRequest }
        guard !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.reason.utf8.count <= 4096 else {
            throw GraphV1ConversionError.invalidRequest
        }
        guard !blockedSharingGraphs.contains(request.graphID), localV1Bootstraps[request.graphID] == nil,
              !migratingStores.contains(request.graphID), entries[request.graphID] == nil,
              !localV1Bootstraps.values.contains(where: { $0.key == destination.key }) else { throw GraphV1ConversionError.busy }
        guard !entries.values.contains(where: { $0.key == destination.key }),
              !locations.contains(where: { $0.key != request.graphID && $0.value.key == destination.key }),
              locations[request.graphID] == nil || locations[request.graphID]?.key == destination.key else { throw GraphStoreError.ownershipConflict }
        let token = UUID()
        localV1Bootstraps[request.graphID] = .init(token: token, key: destination.key)
        defer { if localV1Bootstraps[request.graphID]?.token == token { localV1Bootstraps.removeValue(forKey: request.graphID) } }
        try await requireUnboundBootstrap(request.graphID)
        let file = try WorkspaceFileIdentity(sourceURL)
        let input = try await registry.open(source.configuration, schema: conversion.sourceSchema)
        var target: StoreHandle?
        var receipt: GraphV1ConversionReceipt?
        let backupURL = request.backupRoot.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(request.operationID.uuidString).appendingPathExtension("geb")
        do {
            let snapshot = try await input.read { try native.inspect($0, request.graphID) }
            let intent = GraphV1ConversionIntent(operationID: request.operationID, graphID: request.graphID, sourceFile: file, snapshot: snapshot)
            let exists = FileManager.default.fileExists(atPath: destinationURL.path)
            let metadata = exists ? try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: destinationURL) : [:]
            if exists, metadata[StoreNativeContext.workspaceKey] == nil {
                let handle = try await registry.open(destination.configuration, schema: schema); target = handle
                guard let existing = try await handle.read({ try conversion.receipt($0, request.graphID) }), existing.intent == intent else {
                    throw GraphV1ConversionError.conflictingDestination
                }
                receipt = existing
            } else {
                if exists {
                    guard metadata[StoreNativeContext.workspaceKey] as? String == request.operationID.uuidString,
                          metadata[StoreNativeMigration.documentKey] is Data else { throw GraphV1ConversionError.conflictingDestination }
                }
                let encoded = try intent.encoded()
                let reservation = try await input.reserveMaintenance()
                do {
                    _ = try await backups.create(for: request.graphID, storeID: snapshot.storeID, schema: conversion.sourceSchema.identifier,
                        in: request.backupRoot, reason: request.reason, artifacts: [.init(name: "__graphevo_v1Conversion.json", data: encoded)],
                        backupID: request.operationID, retentionOwner: request.operationID, immutableArtifact: "__graphevo_v1Conversion.json") {
                            try await input.copyStore(to: $0, reservation: reservation)
                        }
                    await reservation.release()
                } catch { await reservation.release(); throw error }
                guard try WorkspaceFileIdentity(sourceURL) == file else { throw GraphV1ConversionError.staleSource }
                let checked = try await input.read { try native.inspect($0, request.graphID) }
                guard checked.storeID == snapshot.storeID, checked.fingerprint == snapshot.fingerprint else { throw GraphV1ConversionError.staleSource }
                let seedDirectory = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".graphevo-native-v1-" + request.operationID.uuidString)
                let seed: URL
                if FileManager.default.fileExists(atPath: seedDirectory.path) {
                    seed = seedDirectory.appendingPathComponent("payload/Graph.sqlite")
                    let reader = try await registry.open(conversion.migrationSource.configuration(at: seed), schema: conversion.sourceSchema)
                    do {
                        let preserved = try await reader.read { try native.inspect($0, request.graphID) }
                        try await reader.close()
                        guard preserved.storeID == snapshot.storeID, preserved.fingerprint == snapshot.fingerprint else { throw GraphV1ConversionError.staleSource }
                    } catch { try? await reader.close(); throw error }
                } else { seed = try await backups.restore(at: backupURL, to: seedDirectory).storeURL }
                let plan = try native.plan(seed, intent, snapshot)
                let configuration = StoreConfiguration(location: .sqlite(destinationURL), exclusiveGraphID: request.graphID.rawValue,
                    workspaceID: request.operationID, workspaceSessionID: migrationIdentity)
                let handle = try await registry.open(configuration, schema: schema, nativeMigration: plan); target = handle
                let committed = try await Task.detached {
                    try await handle.controlRead { try conversion.receipt($0, request.graphID) }
                }.value
                guard let committed, committed.intent == intent else {
                    throw GraphV1ConversionError.invalidReceipt
                }
                receipt = committed
            }
        } catch {
            let failure = error
            var cleanup: (any Error)?
            do { try await target?.close() } catch { cleanup = error }
            do { try await input.close() } catch { cleanup = cleanup ?? error }
            if let cleanup { throw GraphStoreMigrationCleanupFailure(operationID: request.operationID, failure: failure, cleanupFailure: cleanup) }
            throw failure
        }
        guard let receipt else { throw GraphV1ConversionError.invalidReceipt }
        var cleanup: (any Error)?
        do { try await target?.close() } catch { cleanup = error }
        do { try await input.close() } catch { cleanup = cleanup ?? error }
        do { try await backups.releaseRetention(at: backupURL, owner: request.operationID) } catch { cleanup = cleanup ?? error }
        let result = GraphV1ConversionResult(receipt: receipt, backupURL: backupURL, cleanupPending: cleanup != nil, cleanupFailure: cleanup)
        do {
            try Task.checkCancellation(); try await requireUnboundBootstrap(request.graphID)
            let graph = try await openBootstrappedGraph(id: request.graphID, at: request.destinationURL, permit: token)
            do {
                try await graph.read { _ in () }; try await requireUnboundBootstrap(request.graphID)
                return .init(conversion: result, opening: .success(graph))
            } catch { let failure = error; try await graph.close(); throw failure }
        } catch { return .init(conversion: result, opening: .failure(error)) }
    }
}
