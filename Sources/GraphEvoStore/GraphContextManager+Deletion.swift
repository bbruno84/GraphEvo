import Foundation
import GraphEvoModel
import GraphEvoRuntime

extension GraphContextManager {
    func deleteGraph(_ id: GraphID, configuration cloudConfig: GraphCloudConfiguration?) async throws -> GraphDeletionStatus {
        guard let entry = entries[id], entry.closing == nil, let location = locations[id] else { throw GraphStoreError.missingGraph }
        let owner = try await entry.opening.value
        let config = graphStoreConfiguration(id, at: location.url)
        if let intent = try await GraphDeletionIntent.read(config) {
            return try await runGraphDeletion(intent, at: location.url, configuration: cloudConfig)
        }
        guard !migratingStores.contains(id), !activatingCloudGraphs.contains(id), localV1Bootstraps[id] == nil,
              !publishingMigrations.contains(id), !nativePresentations.values.contains(where: { $0.graph.id == id }),
              sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
        defer { sharingGraphs.remove(id) }
        let binding: GraphCloudTransportBinding?
        var unboundCreation = false
        if let cloudConfig {
            let session = try await cloud(cloudConfig)
            let route: GraphCloudBinding
            if let existing = await session.retainedBindings().first(where: { $0.graphID == id }) { route = existing }
            else {
                guard let pending = try await owner.privatePublicationBinding(), pending.identity == (try await session.identity()) else { throw GraphCloudError.ownershipConflict }
                route = pending.route; unboundCreation = true
            }
            guard route.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
            let identity = try await session.identity()
            guard try await owner.accountIdentity() == identity, try await owner.participantAccess() == nil else { throw GraphCloudError.ownershipConflict }
            binding = .init(identity: identity, route: route)
        } else {
            guard try await owner.accountIdentity() == nil, try await owner.participantAccess() == nil else { throw GraphCloudError.ownershipConflict }
            try await requireUnboundBootstrap(id)
            binding = nil
        }
        let storeID = try await owner.storeIdentity()
        var intent = try await owner.deletionIntent() ?? GraphDeletionIntent(operationID: UUID(), graphID: id,
            storeID: storeID, source: try GraphDeletionSource(location.url), binding: binding, phase: .prepared)
        intent.allowsEmptyZone = unboundCreation || intent.allowsEmptyZone
        guard intent.binding == binding else { throw GraphCloudError.ownershipConflict }
        // Stop admission before persisting intent; all admitted native scopes drain.
        try await owner.blockSharingData()
        _ = try await owner.deletionIntent(intent)
        try await intent.persist(config)
        return try await performGraphDeletion(intent, at: location.url, configuration: cloudConfig)
    }
    func resumeGraphDeletion(_ id: GraphID, at url: URL, configuration: GraphCloudConfiguration?) async throws -> GraphDeletionStatus {
        let config = graphStoreConfiguration(id, at: url)
        guard let intent = try await GraphDeletionIntent.read(config) else {
            let graph = try await openGraph(id: id, at: url)
            do {
                guard let entry = entries[id], try await entry.opening.value.deletionIntent() != nil else { throw GraphStoreError.missingGraph }
                let result = try await deleteGraph(id, configuration: configuration)
                try await graph.close()
                return result
            } catch {
                let failure = error
                try await graph.close()
                throw failure
            }
        }
        return try await runGraphDeletion(intent, at: url, configuration: configuration)
    }
    private func runGraphDeletion(_ intent: GraphDeletionIntent, at url: URL, configuration: GraphCloudConfiguration?) async throws -> GraphDeletionStatus {
        guard sharingGraphs.insert(intent.graphID).inserted else { throw GraphCloudError.busy }
        defer { sharingGraphs.remove(intent.graphID) }
        return try await performGraphDeletion(intent, at: url, configuration: configuration)
    }
    private func performGraphDeletion(_ initial: GraphDeletionIntent, at url: URL, configuration cloudConfig: GraphCloudConfiguration?) async throws -> GraphDeletionStatus {
        let id = initial.graphID, config = graphStoreConfiguration(id, at: url)
        let resolved = try StoreRegistry.resolve(config)
        guard let binding = initial.binding else {
            guard cloudConfig == nil else { throw GraphCloudError.ownershipConflict }
            return try await finishGraphDeletion(initial, at: url)
        }
        guard let cloudConfig else { throw GraphCloudError.ownershipConflict }
        try await validateDeletionSource(initial, configuration: config)
        let session = try await cloud(cloudConfig)
        guard try await session.identity() == binding.identity else { throw GraphCloudError.accountChanged }
        try await session.registerDeletion(initial, allowingUnbound: initial.allowsEmptyZone)
        blockedSharingGraphs.insert(id); automaticChanged()
        if entries[id] != nil { try await pauseCloudSynchronization(for: id) }
        try await claimContextGraph(id, resolved: resolved)
        var intent = initial
        if intent.phase == .prepared {
            try await session.removePrivateZone(intent)
            intent.phase = .remoteDeleted
            try await intent.persist(config)
            try await session.registerDeletion(intent)
        }
        let status = try await finishGraphDeletion(intent, at: url)
        var completed = intent; completed.phase = .completed
        try await session.finishDeletion(completed)
        return status
    }
    private func validateDeletionSource(_ value: GraphDeletionIntent, configuration: StoreConfiguration) async throws {
        try await StoreRegistry.validateDestructionSource(configuration, graphID: value.graphID.rawValue,
            storeID: value.storeID, operationID: value.operationID, device: value.source.device, inode: value.source.inode,
            completed: value.phase == .completed)
    }
    private func finishGraphDeletion(_ initial: GraphDeletionIntent, at url: URL) async throws -> GraphDeletionStatus {
        let id = initial.graphID, config = graphStoreConfiguration(id, at: url)
        let resolved = try StoreRegistry.resolve(config)
        guard locations[id].map({ $0.key == resolved.key }) ?? true else { throw GraphStoreError.ownershipConflict }
        try await validateDeletionSource(initial, configuration: config)
        if initial.phase == .completed {
            guard [url.path, url.path + "-wal", url.path + "-shm"].allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) else { throw GraphStoreError.ownershipConflict }
            return initial.status
        }
        blockedSharingGraphs.insert(id); automaticChanged()
        try await claimContextGraph(id, resolved: resolved)
        if let entry = entries[id], entry.key != resolved.key { throw GraphStoreError.ownershipConflict }
        if entries[id] == nil, try await StoreRegistry.recoverInterruptedDestruction(config, graphID: id.rawValue,
            storeID: initial.storeID, operationID: initial.operationID) {
            var completed = initial; completed.phase = .completed
            try await completed.persist(config)
            locations.removeValue(forKey: id)
            await releaseContextGraphIfIdle(id)
            return completed.status
        }
        if entries[id] == nil {
            let registry = registry, schema = schema, adapter = adapter, storeID = initial.storeID
            let opening = Task.detached { try await GraphCoordinator.recoverForPurge(id: id, configuration: config,
                storeID: storeID, registry: registry, schema: schema, adapter: adapter, operationID: initial.operationID) }
            entries[id] = Entry(key: resolved.key, url: url, creating: false, initialPolicy: .lastEditWins, opening: opening)
        }
        let entry = entries[id]!, owner = try await entry.opening.value
        do {
            guard try await owner.storeIdentity() == initial.storeID,
                  let native = try await owner.deletionIntent(), native.matches(initial) else { throw GraphCloudError.ownershipConflict }
        } catch {
            let failure = error
            do { try await owner.close() }
            catch { throw GraphStoreMigrationCleanupFailure(operationID: initial.operationID, failure: failure, cleanupFailure: error) }
            removeClosedEntry(id, generation: entry.generation)
            await releaseContextGraphIfIdle(id)
            throw failure
        }
        try await owner.blockSharingData()
        let outcome = try await owner.destroy(storeID: initial.storeID, operationID: initial.operationID)
        removeClosedEntry(id, generation: entry.generation)
        if case .deferredAfterDetach = outcome { throw StoreRuntimeError.resourceReserved }
        var completed = initial; completed.phase = .completed
        try await completed.persist(config)
        locations.removeValue(forKey: id)
        await releaseContextGraphIfIdle(id)
        return completed.status
    }
}

@available(iOS 17, macOS 14, *)
extension GraphContext {
    /// Deletes a local-only graph. Cloud-bound graphs require their connection.
    public func deleteGraph(_ graph: GraphStore) async throws -> GraphDeletionStatus {
        try requireOrdinaryContext()
        guard await graph.publicContextIdentity == identityForBootstrap, await graph.publicLeaseIsOpen else { throw GraphStoreError.foreignGraph }
        do { return try await manager.deleteGraph(graph.id, configuration: nil) }
        catch { throw GraphStore.translate(error) }
    }
    public func resumeGraphDeletion(id: GraphID, at storeURL: URL) async throws -> GraphDeletionStatus {
        try requireOrdinaryContext(); try Self.validateStoreURL(storeURL)
        do { return try await manager.resumeGraphDeletion(id, at: storeURL, configuration: nil) }
        catch { throw GraphStore.translate(error) }
    }
    public func graphDeletionStatus(id: GraphID, at storeURL: URL) async throws -> GraphDeletionStatus? {
        try requireOrdinaryContext(); try Self.validateStoreURL(storeURL)
        do { return try await GraphDeletionIntent.read(manager.graphStoreConfiguration(id, at: storeURL))?.status }
        catch { throw GraphStore.translate(error) }
    }
}

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    /// Deletes an owner graph for all participants, then removes its local store.
    /// Errors retain durable progress; participant replicas must use leave instead.
    public func deleteGraph(_ graph: GraphStore) async throws -> GraphDeletionStatus {
        try await owningContext.requireOrdinaryContext()
        let config = try await ready()
        guard await graph.publicContextIdentity == owningContext.identityForBootstrap,
              await graph.publicLeaseIsOpen else { throw GraphStoreError.foreignGraph }
        return try await operation { try await owningContext.manager.deleteGraph(graph.id, configuration: config) }
    }
    public func resumeGraphDeletion(id: GraphID, at storeURL: URL) async throws -> GraphDeletionStatus {
        try await owningContext.requireOrdinaryContext()
        let config = try await ready(); try GraphContext.validateStoreURL(storeURL)
        return try await operation { try await owningContext.manager.resumeGraphDeletion(id, at: storeURL, configuration: config) }
    }
}
