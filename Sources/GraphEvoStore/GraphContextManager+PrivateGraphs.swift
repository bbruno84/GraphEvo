import Foundation
import GraphEvoModel
import GraphEvoRuntime

extension GraphContextManager {
    func openPrivateGraph(_ reference: GraphCloudPrivateGraph, at url: URL,
                          configuration: GraphCloudConfiguration) async throws -> GraphStore {
        let session = try await cloud(configuration), route = reference.binding, id = reference.id
        guard try await session.identity() == reference.identity else { throw GraphCloudError.accountChanged }
        let discovered = try await session.discoverPrivateGraphs(prefix: reference.zoneName)
        guard discovered.graphs.contains(reference) else { throw GraphCloudDiscoveryError.invalidDescriptor }
        // Converted v1 graphs retain their authoritative recovery protocol.
        let authority = try await session.activationControl { service, _ in try await service.fetch(configuration, route) }
        if authority != nil {
            return try await openCloudReplica(id: id, at: url, zone: route.zone, configuration: configuration).opening.get()
        }
        guard entries[id] == nil, localV1Bootstraps[id] == nil, !migratingStores.contains(id),
              activatingCloudGraphs.insert(id).inserted else { throw GraphCloudDiscoveryError.busy }
        defer { activatingCloudGraphs.remove(id); automaticChanged() }
        let resolved = try StoreRegistry.resolve(graphStoreConfiguration(id, at: url))
        try await claimContextGraph(id, resolved: resolved)
        let permit = UUID(), creating = !FileManager.default.fileExists(atPath: url.path)
        localV1Bootstraps[id] = .init(token: permit, key: resolved.key)
        defer { if localV1Bootstraps[id]?.token == permit { localV1Bootstraps.removeValue(forKey: id) } }
        let graph = try await openActivationReplica(id: id, at: url, permit: permit, creating: creating)
        var operationID = permit
        do {
            guard let entry = entries[id] else { throw GraphStoreError.missingGraph }
            let owner = try await entry.opening.value
            let prior = try await owner.privateReplicaState()
            guard creating || prior != nil else { throw GraphCloudSharingError.nonemptyReplica }
            let binding = GraphCloudTransportBinding(identity: reference.identity, route: route)
            let state = try await owner.preparePrivateReplica(binding, operation: permit)
            operationID = state.operationID
            try await claimCloudAccount(reference.identity, for: id, owner: owner)
            if !state.ready {
                try await owner.activationAccess(state.operationID, peer: true)
                try await session.bindPrivateReplica(route, operation: state.operationID, ready: false)
                try await session.activationControl { service, _ in
                    // An authority appearing after discovery must not be treated as ordinary data.
                    guard try await service.fetch(configuration, route) == nil else { throw GraphCloudActivationError.recoveryRequired }
                    let limits = GraphCloudActivationLimits()
                    let inventory = try await service.inventory(configuration, reference.identity, route, limits)
                    let manifest = try await Self.seedManifest(inventory, session: session, binding: route, authority: nil, limits: limits)
                    let previous = try await owner.privateReplicaIDs()
                    try await Self.importActivationInventory(inventory, manifest: manifest, previous: previous,
                        session: session, graph: graph, binding: binding, activationID: state.operationID, configuration: configuration)
                }
                _ = try await owner.validateActivationReplica()
                guard try await graph.collectSyncChanges() == 0 else { throw GraphSyncError.pendingImport }
                try await owner.completePrivateReplica(state.operationID)
            }
            try await session.bindPrivateReplica(route, operation: state.operationID, ready: true)
            try await owner.activationAccess(state.operationID, peer: true, release: true)
            return graph
        } catch {
            let original = error
            do { try await graph.close() }
            catch { throw GraphStoreMigrationCleanupFailure(operationID: operationID, failure: original, cleanupFailure: error) }
            throw original
        }
    }
}
