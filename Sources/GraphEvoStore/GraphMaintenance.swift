import Foundation
import GraphEvoModel
import GraphEvoRuntime

enum GraphLocalAdmission {
    static func isReserved(_ error: any Error) -> Bool {
        switch error {
        case StoreRuntimeError.writesSuspended, StoreRuntimeError.resourceReserved,
             GraphStoreError.writesSuspended, GraphStoreError.resourceReserved: return true
        default: return false
        }
    }
}

extension GraphContextManager {
    /// Reject new writers across all handles, then drain every writer already admitted.
    package func suspendLocalWrites(for id: GraphID) async throws -> StoreReservation {
        guard let location = locations[id] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: id, at: location.url)
        do {
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let reservation = try await entry.opening.value.suspendLocalWrites()
            return StoreReservation(id: UUID()) { await reservation.release(); try? await graph.close() }
        } catch { let original = error; try? await graph.close(); throw original }
    }

    package func createBackup(for id: GraphID, in root: URL, reason: String? = nil,
                              artifacts: [GraphBackupArtifact] = []) async throws -> GraphBackup {
        guard !artifacts.contains(where: { $0.name.hasPrefix("__graphevo_") }) else { throw GraphBackupError.invalidBackup }
        return try await snapshotBackup(for: id, in: root, reason: reason, artifacts: artifacts)
    }

    func snapshotBackup(for id: GraphID, in root: URL, reason: String?, artifacts: [GraphBackupArtifact],
                        backupID: UUID? = nil, retentionOwner: UUID? = nil) async throws -> GraphBackup {
        guard let location = locations[id] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: id, at: location.url)
        var cloudHold: StoreReservation?, localHold: StoreReservation?
        do {
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            let storeID = try await owner.storeIdentity()
            cloudHold = try await reserveCloudPause(for: id)
            localHold = try await owner.reserveMaintenance()
            let held = localHold!, cloudReservation = cloudHold!
            var captured = artifacts
            for (index, configuration) in activeCloudConfigurations().sorted(by: { $0.namespace < $1.namespace }).enumerated() {
                if let data = try await cloud(configuration).backupSnapshot(for: id) {
                    captured.append(.init(name: "__graphevo_cloud_\(index).json", data: data))
                }
            }
            let result = try await backups.create(for: id, storeID: storeID, schema: schema.identifier,
                in: root, reason: reason, artifacts: captured, backupID: backupID, retentionOwner: retentionOwner) { url in
                    try await owner.copyStore(to: url, reservation: held)
                    await held.release(); await cloudReservation.release()
                }
            await localHold?.release(); await cloudHold?.release(); try await graph.close()
            return result
        } catch {
            let original = error
            await localHold?.release(); await cloudHold?.release(); try? await graph.close()
            throw original
        }
    }
}
