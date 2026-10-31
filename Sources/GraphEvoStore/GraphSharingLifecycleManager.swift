import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

extension GraphContextManager {
    package func cloudSharingStatus(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        guard let member = try await cloud(configuration).membership(id) else { throw GraphStoreError.missingGraph }
        return member.status
    }
    package func observeCloudSharing(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> AsyncStream<GraphCloudSharingStatus> {
        try await cloud(configuration).observeSharing(id)
    }
    package func cloudParticipants(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> [GraphCloudParticipant] {
        let session = try await cloud(configuration), route = try await session.route(for: id)
        guard let snapshot = try await session.inspectSharing(route), snapshot.role == .owner else { throw GraphCloudSharingError.ownerRequired }
        return snapshot.participants
    }
    package func setCloudParticipantPermission(_ permission: GraphCloudSharePermission, participant: String,
        for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        try await ownerSharingCommand(.permission(participant, permission), id: id, configuration: configuration)
    }
    package func removeCloudParticipant(_ participant: String, from id: GraphID,
        configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        try await ownerSharingCommand(.remove(participant), id: id, configuration: configuration)
    }
    package func stopCloudSharing(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        try await ownerSharingCommand(.stop, id: id, configuration: configuration)
    }
    private func ownerSharingCommand(_ command: GraphCloudShareCommand, id: GraphID,
        configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        guard sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
        defer { sharingGraphs.remove(id) }
        let session = try await cloud(configuration), route = try await session.route(for: id)
        guard route.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
        if let prior = try await session.membership(id), prior.pending != nil {
            guard prior.pending?.command == command else { throw GraphCloudError.busy }
            return try await executeSharingIntent(prior, session: session)
        }
        let snapshot = try await session.inspectSharing(route)
        guard let snapshot else {
            if command == .stop, let prior = try await session.membership(id) { return prior.status }
            throw GraphCloudSharingError.metadataPending
        }
        guard snapshot.role == .owner else { throw GraphCloudSharingError.ownerRequired }
        let identity = try await session.identity()
        var member = try await session.membership(id) ?? GraphCloudMembership(binding: route, identity: identity,
            generation: UUID(), role: .owner, phase: .active, permission: .readWrite, hadAccess: true)
        member.shareIdentity = snapshot.identity
        member.pending = .init(id: UUID(), command: command, shareIdentity: snapshot.identity)
        try await session.updateMembership(member)
        return try await executeSharingIntent(member, session: session)
    }
    func executeSharingIntent(_ member: GraphCloudMembership, session: GraphCloudSession) async throws -> GraphCloudSharingStatus {
        do { try await session.executeSharing(member) }
        catch {
            guard var current = try await session.membership(member.binding.graphID), current.generation == member.generation else { throw GraphCloudError.invalidState }
            current.failure = Self.sharingDiagnostic(error)
            if let sharing = error as? GraphCloudSharingError,
               [.superseded, .invalidParticipant, .invalidInvitation, .ownerRequired].contains(sharing) { current.pending = nil }
            try await session.updateMembership(current)
            let key = member.identity.environment.rawValue + ":" + member.identity.container + ":" + member.binding.zone.scope.rawValue
            await lifecycleWorkers[key]?.recordFailure(member.binding.graphID, error: error)
        }
        return try await session.membership(member.binding.graphID)!.status
    }

    /// Destructive even offline: remove local work before attempting the retained remote command.
    package func leaveCloudShare(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        guard sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
        defer { sharingGraphs.remove(id) }
        let session = try await cloud(configuration)
        guard var member = try await session.membership(id), member.role == .participant else { throw GraphCloudSharingError.invalidParticipant }
        if member.terminal {
            if member.phase != .removed { try await runSharingPurge(member, configuration: configuration) }
            if member.pending != nil { return try await executeSharingIntent(member, session: session) }
            return member.status
        }
        guard let share = member.shareIdentity else { throw GraphCloudSharingError.metadataPending }
        member.phase = .leaving; member.reason = .left
        member.pending = .init(id: UUID(), command: .leave, shareIdentity: share)
        try await session.updateMembership(member)
        try await markSharingTerminal(member)
        try await runSharingPurge(member, configuration: configuration)
        return try await executeSharingIntent(member, session: session)
    }

    /// Only this overload may create a new empty replica for a completed removal.
    package func acceptCloudInvitation(_ invitation: GraphCloudInvitation, at url: URL,
        configuration: GraphCloudConfiguration) async throws -> GraphStore {
        let session = try await cloud(configuration), id = invitation.graphID
        if let prior = try await session.membership(id) {
            if prior.phase == .joining, !prior.hadAccess,
               prior.binding == GraphCloudBinding(zone: invitation.zone, graphID: id) {
                // Resume the same durable acceptance, never allocate a replacement generation.
                try await registerCloudGraphLocation(id, at: url, configuration: configuration)
                let graph = try await openGraph(id: id, at: url)
                do { try await acceptCloudInvitation(invitation, configuration: configuration); return graph }
                catch { let original = error; try? await graph.close(); throw original }
            }
            guard prior.phase == .removed, prior.pending == nil, !FileManager.default.fileExists(atPath: url.path) else { throw GraphCloudError.busy }
            guard entries[id] == nil, purgeTasks[id] == nil else { throw GraphCloudError.busy }
            blockedSharingGraphs.remove(id); locations.removeValue(forKey: id)
        }
        rejoiningGraphs.insert(id)
        defer { rejoiningGraphs.remove(id) }
        let graph = try await createGraph(id: id, at: url)
        do { try await acceptCloudInvitation(invitation, configuration: configuration); return graph }
        catch { let original = error; try? await graph.close(); throw original }
    }

    /// A restart supplies current URLs before recovery; no sandbox path is persisted.
    package func registerCloudGraphLocation(_ id: GraphID, at url: URL, configuration: GraphCloudConfiguration) async throws {
        let session = try await cloud(configuration)
        guard let member = try await session.membership(id), member.role == .participant else { throw GraphStoreError.missingGraph }
        guard !rejoiningGraphs.contains(id) else { throw GraphCloudError.busy }
        if member.terminal, member.phase != .removed, let location = locations[id] {
            let sameURL = url.standardizedFileURL.resolvingSymlinksInPath() == location.url
            if let purge = purgeTasks[id] {
                guard purge.namespace == configuration.namespace else { throw GraphCloudError.ownershipConflict }
                // Even URL resolution probes the filesystem. Wait before examining disappearing files.
                try await purge.task.value
                guard !rejoiningGraphs.contains(id), try await session.membership(id)?.generation == member.generation else { throw GraphCloudError.busy }
                if sameURL { return }
                return try await registerCloudGraphLocation(id, at: url, configuration: configuration)
            }
            if sameURL, entries[id] != nil { return try await runSharingPurge(member, configuration: configuration) }
        }
        let resolved = try StoreRegistry.resolve(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue))
        if let existing = entries[id], existing.key != resolved.key { throw GraphStoreError.ownershipConflict }
        guard !locations.contains(where: { $0.key != id && $0.value.key == resolved.key }) else { throw GraphStoreError.ownershipConflict }
        guard case .sqlite(let canonical) = resolved.configuration.location else { throw GraphCloudError.invalidConfiguration }
        if member.terminal, member.phase != .removed, locations[id]?.key == resolved.key {
            // A retained owner validates destruction itself; never open a second metadata reader mid-purge.
            if let purge = purgeTasks[id] {
                guard purge.namespace == configuration.namespace else { throw GraphCloudError.ownershipConflict }
                return try await purge.task.value
            }
            if entries[id] != nil { return try await runSharingPurge(member, configuration: configuration) }
        }
        if FileManager.default.fileExists(atPath: canonical.path) {
            try autoreleasepool {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: canonical)
                guard metadata[NSStoreUUIDKey] as? String == member.storeID,
                      metadata[StoreNativeContext.historySyncGraphKey] as? String == id.rawValue.uuidString else { throw GraphCloudError.ownershipConflict }
            }
        } else if [canonical.path + "-wal", canonical.path + "-shm"].contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            throw GraphCloudError.invalidState
        }
        locations[id] = GraphLocation(key: resolved.key, url: canonical)
        if member.terminal {
            blockedSharingGraphs.insert(id)
            if member.phase != .removed { try await runSharingPurge(member, configuration: configuration) }
        } else if let entry = entries[id] {
            try await restoreSharingOwner(member, owner: entry.opening.value)
        }
    }
    func restoreSharingOnOpen(_ id: GraphID, owner: GraphCoordinator) async throws {
        if rejoiningGraphs.contains(id) { return }
        for config in activeCloudConfigurations() {
            let session = try await cloud(config)
            if let member = try await session.membership(id), member.role == .participant {
                try await restoreSharingOwner(member, owner: owner)
            }
        }
    }
    func restoreSharingRegistrations(configuration: GraphCloudConfiguration) async throws {
        let session = try await cloud(configuration)
        for member in try await session.memberships() where member.role == .participant {
            if member.terminal {
                blockedSharingGraphs.insert(member.binding.graphID)
                if let entry = entries[member.binding.graphID] {
                    try await entry.opening.value.setSharingDataAvailable(false)
                }
                if member.phase != .removed, locations[member.binding.graphID] != nil { scheduleSharingPurge(member, configuration: configuration) }
            } else if let entry = entries[member.binding.graphID] {
                try await restoreSharingOwner(member, owner: entry.opening.value)
            }
        }
    }
    private func restoreSharingOwner(_ member: GraphCloudMembership, owner: GraphCoordinator) async throws {
        guard try await owner.storeIdentity() == member.storeID else { throw GraphCloudError.invalidState }
        var stored = try await owner.participantAccess()
        if stored == nil, member.phase == .joining, !member.hadAccess, member.permission == nil,
           member.pending == nil, member.reason == nil {
            // Recover only the gap between the durable join intent and the untouched replica marker.
            try await owner.setSharingDataAvailable(false)
            stored = try await owner.participantAccess(.init(binding: member.binding, account: member.identity.account,
                permission: nil, accepted: false, identity: member.identity, generation: member.generation))
        }
        guard let access = stored, access.identity == member.identity,
              access.generation == member.generation, access.binding == member.binding else { throw GraphCloudError.invalidState }
        if !member.terminal, member.hadAccess, !access.blocked, access.permission != member.permission {
            _ = try await owner.participantAccess(.init(binding: member.binding, account: member.identity.account,
                permission: member.permission, accepted: true, identity: member.identity, generation: member.generation))
        }
        try await owner.setSharingDataAvailable(!member.terminal && member.hadAccess && !access.blocked)
    }

    /// Control-only inspection precedes payload, frozen receipts and normal data admission.
    package func refreshCloudSharing(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphCloudSharingStatus {
        try await refreshCloudMembership(id, configuration: configuration)
        return try await cloudSharingStatus(for: id, configuration: configuration)
    }
    func refreshCloudMembership(_ id: GraphID, configuration: GraphCloudConfiguration) async throws {
        let session = try await cloud(configuration)
        guard var member = try await session.membership(id), member.role == .participant else { return }
        guard sharingGraphs.insert(id).inserted else { throw GraphCloudError.busy }
        defer { sharingGraphs.remove(id) }
        if member.terminal {
            if member.phase != .removed { scheduleSharingPurge(member, configuration: configuration) }
            throw GraphCloudError.zoneUnavailable
        }
        let snapshot: GraphCloudShareSnapshot?
        do {
            if await session.supportsSharingOperations() { snapshot = try await session.inspectSharing(member.binding) }
            else {
                snapshot = member.permission.map { GraphCloudShareSnapshot(identity: member.shareIdentity ?? "", role: .participant, permission: $0, participants: []) }
            }
        } catch {
            if let error = error as? GraphCloudError, error == .busy || error == .stopping || error == .stopped { throw error }
            member.phase = member.hadAccess ? .accessUnverified : .joining; member.failure = Self.sharingDiagnostic(error)
            try await session.updateMembership(member)
            throw error
        }
        if let snapshot {
            guard snapshot.role == .participant else { throw GraphCloudSharingError.invalidInvitation }
            if snapshot.permission != member.permission || !member.hadAccess, let entry = entries[id] {
                try await entry.opening.value.setSharingDataAvailable(false)
            }
            member.phase = .active; member.permission = snapshot.permission; member.hadAccess = true
            member.shareIdentity = snapshot.identity; member.failure = nil
            try await session.updateMembership(member)
            let key = configuration.namespace + ":" + member.binding.zone.scope.rawValue
            await lifecycleWorkers[key]?.recordSuccess(id)
            if let entry = entries[id] {
                let owner = try await entry.opening.value
                _ = try await owner.participantAccess(.init(binding: member.binding, account: member.identity.account,
                    permission: member.permission, accepted: true, identity: member.identity, generation: member.generation))
                try await owner.setSharingDataAvailable(true)
            }
        } else if member.hadAccess {
            member.phase = .purging; member.reason = .accessLost; member.permission = nil
            try await session.updateMembership(member)
            try await markSharingTerminal(member)
            scheduleSharingPurge(member, configuration: configuration)
            throw GraphCloudError.zoneUnavailable
        } else {
            member.phase = .joining; try await session.updateMembership(member)
            throw GraphCloudSharingError.metadataPending
        }
    }
    private func markSharingTerminal(_ member: GraphCloudMembership) async throws {
        let id = member.binding.graphID
        blockedSharingGraphs.insert(id); automaticChanged()
        if let entry = entries[id] {
            let owner = try await entry.opening.value
            try await owner.setSharingDataAvailable(false)
            if let access = try? await owner.participantAccess() {
                _ = try await owner.participantAccess(.init(binding: access.binding, account: access.account,
                    permission: nil, accepted: access.accepted, identity: access.identity, generation: access.generation, blocked: true))
            }
        }
    }
    private func scheduleSharingPurge(_ member: GraphCloudMembership, configuration: GraphCloudConfiguration) {
        guard purgeTasks[member.binding.graphID] == nil else { return }
        Task { [weak self] in try? await self?.runSharingPurge(member, configuration: configuration) }
    }
    private func runSharingPurge(_ member: GraphCloudMembership, configuration: GraphCloudConfiguration) async throws {
        let id = member.binding.graphID
        if let purge = purgeTasks[id] { return try await purge.task.value }
        let task = Task { try await self.performSharingPurge(member, configuration: configuration) }
        purgeTasks[id] = SharingPurge(namespace: configuration.namespace, task: task)
        do { try await task.value; purgeTasks.removeValue(forKey: id) }
        catch {
            purgeTasks.removeValue(forKey: id)
            if let session = try? await cloud(configuration), var current = try? await session.membership(id), current.generation == member.generation {
                current.phase = .purging; current.failure = Self.sharingDiagnostic(error); try? await session.updateMembership(current)
            }
            throw error
        }
    }
    private func performSharingPurge(_ member: GraphCloudMembership, configuration: GraphCloudConfiguration) async throws {
        let id = member.binding.graphID, session = try await cloud(configuration)
        guard let current = try await session.membership(id), current.generation == member.generation, current.terminal else { throw GraphCloudError.invalidState }
        guard let location = locations[id], let storeID = member.storeID else { throw GraphCloudSharingError.metadataPending }
        if let entry = entries[id], !entry.tokens.isEmpty { try await pauseCloudSynchronization(for: id) }
        if FileManager.default.fileExists(atPath: location.url.path) || entries[id] != nil {
            if entries[id] == nil {
                let registry = registry, schema = schema, adapter = adapter
                let configuration = StoreConfiguration(location: .sqlite(location.url), exclusiveGraphID: id.rawValue)
                let task = Task.detached { try await GraphCoordinator.recoverForPurge(id: id, configuration: configuration, registry: registry, schema: schema, adapter: adapter) }
                entries[id] = Entry(key: location.key, url: location.url, creating: false, initialPolicy: .lastEditWins, opening: task)
            }
            let entry = entries[id]!
            let owner = try await entry.opening.value
            #if DEBUG
            try await purgeProbeBarrier?(id)
            #endif
            try await owner.destroy(storeID: storeID)
            removeClosedEntry(id, generation: entry.generation)
        }
        try await session.completePurge(id, generation: member.generation)
        locations.removeValue(forKey: id); automaticChanged()
    }
    static func sharingDiagnostic(_ error: any Error) -> String {
        let value = error as NSError
        return (value.domain == "CKErrorDomain" ? "cloud:" : "sharing:") + String(value.code)
    }
}
