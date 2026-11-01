import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphStoreMigrationError: Error { case unavailable, busy, invalidRequest, unsupportedSource, limitExceeded, staleSource, conflictingDestination, invalidReceipt }
package struct GraphStoreMigrationCleanupFailure: Error {
    package let operationID: UUID
    package let failure: any Error
    package let cleanupFailure: any Error
}
/// Bounds for a single atomic conversion into a distinct store.
package struct GraphStoreMigrationLimits: Sendable {
    package let maximumRecords: Int
    package let maximumNativeRows: Int
    package let maximumPayloadBytes: Int
    package init(maximumRecords: Int = 10_000, maximumNativeRows: Int = 100_000, maximumPayloadBytes: Int = 32 * 1024 * 1024) {
        self.maximumRecords = maximumRecords; self.maximumNativeRows = maximumNativeRows; self.maximumPayloadBytes = maximumPayloadBytes
    }
    package func validate() throws {
        guard (1...10_000).contains(maximumRecords), (1...100_000).contains(maximumNativeRows),
              (1...512 * 1024 * 1024).contains(maximumPayloadBytes) else { throw GraphStoreMigrationError.limitExceeded }
    }
}
/// Current caller-supplied locations, never a persistent migration journal.
package struct GraphStoreMigrationRequest: Sendable {
    package let sourceURL: URL
    package let destinationURL: URL
    package let graphID: GraphID
    package let operationID: UUID
    package let backupRoot: URL
    package let reason: String
    package init(sourceURL: URL, destinationURL: URL, graphID: GraphID, operationID: UUID, backupRoot: URL, reason: String) {
        self.sourceURL = sourceURL; self.destinationURL = destinationURL; self.graphID = graphID
        self.operationID = operationID; self.backupRoot = backupRoot; self.reason = reason
    }
}
package struct GraphStoreMigrationSourceState: Sendable, Equatable {
    package let storeID: String
    package let fingerprint: String
    package init(storeID: String, fingerprint: String) { self.storeID = storeID; self.fingerprint = fingerprint }
}
/// One explicitly supported physical source and its backup validator, selected by the runtime factory.
package struct GraphStoreMigrationSource: Sendable {
    package let schema: StoreSchema
    package let legacyReadOnly: Bool
    package let validateBackup: @Sendable (NSManagedObjectContext, GraphID) throws -> String
    package init(schema: StoreSchema, legacyReadOnly: Bool = false,
                 validateBackup: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> String) {
        self.schema = schema; self.legacyReadOnly = legacyReadOnly; self.validateBackup = validateBackup
    }
    func configuration(at url: URL) -> StoreConfiguration {
        .init(location: .sqlite(url), access: .readOnly, legacyReadOnly: legacyReadOnly)
    }
    func matches(_ other: Self) -> Bool {
        schema.identifier == other.schema.identifier && schema.entityVersionHashes == other.schema.entityVersionHashes &&
        schema.requiredModelVersionIdentifier == other.schema.requiredModelVersionIdentifier && legacyReadOnly == other.legacyReadOnly
    }
    var backupValidator: GraphBackupManager.Validator {
        let source = self
        return { url, id in
            let handle = try await StoreRegistry.shared.open(source.configuration(at: url), schema: source.schema)
            do {
                let identity = try await handle.read { try source.validateBackup($0, id) }
                try await handle.close(); return identity
            } catch {
                let failure = error; do { try await handle.close() } catch { throw error }; throw failure
            }
        }
    }
}
package struct GraphStoreMigrationResult<Receipt: Sendable>: Sendable {
    package let receipt: Receipt
    package let backupURL: URL
    /// A cleanup error never changes the fact that the destination commit succeeded.
    package let cleanupPending: Bool
    package let cleanupFailure: (any Error)?
}

/// A concrete internal source-to-destination conversion, not a migration registry or consumer callback API.
/// Closures are synchronous trusted adapters; they cannot save, escape contexts or perform external writes.
package struct GraphStoreMigrationDefinition<Snapshot: Sendable, Intent: Sendable, Receipt: Sendable>: Sendable {
    package let source: GraphStoreMigrationSource
    package let targetSchemaIdentifier: String
    package let backupArtifactName: String
    package let inspect: @Sendable (NSManagedObjectContext, GraphID, GraphStoreMigrationLimits) throws -> Snapshot
    package let sourceState: @Sendable (Snapshot) -> GraphStoreMigrationSourceState
    package let makeIntent: @Sendable (UUID, GraphID, WorkspaceFileIdentity, Snapshot) throws -> Intent
    package let encodeIntent: @Sendable (Intent) throws -> Data
    package let readReceipt: @Sendable (NSManagedObjectContext, GraphID) throws -> Receipt?
    package let validateReceipt: @Sendable (Receipt, Intent, Snapshot) throws -> Void
    package let apply: @Sendable (NSManagedObjectContext, Intent, Snapshot) throws -> Receipt

    package init(source: GraphStoreMigrationSource, targetSchemaIdentifier: String, backupArtifactName: String,
        inspect: @escaping @Sendable (NSManagedObjectContext, GraphID, GraphStoreMigrationLimits) throws -> Snapshot,
        sourceState: @escaping @Sendable (Snapshot) -> GraphStoreMigrationSourceState,
        makeIntent: @escaping @Sendable (UUID, GraphID, WorkspaceFileIdentity, Snapshot) throws -> Intent,
        encodeIntent: @escaping @Sendable (Intent) throws -> Data,
        readReceipt: @escaping @Sendable (NSManagedObjectContext, GraphID) throws -> Receipt?,
        validateReceipt: @escaping @Sendable (Receipt, Intent, Snapshot) throws -> Void,
        apply: @escaping @Sendable (NSManagedObjectContext, Intent, Snapshot) throws -> Receipt) {
        self.source = source; self.targetSchemaIdentifier = targetSchemaIdentifier; self.backupArtifactName = backupArtifactName
        self.inspect = inspect; self.sourceState = sourceState; self.makeIntent = makeIntent; self.encodeIntent = encodeIntent
        self.readReceipt = readReceipt; self.validateReceipt = validateReceipt; self.apply = apply
    }
    func inspectSource(_ context: NSManagedObjectContext, graphID: GraphID, limits: GraphStoreMigrationLimits) throws -> (Snapshot, GraphStoreMigrationSourceState) {
        let snapshot = try inspect(context, graphID, limits), state = sourceState(snapshot)
        guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
              let store = coordinator.persistentStores.first, store.isReadOnly,
              coordinator.metadata(for: store)[NSStoreUUIDKey] as? String == state.storeID,
              !state.storeID.isEmpty, !state.fingerprint.isEmpty, state.fingerprint.utf8.count <= 4096 else { throw GraphStoreMigrationError.unsupportedSource }
        return (snapshot, state)
    }
}

extension GraphContextManager {
    /// Executes one explicit stopped-source migration before the destination enters ordinary graph use.
    package func migrateStore<Snapshot, Intent, Receipt>(using migration: GraphStoreMigrationDefinition<Snapshot, Intent, Receipt>,
        request: GraphStoreMigrationRequest, limits: GraphStoreMigrationLimits = .init()) async throws -> GraphStoreMigrationResult<Receipt> {
        try limits.validate()
        guard let configured = adapter.migrationSource, configured.matches(migration.source),
              schema.identifier == migration.targetSchemaIdentifier else { throw GraphStoreMigrationError.unavailable }
        guard migratingStores.insert(request.graphID).inserted else { throw GraphStoreMigrationError.busy }
        defer { migratingStores.remove(request.graphID) }
        let source = try StoreRegistry.resolve(migration.source.configuration(at: request.sourceURL))
        let destination = try StoreRegistry.resolve(.init(location: .sqlite(request.destinationURL), exclusiveGraphID: request.graphID.rawValue))
        let artifact = migration.backupArtifactName
        guard source.key != destination.key, case .sqlite(let sourceURL) = source.configuration.location,
              case .sqlite(let destinationURL) = destination.configuration.location,
              !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.reason.utf8.count <= 4096,
              artifact.hasPrefix("__graphevo_"), artifact.utf8.count <= 128,
              !artifact.contains("/"), !artifact.contains("\\"), !artifact.contains("..") else { throw GraphStoreMigrationError.invalidRequest }
        let sourceFile = try WorkspaceFileIdentity(sourceURL)
        let input = try await registry.open(source.configuration, schema: migration.source.schema)
        var target: StoreHandle?, committed: Receipt?
        do {
            let (snapshot, state) = try await input.read { try migration.inspectSource($0, graphID: request.graphID, limits: limits) }
            let intent = try migration.makeIntent(request.operationID, request.graphID, sourceFile, snapshot)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let handle = try await registry.open(destination.configuration, schema: schema); target = handle
                if let existing = try await handle.read({ try migration.readReceipt($0, request.graphID) }) {
                    try migration.validateReceipt(existing, intent, snapshot); committed = existing
                }
            }
            if committed == nil {
                let encoded = try migration.encodeIntent(intent)
                guard encoded.count <= 16 * 1024 else { throw GraphStoreMigrationError.limitExceeded }
                let reservation = try await input.reserveMaintenance()
                do {
                    _ = try await backups.create(for: request.graphID, storeID: state.storeID, schema: migration.source.schema.identifier,
                        in: request.backupRoot, reason: request.reason, artifacts: [.init(name: artifact, data: encoded)],
                        backupID: request.operationID, retentionOwner: request.operationID, immutableArtifact: artifact) { url in
                            try await input.copyStore(to: url, reservation: reservation)
                        }
                    await reservation.release()
                } catch { await reservation.release(); throw error }
                guard try WorkspaceFileIdentity(sourceURL) == sourceFile else { throw GraphStoreMigrationError.staleSource }
                let (_, current) = try await input.read { try migration.inspectSource($0, graphID: request.graphID, limits: limits) }
                guard current == state else { throw GraphStoreMigrationError.staleSource }
                if target == nil { target = try await registry.open(destination.configuration, schema: schema) }
                guard let target else { throw GraphStoreMigrationError.invalidRequest }
                committed = try await target.transaction {
                    let receipt = try migration.apply($0, intent, snapshot)
                    try migration.validateReceipt(receipt, intent, snapshot)
                    return receipt
                }
            }
            guard let committed else { throw GraphStoreMigrationError.invalidReceipt }
            // Native commit remains authoritative after cancellation or cleanup failure.
            var cleanup: (any Error)?
            do { try await target?.close() } catch { cleanup = error }
            do { try await input.close() } catch { cleanup = cleanup ?? error }
            let backupURL = request.backupRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(request.operationID.uuidString).appendingPathExtension("geb")
            do { try await backups.releaseRetention(at: backupURL, owner: request.operationID) } catch { cleanup = cleanup ?? error }
            return .init(receipt: committed, backupURL: backupURL, cleanupPending: cleanup != nil, cleanupFailure: cleanup)
        } catch {
            let failure = error
            var cleanup: (any Error)?
            do { try await target?.close() } catch { cleanup = error }
            do { try await input.close() } catch { cleanup = cleanup ?? error }
            if let cleanup { throw GraphStoreMigrationCleanupFailure(operationID: request.operationID, failure: failure, cleanupFailure: cleanup) }
            throw failure
        }
    }
}
