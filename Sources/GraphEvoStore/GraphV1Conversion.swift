import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphV1ConversionError: Error { case unavailable, busy, invalidRequest, unsupportedSource, limitExceeded, staleSource, conflictingDestination, invalidReceipt }
package struct GraphV1ConversionCleanupFailure: Error {
    package let operationID: UUID
    package let failure: any Error
    package let cleanupFailure: any Error
}
package struct GraphV1ConversionLimits: Sendable {
    package let maximumRecords: Int
    package let maximumNativeRows: Int
    package let maximumPayloadBytes: Int
    package init(maximumRecords: Int = 10_000, maximumNativeRows: Int = 100_000, maximumPayloadBytes: Int = 32 * 1024 * 1024) {
        self.maximumRecords = maximumRecords; self.maximumNativeRows = maximumNativeRows; self.maximumPayloadBytes = maximumPayloadBytes
    }
    package func validate() throws {
        guard (1...10_000).contains(maximumRecords), (1...100_000).contains(maximumNativeRows),
              (1...512 * 1024 * 1024).contains(maximumPayloadBytes) else { throw GraphV1ConversionError.limitExceeded }
    }
}
package struct GraphV1Snapshot: Sendable {
    package let storeID: String
    package let fingerprint: String
    package let records: [GraphRecord]
    package let nodeIDs: [String: GraphNodeID]
    package let propertyVersions: [GraphNodeID: [String: Int]]
    package init(storeID: String, fingerprint: String, records: [GraphRecord], nodeIDs: [String: GraphNodeID], propertyVersions: [GraphNodeID: [String: Int]] = [:]) {
        self.storeID = storeID; self.fingerprint = fingerprint; self.records = records; self.nodeIDs = nodeIDs; self.propertyVersions = propertyVersions
    }
}
package struct GraphV1ConversionIntent: Codable, Sendable, Equatable {
    package let format: Int
    package let operationID: UUID
    package let graphID: GraphID
    package let sourceStoreID: String
    package let sourceFile: WorkspaceFileIdentity
    package let fingerprint: String
    package init(operationID: UUID, graphID: GraphID, sourceFile: WorkspaceFileIdentity, snapshot: GraphV1Snapshot) {
        self.format = 1; self.operationID = operationID; self.graphID = graphID; self.sourceStoreID = snapshot.storeID
        self.sourceFile = sourceFile; self.fingerprint = snapshot.fingerprint
    }
    package func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
}
package struct GraphV1ConversionReceipt: Codable, Sendable, Equatable {
    package let intent: GraphV1ConversionIntent
    package let targetStoreID: String
    package let nodeIDs: [String: GraphNodeID]
    package init(intent: GraphV1ConversionIntent, targetStoreID: String, nodeIDs: [String: GraphNodeID]) {
        self.intent = intent; self.targetStoreID = targetStoreID; self.nodeIDs = nodeIDs
    }
}
package struct GraphV1ConversionResult: Sendable {
    package let receipt: GraphV1ConversionReceipt
    package let backupURL: URL
    /// Data is committed even when native detachment or backup unpin needs later recovery.
    package let cleanupPending: Bool
    package let cleanupFailure: (any Error)?
}
package struct GraphV1ConversionAdapter: Sendable {
    package let targetSchemaIdentifier: String
    package let sourceSchema: StoreSchema
    package let snapshot: @Sendable (NSManagedObjectContext, GraphID, GraphV1ConversionLimits) throws -> GraphV1Snapshot
    package let receipt: @Sendable (NSManagedObjectContext, GraphID) throws -> GraphV1ConversionReceipt?
    package let apply: @Sendable (NSManagedObjectContext, GraphV1ConversionIntent, GraphV1Snapshot) throws -> GraphV1ConversionReceipt
    package init(sourceSchema: StoreSchema, targetSchemaIdentifier: String,
                 snapshot: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphV1ConversionLimits) throws -> GraphV1Snapshot,
                 receipt: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> GraphV1ConversionReceipt?,
                 apply: @escaping @Sendable (NSManagedObjectContext, GraphV1ConversionIntent, GraphV1Snapshot) throws -> GraphV1ConversionReceipt) {
        self.sourceSchema = sourceSchema; self.targetSchemaIdentifier = targetSchemaIdentifier; self.snapshot = snapshot; self.receipt = receipt; self.apply = apply
    }
}

extension GraphV1ConversionAdapter {
    var backupValidator: GraphBackupManager.Validator {
        let conversion = self
        return { url, id in
            let handle = try await StoreRegistry.shared.open(.init(location: .sqlite(url), access: .readOnly, legacyReadOnly: true), schema: conversion.sourceSchema)
            do {
                let identity = try await handle.read { try conversion.snapshot($0, id, .init(maximumPayloadBytes: 512 * 1024 * 1024)).storeID }
                try await handle.close(); return identity
            } catch {
                let failure = error; do { try await handle.close() } catch { throw error }; throw failure
            }
        }
    }
}

extension GraphContextManager {
    /// Explicit stopped-writer local conversion. Source and destination are distinct; no cloud session is started.
    package func convertLocalV1Store(at sourceURL: URL, to destinationURL: URL, graphID: GraphID, operationID: UUID,
        backupsIn backupRoot: URL, reason: String = "Before local v1 to v2 conversion",
        limits: GraphV1ConversionLimits = .init()) async throws -> GraphV1ConversionResult {
        try limits.validate()
        guard let conversion = adapter.v1Conversion, schema.identifier == conversion.targetSchemaIdentifier else { throw GraphV1ConversionError.unavailable }
        guard convertingV1.insert(graphID).inserted else { throw GraphV1ConversionError.busy }
        defer { convertingV1.remove(graphID) }
        let source = try StoreRegistry.resolve(.init(location: .sqlite(sourceURL), access: .readOnly, legacyReadOnly: true))
        let destination = try StoreRegistry.resolve(.init(location: .sqlite(destinationURL), exclusiveGraphID: graphID.rawValue))
        guard source.key != destination.key, case .sqlite(let sourceURL) = source.configuration.location,
              case .sqlite(let destinationURL) = destination.configuration.location,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.utf8.count <= 4096 else { throw GraphV1ConversionError.invalidRequest }
        let sourceFile = try WorkspaceFileIdentity(sourceURL)
        let input = try await registry.open(source.configuration, schema: conversion.sourceSchema)
        var target: StoreHandle?, committed: GraphV1ConversionReceipt?
        do {
            let snapshot = try await input.read { try conversion.snapshot($0, graphID, limits) }
            let intent = GraphV1ConversionIntent(operationID: operationID, graphID: graphID, sourceFile: sourceFile, snapshot: snapshot)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let handle = try await registry.open(destination.configuration, schema: schema); target = handle
                if let existing = try await handle.read({ try conversion.receipt($0, graphID) }) {
                    guard existing.intent == intent, Set(existing.nodeIDs.keys) == Set(snapshot.nodeIDs.keys) else { throw GraphV1ConversionError.conflictingDestination }
                    committed = existing
                }
            }
            if committed == nil {
                let reservation = try await input.reserveMaintenance()
                do {
                    _ = try await backups.create(for: graphID, storeID: snapshot.storeID, schema: conversion.sourceSchema.identifier,
                        in: backupRoot, reason: reason, artifacts: [.init(name: "__graphevo_v1Conversion.json", data: try intent.encoded())],
                        backupID: operationID, retentionOwner: operationID, immutableArtifact: "__graphevo_v1Conversion.json") { url in
                            try await input.copyStore(to: url, reservation: reservation)
                        }
                    await reservation.release()
                } catch { await reservation.release(); throw error }
                guard try WorkspaceFileIdentity(sourceURL) == sourceFile else { throw GraphV1ConversionError.staleSource }
                let current = try await input.read { try conversion.snapshot($0, graphID, limits) }
                guard current.storeID == snapshot.storeID, current.fingerprint == snapshot.fingerprint else { throw GraphV1ConversionError.staleSource }
                if target == nil { target = try await registry.open(destination.configuration, schema: schema) }
                guard let target else { throw GraphV1ConversionError.invalidRequest }
                committed = try await target.transaction { try conversion.apply($0, intent, snapshot) }
            }
            guard let committed else { throw GraphV1ConversionError.invalidReceipt }
            // Native commit is authoritative. Cancellation or cleanup cannot change its outcome.
            var cleanup: (any Error)?
            do { try await target?.close() } catch { cleanup = error }
            do { try await input.close() } catch { cleanup = cleanup ?? error }
            let backupURL = backupRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(operationID.uuidString).appendingPathExtension("geb")
            do { try await backups.releaseRetention(at: backupURL, owner: operationID) } catch { cleanup = cleanup ?? error }
            return .init(receipt: committed, backupURL: backupURL, cleanupPending: cleanup != nil, cleanupFailure: cleanup)
        } catch {
            let failure = error
            var cleanup: (any Error)?
            do { try await target?.close() } catch { cleanup = error }
            do { try await input.close() } catch { cleanup = cleanup ?? error }
            if let cleanup { throw GraphV1ConversionCleanupFailure(operationID: operationID, failure: failure, cleanupFailure: cleanup) }
            throw failure
        }
    }
}
