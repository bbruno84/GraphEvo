import Foundation
import GraphEvoModel

extension GraphContextManager {
    /// Validate the sealed graph, verify a complete original backup, then make one local atomic commit.
    /// Success releases only this workspace's source holds; cloud delivery remains separately observable.
    package func publishMigrationWorkspace(_ workspace: GraphMigrationWorkspace, backupsIn root: URL,
        reason: String? = nil, limits: GraphMigrationPublicationLimits = .init()) async throws -> GraphMigrationPublicationResult {
        try limits.validate()
        guard workspace.managerID == migrationIdentity else { throw GraphStoreError.ownershipConflict }
        guard publishingMigrations.insert(workspace.descriptor.graphID).inserted else { throw GraphMigrationPublicationError.busy }
        defer { publishingMigrations.remove(workspace.descriptor.graphID) }
        return try await workspace.publish { [self] seal in
            try await publish(workspace, seal: seal, backupsIn: root, reason: reason, limits: limits)
        }
    }

    private func publish(_ workspace: GraphMigrationWorkspace, seal: GraphMigrationChangeSet, backupsIn root: URL,
                         reason: String?, limits: GraphMigrationPublicationLimits) async throws -> GraphMigrationPublicationResult {
        let descriptor = workspace.descriptor, id = descriptor.graphID
        guard let location = locations[id], let publication = adapter.publication else { throw GraphMigrationPublicationError.unavailable }
        let retained = try await openGraph(id: id, at: location.url)
        do {
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            guard try WorkspaceFileIdentity(location.url) == descriptor.sourceFile,
                  try await owner.storeIdentity() == descriptor.source.storeID else { throw GraphMigrationWorkspaceError.staleSource }
            let known = await workspace.committedPublication()
            if let existing = try await owner.publicationReceipt(for: descriptor.id) ?? known {
                try existing.validate(seal, storeID: descriptor.source.storeID)
                let result = await finishPublication(existing, in: root)
                try? await retained.close()
                return result
            }
            try await owner.preflightPublication(descriptor, seal: seal)
            let items = try await workspace.publicationItems(seal, adapter: publication, limits: limits)
            let intent = try await workspace.publicationIntent(seal, reason: reason)
            let backup = try await snapshotBackup(for: id, in: root, reason: intent.reason,
                artifacts: [.init(name: "__graphevo_publication.json", data: try intent.encoded())],
                backupID: intent.backupID, retentionOwner: descriptor.id)
            guard backup.manifest.id == intent.backupID, backup.manifest.nativeStoreID == descriptor.source.storeID,
                  backup.manifest.graphID == id else { throw GraphBackupError.invalidBackup }
            let maintenance = try await owner.reserveMaintenance()
            let receipt: GraphMigrationPublicationReceipt
            do {
                receipt = try await owner.publish(descriptor, seal: seal, intent: intent, items: items, reservation: maintenance)
                await maintenance.release()
            } catch { await maintenance.release(); throw error }
            // No cancellation check follows the native commit. Cleanup cannot turn a committed publication into failure.
            let result = await finishPublication(receipt, in: root)
            try? await retained.close()
            return result
        } catch {
            let original = error; try? await retained.close(); throw original
        }
    }

    private func finishPublication(_ receipt: GraphMigrationPublicationReceipt, in root: URL) async -> GraphMigrationPublicationResult {
        let url = root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(receipt.backupID.uuidString).appendingPathExtension("geb")
        var pending = false
        do { try await backups.releaseRetention(at: url, owner: receipt.workspaceID) }
        catch { pending = true }
        return GraphMigrationPublicationResult(receipt: receipt, backupURL: url, backupRetentionPending: pending)
    }
}
