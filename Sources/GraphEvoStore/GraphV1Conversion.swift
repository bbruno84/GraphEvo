import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

// Existing v1 names remain source aliases; persisted intent/receipt formats are unchanged.
package typealias GraphV1ConversionError = GraphStoreMigrationError
package typealias GraphV1ConversionCleanupFailure = GraphStoreMigrationCleanupFailure
package typealias GraphV1ConversionLimits = GraphStoreMigrationLimits
package typealias GraphV1ConversionResult = GraphStoreMigrationResult<GraphV1ConversionReceipt>

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
    package var migrationSource: GraphStoreMigrationSource {
        let conversion = self
        return GraphStoreMigrationSource(schema: sourceSchema, legacyReadOnly: true) { context, id in
            try conversion.snapshot(context, id, .init(maximumPayloadBytes: 512 * 1024 * 1024)).storeID
        }
    }
    var migration: GraphStoreMigrationDefinition<GraphV1Snapshot, GraphV1ConversionIntent, GraphV1ConversionReceipt> {
        GraphStoreMigrationDefinition(source: migrationSource, targetSchemaIdentifier: targetSchemaIdentifier,
            backupArtifactName: "__graphevo_v1Conversion.json", inspect: snapshot,
            sourceState: { .init(storeID: $0.storeID, fingerprint: $0.fingerprint) },
            makeIntent: { .init(operationID: $0, graphID: $1, sourceFile: $2, snapshot: $3) },
            encodeIntent: { try $0.encoded() }, readReceipt: receipt,
            validateReceipt: { receipt, intent, snapshot in
                guard receipt.intent == intent, Set(receipt.nodeIDs.keys) == Set(snapshot.nodeIDs.keys) else {
                    throw GraphStoreMigrationError.conflictingDestination
                }
            }, apply: apply)
    }
}

extension GraphContextManager {
    /// Executes the concrete v1 recipe through the shared internal migration sequence.
    package func convertLocalV1Store(at sourceURL: URL, to destinationURL: URL, graphID: GraphID, operationID: UUID,
        backupsIn backupRoot: URL, reason: String = "Before local v1 to v2 conversion",
        limits: GraphV1ConversionLimits = .init()) async throws -> GraphV1ConversionResult {
        guard let conversion = adapter.v1Conversion else { throw GraphV1ConversionError.unavailable }
        return try await migrateStore(using: conversion.migration, request: .init(sourceURL: sourceURL,
            destinationURL: destinationURL, graphID: graphID, operationID: operationID, backupRoot: backupRoot, reason: reason), limits: limits)
    }
}
