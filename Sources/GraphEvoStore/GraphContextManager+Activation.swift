import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime

public struct GraphCloudActivationResult: Sendable {
    public let status: GraphCloudActivationStatus
    public let operationError: (any Error)?
    public let cleanupPending: Bool
}

public struct GraphCloudReplicaResult: Sendable {
    public let status: GraphCloudActivationStatus
    public let opening: Result<GraphStore, any Error>
}

public struct GraphCloudActivationCleanupFailure: Error {
    public let status: GraphCloudActivationStatus?
    public let operationError: (any Error)?
    public let cleanupFailure: any Error
}

extension GraphContextManager {
    private func withActivationOwner<Value: Sendable>(_ id: GraphID,
        _ body: (isolated GraphContextManager, GraphCoordinator) async throws -> Value) async throws -> Value {
        guard activatingCloudGraphs.insert(id).inserted else { throw GraphCloudActivationError.busy }
        defer { activatingCloudGraphs.remove(id); automaticChanged() }
        guard let location = locations[id] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: id, at: location.url)
        guard let entry = entries[id], entry.closing == nil else { try await graph.close(); throw GraphStoreError.closed }
        let owner = try await entry.opening.value
        let outcome: Result<Value, any Error>
        do { outcome = .success(try await body(self, owner)) }
        catch { outcome = .failure(error) }
        let status = try? await owner.activationDocument()?.status
        do { try await graph.close() }
        catch {
            let operationError: (any Error)?
            if case .failure(let failure) = outcome { operationError = failure } else { operationError = nil }
            throw GraphCloudActivationCleanupFailure(status: status, operationError: operationError, cleanupFailure: error)
        }
        return try outcome.get()
    }

    package func cloudActivationStatus(for id: GraphID) async throws -> GraphCloudActivationStatus? {
        try await withActivationOwner(id) { _, owner in try await owner.activationDocument()?.status }
    }

    /// Preparation is local and bounded. The caller explicitly starts the account session beforehand.
    package func prepareCloudActivation(for id: GraphID, activationID: UUID, zone: GraphCloudZone,
        configuration: GraphCloudConfiguration, declaration: GraphCloudCutoverDeclaration,
        limits: GraphCloudActivationLimits = .init()) async throws -> GraphCloudActivationStatus {
        try declaration.validate(); try limits.validate()
        guard zone.scope == .private, !zone.name.isEmpty, !zone.owner.isEmpty else { throw GraphCloudActivationError.invalidRequest }
        return try await withActivationOwner(id) { manager, owner in
            let session = try await manager.cloud(configuration)
            let binding = GraphCloudTransportBinding(identity: try await session.identity(), route: .init(zone: zone, graphID: id))
            try await manager.claimCloudAccount(binding.identity, for: id, owner: owner)
            if await session.containsBinding(for: id), await session.activationRoute(for: id) == nil { throw GraphCloudActivationError.invalidRequest }
            if let prior = try await owner.activationDocument() {
                guard prior.authority.activationID == activationID, prior.binding == binding,
                      prior.declaration == declaration, prior.limits == limits else { throw GraphCloudActivationError.authorityConflict }
                return prior.status
            }
            let pause = try await manager.reserveCloudPause(for: id)
            do {
                try await owner.activationAccess(activationID)
                let writes = try await owner.suspendLocalWrites()
                // The activation gate now owns consumer admission; release only our temporary drainage reservation.
                await writes.release()
                let result = try await owner.prepareActivation(binding, operation: activationID, declaration: declaration, limits: limits)
                await pause.release()
                return result.status
            } catch {
                let failure = error
                // A committed marker retains the gate even after cancellation or a failed response.
                if try await owner.activationDocument() == nil { try await owner.activationAccess(activationID, release: true) }
                await pause.release()
                throw failure
            }
        }
    }

    /// One explicit advancement sends at most one immutable batch, then verifies only when the queue is empty.
    package func advanceCloudActivation(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudActivationResult {
        try await withActivationOwner(id) { manager, owner in
            guard var document = try await owner.activationDocument(), !document.peer else { throw GraphCloudActivationError.invalidRequest }
            guard document.phase != .conflict else { throw GraphCloudActivationError.authorityConflict }
            let session = try await manager.cloud(configuration)
            guard try await session.identity() == document.binding.identity else { throw GraphCloudError.accountChanged }
            let route = document.binding.route
            do {
                if document.phase == .prepared {
                    document.phase = .claiming
                    try await owner.persistActivation(document)
                }
                let expected = document.authority
                let claiming = document.phase == .claiming
                let limits = document.limits
                let remote = try await session.activationControl { service, identity -> GraphCloudAuthorityRemote in
                    if claiming { try await service.ensureZone(configuration, route) }
                    if let existing = try await service.fetch(configuration, route) {
                        guard existing.value.matches(expected) else { throw GraphCloudActivationError.authorityConflict }
                        return existing
                    }
                    guard claiming else { throw GraphCloudActivationError.recoveryRequired }
                    let inventory = try await service.inventory(configuration, identity, route, limits)
                    guard inventory.isEmpty else { throw GraphCloudActivationError.zoneNotEmpty }
                    return try await service.save(configuration, route, expected, nil)
                }
                if document.phase == .published && !remote.value.published { throw GraphCloudActivationError.recoveryRequired }
                if remote.value.published {
                    document.phase = .published
                    try await owner.persistActivation(document)
                    try await session.bindActivation(route, activationID: expected.activationID, published: true, peer: false)
                    try await owner.activationAccess(expected.activationID, release: true)
                    return .init(status: document.status, operationError: nil, cleanupPending: false)
                }
                if claiming {
                    document.phase = .seeding
                    try await owner.persistActivation(document)
                }
                try await session.bindActivation(route, activationID: expected.activationID, published: false, peer: false)
                let send = try await manager.sendActivationSeed(document, configuration: configuration)
                if let failure = send.operationError { return .init(status: document.status, operationError: failure, cleanupPending: send.cleanupPending) }
                guard send.empty else { return .init(status: document.status, operationError: nil, cleanupPending: send.cleanupPending) }
                document.phase = .publishing
                try await owner.persistActivation(document)
                guard let manifest = document.manifest else { throw GraphCloudActivationError.invalidState }
                let published = try await session.activationControl { service, identity -> GraphCloudAuthorityRemote in
                    guard let current = try await service.fetch(configuration, route), current.value.matches(expected) else {
                        throw GraphCloudActivationError.recoveryRequired
                    }
                    if current.value.published { return current }
                    let inventory = try await service.inventory(configuration, identity, route, limits)
                    guard try await Self.seedManifest(inventory, session: session, binding: route,
                                                      authority: expected, limits: limits) == manifest else {
                        throw GraphCloudActivationError.recoveryRequired
                    }
                    var ready = current.value; ready.published = true
                    return try await service.save(configuration, route, ready, current)
                }
                guard published.value.published, published.value.matches(expected) else { throw GraphCloudActivationError.invalidState }
                document.phase = .published
                try await owner.persistActivation(document)
                try await session.bindActivation(route, activationID: expected.activationID, published: true, peer: false)
                try await owner.activationAccess(expected.activationID, release: true)
                return .init(status: document.status, operationError: nil, cleanupPending: send.cleanupPending)
            } catch {
                let failure = error
                if let activationFailure = failure as? GraphCloudActivationError, activationFailure == .authorityConflict, document.phase == .claiming {
                    document.phase = .conflict
                    try await owner.persistActivation(document)
                    try await owner.activationAccess(document.authority.activationID, release: true)
                }
                let persisted = try await owner.activationDocument() ?? document
                return .init(status: persisted.status, operationError: failure, cleanupPending: false)
            }
        }
    }

    /// Creates only an empty target, or resumes this protocol's already marked replica.
    package func openCloudReplica(id: GraphID, at url: URL, zone: GraphCloudZone,
        configuration: GraphCloudConfiguration, limits: GraphCloudActivationLimits = .init()) async throws -> GraphCloudReplicaResult {
        try limits.validate()
        guard zone.scope == .private, !zone.name.isEmpty, !zone.owner.isEmpty,
              entries[id] == nil, localV1Bootstraps[id] == nil, !migratingStores.contains(id),
              activatingCloudGraphs.insert(id).inserted else { throw GraphCloudActivationError.busy }
        defer { activatingCloudGraphs.remove(id); automaticChanged() }
        let resolved = try StoreRegistry.resolve(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue, contextOwnerID: contextOwnerID))
        try await claimContextGraph(id, resolved: resolved)
        guard !entries.values.contains(where: { $0.key == resolved.key }),
              !locations.contains(where: { $0.key != id && $0.value.key == resolved.key }),
              !localV1Bootstraps.values.contains(where: { $0.key == resolved.key }),
              locations[id] == nil || locations[id]?.key == resolved.key else { throw GraphStoreError.ownershipConflict }
        let syncPermit = try admitSynchronization(id)
        defer { finishSynchronization(syncPermit) }
        let token = UUID()
        localV1Bootstraps[id] = .init(token: token, key: resolved.key)
        defer { if localV1Bootstraps[id]?.token == token { localV1Bootstraps.removeValue(forKey: id) } }
        let session = try await cloud(configuration)
        let route = GraphCloudBinding(zone: zone, graphID: id)
        let identity = try await session.identity()
        let remote = try await session.activationControl { service, _ in
            guard let value = try await service.fetch(configuration, route), value.value.published else {
                throw GraphCloudActivationError.recoveryRequired
            }
            return value
        }
        let graph = try await openActivationReplica(id: id, at: url, permit: token, creating: !FileManager.default.fileExists(atPath: url.path))
        let owner = try await entries[id]!.opening.value
        try await claimCloudAccount(identity, for: id, owner: owner)
        var document: GraphCloudActivationDocument?
        do {
            if let prior = try await owner.activationDocument() {
                guard prior.peer, prior.authority.matches(remote.value), prior.binding.identity == identity,
                      prior.binding.route == route else { throw GraphCloudActivationError.authorityConflict }
                document = prior
            } else {
                try await owner.activationAccess(remote.value.activationID, peer: true)
                document = try await owner.prepareActivationPeer(.init(identity: identity, route: route), authority: remote.value, limits: limits)
            }
            var current = document!
            if current.phase != .published {
                try await session.bindActivation(route, activationID: remote.value.activationID, published: false, peer: true)
                // No public handle is exposed, and the persistent native marker blocks other openings.
                // This internal path retains the manager's wider bootstrap admission throughout import.
                let binding = current.binding
                let retained = try await session.incoming(for: zone, limit: configuration.maximumEvents)
                if !retained.isEmpty { _ = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: configuration.maximumEvents) }
                try await session.activationControl { service, identity in
                    guard let latest = try await service.fetch(configuration, route), latest.value.published,
                          latest.value.matches(remote.value) else { throw GraphCloudActivationError.recoveryRequired }
                    let inventory = try await service.inventory(configuration, identity, route, limits)
                    _ = try await Self.seedManifest(inventory, session: session, binding: route,
                                                    authority: remote.value, limits: limits)
                    var events = inventory.filter { !GraphCloudAuthorityCodec.isControl($0) && !GraphCloudGraphDescriptor.isControl($0) && !GraphCloudShareControl.isControl($0) }
                    // Only this unexposed replica may be reconciled against a complete verified zone cut.
                    // A retry can otherwise retain an earlier import whose row was subsequently deleted remotely.
                    let present = Set(events.compactMap(\.recordName))
                    for nodeID in try await owner.activationReplicaIDs().sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                        let name = try GraphCloudNodeCodec.recordID(for: nodeID, binding: route).recordName
                        if !present.contains(name) {
                            events.append(.init(kind: .recordDeleted, zone: zone, recordName: name, recordType: GraphCloudNodeCodec.recordType))
                        }
                    }
                    try await session.stageActivationSnapshot(events, for: route, activationID: remote.value.activationID)
                }
                _ = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: configuration.maximumEvents)
                guard try await graph.collectSyncChanges() == 0 else { throw GraphSyncError.pendingImport }
                _ = try await owner.validateActivationReplica()
                current.phase = .published
                try await owner.persistActivation(current)
                document = current
            }
            try await session.bindActivation(route, activationID: remote.value.activationID, published: true, peer: true)
            try await owner.activationAccess(remote.value.activationID, peer: true, release: true)
            return .init(status: document!.status, opening: .success(graph))
        } catch {
            let failure = error
            if document == nil { try? await owner.activationAccess(remote.value.activationID, peer: true, release: true) }
            do { try await graph.close() }
            catch { throw GraphStoreMigrationCleanupFailure(operationID: remote.value.activationID, failure: failure, cleanupFailure: error) }
            guard let document else { throw failure }
            return .init(status: document.status, opening: .failure(failure))
        }
    }

    private struct SeedSend: Sendable {
        let empty: Bool
        let cleanupPending: Bool
        let operationError: (any Error)?
    }

    private func sendActivationSeed(_ document: GraphCloudActivationDocument, configuration: GraphCloudConfiguration) async throws -> SeedSend {
        let permit = document.authority.activationID
        return try await withTransport(document.authority.graphID, configuration: configuration, activationPermit: permit) { session, graph, binding, _ in
            let previous = try await Self.drainSent(session, graph: graph, binding: binding)
            if let error = Self.seedUploadError(previous) {
                return .init(empty: false, cleanupPending: previous.cleanupPending, operationError: error)
            }
            let batch = try await graph.prepareTransport(binding, maximum: 100)
            if batch.items.isEmpty { return .init(empty: true, cleanupPending: previous.cleanupPending, operationError: nil) }
            let outcome = try await session.sendWithAdvice(batch, activationPermit: permit)
            let result = try await Self.drainSent(session, graph: graph, binding: binding)
            return .init(empty: false, cleanupPending: previous.cleanupPending || result.cleanupPending,
                         operationError: Self.seedUploadError(result) ?? outcome.transportError)
        }
    }

    private static func seedUploadError(_ report: GraphCloudSendReport) -> (any Error)? {
        if report.failures.contains(where: { $0.code == CKError.Code.limitExceeded.rawValue }) {
            return CKError(.limitExceeded)
        }
        return report.failures.isEmpty ? nil : GraphCloudActivationError.recoveryRequired
    }

    private static func seedManifest(_ inventory: [GraphCloudIncoming], session: GraphCloudSession,
                                     binding: GraphCloudBinding, authority: GraphCloudAuthority,
                                     limits: GraphCloudActivationLimits) async throws -> GraphCloudSeedManifest {
        var entries: [GraphCloudSeedEntry] = []
        var remaining = limits.maximumPayloadBytes
        var controls = 0
        for event in inventory {
            guard event.kind == .recordChanged, event.zone == binding.zone, let bytes = event.recordArchive else {
                throw GraphCloudActivationError.invalidState
            }
            let record = try GraphCloudRecordCodec.restore(bytes)
            if let data = try await session.assetData(for: event, binding: binding) {
                record["asset"] = data as CKRecordValue
            }
            if GraphCloudGraphDescriptor.isControl(event) {
                try GraphCloudGraphDescriptor.validate(event, binding: binding)
            } else if GraphCloudShareControl.isControl(event) {
                try GraphCloudShareControl.validateOwnerInventory(event, binding: binding)
            } else if GraphCloudAuthorityCodec.isControl(event) {
                guard try GraphCloudAuthorityCodec.decode(record, binding: binding).value.matches(authority) else {
                    throw GraphCloudActivationError.authorityConflict
                }
                controls += 1
            } else {
                _ = try GraphCloudNodeCodec.decode(record, binding: binding)
                guard let payload = record["payload"] as? Data, payload.count <= remaining else {
                    throw GraphCloudActivationError.limitExceeded
                }
                remaining -= payload.count
                entries.append(try GraphCloudSeedManifest.entry(record, binding: binding))
            }
        }
        guard controls == 1 else { throw GraphCloudActivationError.recoveryRequired }
        return try GraphCloudSeedManifest.make(entries: entries, binding: binding, limits: limits)
    }
}
