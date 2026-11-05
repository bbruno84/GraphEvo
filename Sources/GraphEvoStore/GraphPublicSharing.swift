import CloudKit
import Foundation
import GraphEvoModel

/// A container-scoped participant reference supplied by CloudKit, not a credential.
public struct GraphCloudParticipantIdentity: Sendable, Equatable, Hashable {
    let value: String
}

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    func controlConfiguration() async throws -> GraphCloudConfiguration {
        try await check()
        let config = try await sharingConfiguration()
        _ = try await owningContext.manager.cloud(config).identity(control: true)
        return config
    }
    func validateGraph(_ graph: GraphStore) async throws {
        guard await graph.publicContextIdentity == owningContext.identityForBootstrap else { throw GraphStoreError.foreignGraph }
        guard await graph.publicLeaseIsOpen, let generation = await graph.publicCoordinatorGeneration else { throw GraphStoreError.closed }
        try await owningContext.manager.checkPublicSharingOwner(graph.id, generation: generation)
    }
    func hasRoute(_ id: GraphID, configuration: GraphCloudConfiguration) async throws -> Bool {
        let session = try await owningContext.manager.cloud(configuration)
        return try await (session.routes(in: .private) + session.routes(in: .shared)).contains { $0.graphID == id }
    }
    /// Accepts a native share URL and records resumable progress before GraphID is known.
    public func acceptInvitation(at url: URL) async throws -> GraphCloudJoin {
        return try await sharingOperation {
            let config = try await ready(), session = try await owningContext.manager.cloud(config)
            let value = try await session.nativeBeginJoin(url)
            // A failed network step is retained on the returned handle, not a lost acceptance receipt.
            // Publication already committed: even account loss must not conceal the intent ID.
            try? await session.nativeAdvanceJoin(value.id)
            return GraphCloudJoin(id: value.id, connection: self, contextIdentity: owningContext.identityForBootstrap, namespace: config.namespace)
        }
    }
    /// Revalidates native callback metadata through its URL under the current account.
    public func acceptInvitation(_ metadata: CKShare.Metadata) async throws -> GraphCloudJoin {
        return try await sharingOperation {
            guard let url = metadata.share.url else { throw GraphCloudDiscoveryError.invalidInvitation }
            return try await acceptInvitation(at: url)
        }
    }
    /// Lists durable invitations, including completed joins, without reading application data.
    public func pendingInvitations() async throws -> [GraphCloudJoin] {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return try await owningContext.manager.cloud(config).nativeJoins().filter { $0.phase != .discarded }.map { GraphCloudJoin(id: $0.id, connection: self, contextIdentity: owningContext.identityForBootstrap, namespace: config.namespace) }
        }
    }
    func joinState(_ id: UUID) async throws -> GraphCloudJoinState {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return try await owningContext.manager.cloud(config).nativeJoin(id).status
        }
    }
    func retryJoin(_ id: UUID) async throws {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            try await owningContext.manager.cloud(config).nativeAdvanceJoin(id)
        }
    }
    func observeJoin(_ id: UUID) async throws -> GraphObservation<GraphCloudJoinState> {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return forwarding(try await owningContext.manager.cloud(config).observeJoin(id))
        }
    }
    /// Creates or resumes an exact participant replica after descriptor discovery.
    public func openReplica(for join: GraphCloudJoin, at storeURL: URL) async throws -> GraphStore {
        return try await sharingOperation {
            try GraphContext.validateStoreURL(storeURL)
            let config = try await ready()
            guard join.contextIdentity == owningContext.identityForBootstrap, join.namespace == config.namespace else { throw GraphStoreError.foreignGraph }
            let graph = try await owningContext.manager.openNativeReplica(join.id, at: storeURL, configuration: config)
            await graph.retainPublicContext(owningContext, identity: owningContext.identityForBootstrap)
            return graph
        }
    }
    /// Leaves an accepted join without a replica; remote failure preserves the pending command.
    public func discardInvitation(_ join: GraphCloudJoin) async throws {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            guard join.contextIdentity == owningContext.identityForBootstrap, join.namespace == config.namespace else { throw GraphStoreError.foreignGraph }
            try await owningContext.manager.cloud(config).nativeDiscardJoin(join.id)
        }
    }
    /// Fetches owner-visible participants. Native identity may be absent on some entries.
    public func participants(in graph: GraphStore) async throws -> [GraphCloudParticipant] {
        return try await sharingOperation {
            try await validateGraph(graph)
            let config = try await ready()
            return try await owningContext.manager.cloudParticipants(for: graph.id, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
        }
    }
    /// Changes one owner's participant permission through the durable command path.
    public func setPermission(_ permission: GraphCloudSharePermission, for participant: GraphCloudParticipantIdentity,
                              in graph: GraphStore) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            try await validateGraph(graph)
            let config = try await controlConfiguration()
            return try await owningContext.manager.setCloudParticipantPermission(permission, participant: participant.value, for: graph.id, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
        }
    }
    /// Removes one participant without deleting the owner's graph.
    public func removeParticipant(_ participant: GraphCloudParticipantIdentity, from graph: GraphStore) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            try await validateGraph(graph)
            let config = try await controlConfiguration()
            return try await owningContext.manager.removeCloudParticipant(participant.value, from: graph.id, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
        }
    }
    /// Stops sharing while preserving owner-private graph records.
    public func stopSharing(_ graph: GraphStore) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            try await validateGraph(graph)
            let config = try await controlConfiguration()
            return try await owningContext.manager.stopCloudSharing(for: graph.id, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
        }
    }
    /// Destroys the participant replica and unpublished work, retaining an offline remote leave.
    public func leaveSharedGraph(_ graph: GraphStore) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            try await validateGraph(graph)
            let config = try await controlConfiguration()
            return try await owningContext.manager.leaveCloudShare(for: graph.id, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
        }
    }
    /// Reads durable membership state, including after local removal.
    public func sharingStatus(for graphID: GraphID) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return try await owningContext.manager.cloudSharingStatus(for: graphID, configuration: config)
        }
    }
    /// Observes newest membership state without retaining a graph lease.
    public func observeSharing(for graphID: GraphID) async throws -> GraphObservation<GraphCloudSharingStatus> {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return forwarding(try await owningContext.manager.observeCloudSharing(for: graphID, configuration: config))
        }
    }
    /// Inspects current native access; failure is not proof authorizing deletion.
    public func refreshSharing(for graphID: GraphID) async throws -> GraphCloudSharingStatus {
        return try await sharingOperation {
            let config = try await controlConfiguration()
            return try await owningContext.manager.refreshCloudSharing(for: graphID, configuration: config)
        }
    }
    /// Supplies a current path for an existing durable membership's restart/purge recovery.
    public func registerSharedReplica(id: GraphID, at storeURL: URL) async throws {
        try await registerSharedReplica(id: id, at: storeURL, recoveringOfflineGeneration: nil)
    }

    /// A recovery generation may be supplied after stopping every process using an ordinary SQLite replica.
    public func registerSharedReplica(id: GraphID, at storeURL: URL, recoveringOfflineGeneration: UUID?) async throws {
        return try await sharingOperation {
            try GraphContext.validateStoreURL(storeURL)
            let config = try await controlConfiguration()
            try await owningContext.manager.registerCloudGraphLocation(id, at: storeURL, configuration: config,
                recoveringOfflineGeneration: recoveringOfflineGeneration)
        }
    }
    private func removePublicObservation(_ id: UUID) { publicObservationControls.removeValue(forKey: id) }
    func forwarding<Value: Sendable>(_ stream: AsyncStream<Value>) -> GraphObservation<Value> {
        let id = UUID(), pair = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1)), control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        // No actor state is used; detached forwarding cannot retain the connection executor.
        let worker = Task.detached {
            for await value in stream {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(value)
            }
            pair.continuation.finish()
        }
        control.install(worker, refresh: {}, finish: { [weak self] in
            pair.continuation.finish()
            Task { await self?.removePublicObservation(id) }
        })
        retainForwardedObservation(id, control: control)
        return .init(stream: pair.stream, control: control)
    }
}

extension GraphContextManager {
    func openNativeReplica(_ joinID: UUID, at url: URL, configuration: GraphCloudConfiguration) async throws -> GraphStore {
        let session = try await cloud(configuration)
        var join = try await session.nativeJoin(joinID)
        guard let id = join.graphID, [.ready, .openingReplica, .joined].contains(join.phase),
              !sharingGraphs.contains(id), nativeReplicaOpenings.insert(id).inserted else { throw GraphCloudDiscoveryError.invalidJoin }
        defer { nativeReplicaOpenings.remove(id) }
        let route = GraphCloudBinding(zone: join.invitation.zone, graphID: id)
        if let member = try await session.membership(id), member.terminal, member.generation == join.id {
            throw GraphCloudDiscoveryError.invalidJoin
        }
        if let member = try await session.membership(id), member.hadAccess, !member.terminal {
            guard member.binding == route else { throw GraphCloudError.ownershipConflict }
            try await registerCloudGraphLocation(id, at: url, configuration: configuration)
            let graph = try await openGraph(id: id, at: url)
            join.phase = .joined; join.failure = false
            do { try await session.updateJoin(join) } catch { try? await graph.close(); throw error }
            automaticChanged()
            return graph
        }
        try await session.verifyNativeJoinDescriptor(joinID)
        let existing = FileManager.default.fileExists(atPath: url.path)
        if let prior = try await session.membership(id), prior.terminal {
            guard prior.phase == .removed, prior.pending == nil, !existing,
                  entries[id] == nil, purgeTasks[id] == nil else { throw GraphCloudDiscoveryError.busy }
            blockedSharingGraphs.remove(id); locations.removeValue(forKey: id)
        }
        rejoiningGraphs.insert(id)
        defer { rejoiningGraphs.remove(id) }
        if join.phase == .ready, existing { throw GraphStoreError.duplicateIdentity }
        let identity = try await session.identity()
        let initial = GraphCloudParticipantAccess(binding: route, account: identity.account, permission: nil,
            accepted: false, identity: identity, generation: join.id)
        let previousPhase = join.phase
        join.phase = .openingReplica; try await session.updateJoin(join, expectedPhase: previousPhase)
        var opened: GraphStore?
        do {
            let graph = try await (existing ? openGraph(id: id, at: url) : createJoiningGraph(id: id, at: url, access: initial))
            opened = graph
            guard let entry = entries[id] else { throw GraphStoreError.closed }
            let owner = try await entry.opening.value
            let priorMembership = try await session.membership(id)
            if priorMembership == nil || priorMembership?.phase == .removed {
                try await owner.validateUntouchedJoin(initial)
                _ = try await session.beginMembership(route, storeID: owner.storeIdentity(),
                    shareIdentity: GraphCloudShareIdentity.of(join.invitation.url), generation: join.id)
            } else {
                guard let member = try await session.membership(id), member.binding == route,
                      member.generation == join.id, member.storeID == (try await owner.storeIdentity()),
                      !member.terminal else { throw GraphCloudDiscoveryError.invalidJoin }
            }
            let permit = try admitSynchronization(id)
            do {
                try await claimCloudAccount(identity, for: id, owner: owner)
                _ = try await graph.participantAccess(session.nativeBindAcceptedJoin(joinID))
                try await refreshCloudMembership(id, configuration: configuration)
                finishSynchronization(permit)
            } catch { finishSynchronization(permit); throw error }
            join.phase = .joined; join.failure = false
            try await session.updateJoin(join)
            automaticChanged()
            return graph
        } catch {
            if let opened { try? await opened.close() }
            join.failure = true; try await session.updateJoin(join)
            throw error
        }
    }
}

extension GraphContextManager {
    func prepareNativePresentation(_ id: GraphID, title: String, configuration: GraphCloudConfiguration, publicOwner: UUID? = nil) async throws -> (UUID, Data) {
        try checkPublicSharingOwner(id, generation: publicOwner)
        guard !title.isEmpty, title.utf8.count <= 1024 else { throw GraphCloudError.invalidConfiguration }
        guard sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
        var held: GraphStore?
        var permit: GraphCloudSyncPermit?
        do {
            let session = try await cloud(configuration)
            guard try await session.membership(id)?.pending == nil else { throw GraphCloudError.busy }
            let binding = try await session.route(for: id)
            if try await session.membership(id)?.nativePresentationPending == true {
                try await session.nativeReconcileOwnerShare(binding, stopped: false)
            }
            guard binding.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
            guard let location = locations[id] else { throw GraphStoreError.missingGraph }
            permit = try admitSynchronization(id)
            let graph = try await openGraph(id: id, at: location.url); held = graph
            try checkPublicSharingOwner(id, generation: publicOwner)
            _ = try await graph.accountCheck()
            let bytes = try await withTransport(id, configuration: configuration) { session, _, verified, _ in
                try await session.nativePrepareShare(verified.route, title: title)
            }
            try await session.nativeRecordOwnerShare(binding, archive: bytes)
            let token = UUID()
            nativePresentations[token] = .init(graph: graph, binding: binding, configuration: configuration, permit: permit!)
            return (token, bytes)
        } catch {
            if let permit { finishSynchronization(permit) }
            if let held { try? await held.close() }
            sharingGraphs.remove(id)
            throw error
        }
    }
    func finishNativePresentation(_ token: UUID, stopped: Bool) async throws {
        guard let held = nativePresentations[token] else { return }
        var failure: (any Error)?
        do { try await cloud(held.configuration).nativeReconcileOwnerShare(held.binding, stopped: stopped) }
        catch { failure = error }
        // Keep native claims and the presentation registration if close fails.
        try await held.graph.close()
        nativePresentations.removeValue(forKey: token)
        sharingGraphs.remove(held.binding.graphID); finishSynchronization(held.permit)
        if let failure { throw failure }
    }
}

extension GraphContextManager {
    func checkPublicSharingOwner(_ id: GraphID, generation: UUID?) throws {
        guard let generation else { return }
        guard let entry = entries[id], entry.generation == generation, entry.closing == nil else { throw GraphStoreError.closed }
    }
}

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    func sharingOperation<Value: Sendable>(_ body: () async throws -> Value) async throws -> Value {
        do { return try await body() }
        catch {
            switch error {
            case GraphCloudError.busy: throw GraphCloudDiscoveryError.busy
            case GraphCloudError.graphPaused: throw GraphCloudDiscoveryError.graphPaused
            case GraphCloudError.inboxLimit: throw GraphCloudDiscoveryError.limitExceeded
            case GraphCloudError.accountChanged, GraphCloudError.accountUnavailable, GraphCloudError.stopped, GraphCloudError.stopping:
                throw GraphCloudConnectionError.notReady
            default:
                if error is GraphCloudDiscoveryError || error is GraphCloudSharingError || error is GraphStoreError { throw error }
                throw GraphCloudConnectionError.translate(error)
            }
        }
    }
}
