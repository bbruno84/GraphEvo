import Foundation
import GraphEvoModel
import GraphEvoRuntime

extension GraphContextManager {
    func claimContextGraph(_ id: GraphID, resolved: (key: StoreKey, configuration: StoreConfiguration)) async throws {
        guard let contextOwnerID else { return }
        if let closing = contextClaimClosing[id] { await closing.value }
        if contextClaims[id] == nil {
            contextClaims[id] = try await registry.claimContextGraph(id.rawValue, key: resolved.key, owner: contextOwnerID)
        }
    }

    func releaseContextGraphIfIdle(_ id: GraphID) async {
        guard entries[id] == nil, localV1Bootstraps[id] == nil,
              !migratingStores.contains(id), !activatingCloudGraphs.contains(id),
              let token = contextClaims.removeValue(forKey: id) else { return }
        let registry = registry
        let task = Task { await registry.releaseContextGraph(token) }
        contextClaimClosing[id] = task
        await task.value
        contextClaimClosing.removeValue(forKey: id)
    }
}
