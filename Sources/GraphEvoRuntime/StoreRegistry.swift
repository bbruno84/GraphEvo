import CoreData
import Foundation

package enum StoreOpeningMode: Sendable, Equatable {
    case openOrCreate
    case existing
    case new
    /// A cold purge cannot borrow an ordinary graph owner or attach ahead of a peer.
    case appGroupPurgeRecovery(storeID: String)

    var isAppGroupPurgeRecovery: Bool {
        if case .appGroupPurgeRecovery = self { return true }
        return false
    }
}

/// Value-only diagnostics, distinct from domain identity and cloud readiness.
package struct StoreRuntimeSnapshot: Sendable, Equatable {
    package let runtimeID: UUID
    package let location: StoreLocation
    package let access: StoreAccess
    package let schemaIdentifier: String
}

/// One lease on an owner; close is idempotent and concurrent callers await the same outcome.
package actor StoreHandle {
    private let registry: StoreRegistry
    private let key: StoreKey
    private let generation: UUID
    private let token: UUID
    private var closeTask: Task<Void, any Error>?
    private var changeHub: StoreInvalidationHub?
    private var accountHub: StoreAccountAccess?

    fileprivate init(registry: StoreRegistry, key: StoreKey, generation: UUID, token: UUID) {
        self.registry = registry
        self.key = key
        self.generation = generation
        self.token = token
    }

    deinit {
        changeHub?.finish(owner: token); accountHub?.finish(owner: token)
        let registry = registry, key = key, generation = generation, token = token
        Task { try? await registry.release(key, generation: generation, token: token) }
    }

    package func newLease() async throws -> StoreHandle {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.retain(key, generation: generation, token: token)
    }

    package func cloudSetup() async throws -> StoreCloudSetup {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.cloudSetup(key, generation: generation, token: token)
    }

    package func snapshot() async throws -> StoreRuntimeSnapshot {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.snapshot(key, generation: generation, token: token)
    }

    /// Trusted adapter boundary: the synchronous body must not save or escape its context.
    package func transaction<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.transaction(key, generation: generation, token: token, body)
    }

    /// Native framework operations retain admission and the writer gate through their completion.
    package func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.nativeOperation(key, generation: generation, token: token, body)
    }

    package func invalidationFeed(localCommitsOnly: Bool = false) async throws -> StoreInvalidationFeed {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        let hub = try await registry.invalidationHub(key, generation: generation, token: token)
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        changeHub = hub
        return hub.subscribe(owner: token, localCommitsOnly: localCommitsOnly)
    }

    package func close() async throws {
        if let closeTask { return try await closeTask.value }
        changeHub?.finish(owner: token); accountHub?.finish(owner: token)
        let registry = registry, key = key, generation = generation, token = token
        let task = Task { try await registry.release(key, generation: generation, token: token) }
        closeTask = task
        try await task.value
    }

    package func controlRead<Value: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.read(key, generation: generation, token: token, control: true, body)
    }
    package func controlTransaction<Value: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.transaction(key, generation: generation, token: token, control: true, body)
    }
    /// Library preparation may perform awaited file work between synchronous native phases.
    /// The runtime retains writer admission, owns the sole save and always drains cleanup.
    package func preparedControlTransaction<Snapshot: Sendable, Prepared: Sendable, Value: Sendable>(
        prepare: @escaping @Sendable (NSManagedObjectContext) throws -> Snapshot,
        materialize: @escaping @Sendable (Snapshot, StoreNativeContext.CancellationCheck) async throws -> Prepared,
        finish: @escaping @Sendable (NSManagedObjectContext, Prepared) throws -> Value
    ) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.preparedControlTransaction(key, generation: generation, token: token,
            prepare: prepare, materialize: materialize, finish: finish)
    }
    package func inheritAccount(_ control: StoreAccountControl) async throws {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        try await registry.inheritAccount(key, generation: generation, token: token, control: control)
    }
    package func accountControl() async throws -> StoreAccountControl {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        let access = try await registry.accountAccess(key, generation: generation, token: token)
        let hub = try await registry.invalidationHub(key, generation: generation, token: token)
        return StoreAccountControl(access: access, invalidations: hub)
    }
    package func accountPermit() async throws -> StoreAccountPermit {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.accountAccess(key, generation: generation, token: token).permit()
    }
    package func accountStatus() async throws -> StoreAccountStatus {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.accountAccess(key, generation: generation, token: token).status
    }
    package func accountFeed() async throws -> StoreAccountFeed {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        let hub = try await registry.accountAccess(key, generation: generation, token: token)
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        accountHub = hub
        return hub.subscribe(owner: token)
    }
    package func setAccountStatus(_ value: StoreAccountStatus, revision: UInt64) async throws {
        try await registry.setAccountStatus(key, generation: generation, token: token, value: value, revision: revision)
    }
    package func accountControlRead<Value: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.read(key, generation: generation, token: token, control: true, accountControl: true, body)
    }
    package func accountControlTransaction<Value: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.transaction(key, generation: generation, token: token, control: true, accountControl: true, body)
    }
    package func setDataAvailable(_ value: Bool, terminal: Bool = false) async throws {
        try await registry.setDataAvailable(key, generation: generation, token: token, value: value, terminal: terminal)
    }
    package func suspendWrites() async throws -> StoreReservation { try await reserve(.writes) }
    package func restrictActivation(_ id: UUID, reads: Bool = false, release: Bool = false) async throws {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        try await registry.restrictActivation(key, generation: generation, token: token, id: id, reads: reads, release: release)
    }
    package func reserveMaintenance() async throws -> StoreReservation { try await reserve(.all) }
    private func reserve(_ mode: StoreReservationMode) async throws -> StoreReservation {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        let lease = try await newLease(), id = UUID()
        do {
            try await lease.acquireReservation(id, mode: mode)
            return StoreReservation(id: id) { await lease.releaseReservation(id); try? await lease.close() }
        } catch {
            await lease.releaseReservation(id); try? await lease.close(); throw error
        }
    }
    private func acquireReservation(_ id: UUID, mode: StoreReservationMode) async throws {
        try await registry.reserve(key, generation: generation, token: token, id: id, mode: mode)
    }
    private func releaseReservation(_ id: UUID) async {
        await registry.releaseReservation(key, generation: generation, id: id)
    }
    /// Retain native and registry claims through detached owned-workspace filesystem cleanup.
    package func discardWorkspace(_ body: @escaping @Sendable () throws -> Void) async throws {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        try await registry.discardWorkspace(key, generation: generation, token: token, body)
    }
    /// Explicit protected publication on the original; ordinary transactions still obey write holds.
    package func publicationTransaction<Value: Sendable>(graphID: UUID, reservation: StoreReservation,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.publicationTransaction(key, generation: generation, token: token,
            graphID: graphID, reservation: reservation.id, body)
    }
    /// The workspace control path alone may commit under its own exclusive maintenance fence.
    package func workspaceTransaction<Value: Sendable>(reservation: StoreReservation,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.workspaceTransaction(key, generation: generation, token: token, reservation: reservation.id, body)
    }
    package func copyStore(to url: URL, reservation: StoreReservation) async throws {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        try await registry.copyStore(key, generation: generation, token: token, to: url, reservation: reservation.id)
    }
    package func destroy(graphID: UUID, storeID: String) async throws {
        try await registry.destroy(key, generation: generation, token: token, graphID: graphID, storeID: storeID)
    }

    /// Package implementation boundary, not a public raw-context escape hatch.
    package func read<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.read(key, generation: generation, token: token, body)
    }
}

/// Shared production registry; internal initializers allow isolated lifecycle tests.
package actor StoreRegistry {
    private struct ContextClaim {
        let graphID: UUID
        let key: StoreKey
        let owner: UUID
    }
    private var contextClaims: [UUID: ContextClaim] = [:]

    /// Reservations include pending bootstrap before a native destination exists.
    package func claimContextGraph(_ graphID: UUID, key: StoreKey, owner: UUID) throws -> UUID {
        for (token, claim) in contextClaims where claim.graphID == graphID || claim.key == key {
            guard claim.owner == owner, claim.graphID == graphID, claim.key == key else {
                throw StoreRuntimeError.configurationConflict(nil)
            }
            return token
        }
        for entry in entries.values where entry.resolved.key == key || entry.resolved.configuration.exclusiveGraphID == graphID {
            guard entry.resolved.configuration.contextOwnerID == owner else { throw StoreRuntimeError.configurationConflict(nil) }
        }
        let token = UUID()
        contextClaims[token] = ContextClaim(graphID: graphID, key: key, owner: owner)
        return token
    }

    package func releaseContextGraph(_ token: UUID) {
        guard let claim = contextClaims[token] else { return }
        // A failed native close must keep the reservation even without a consumer handle.
        guard !entries.values.contains(where: {
            $0.resolved.configuration.contextOwnerID == claim.owner &&
            $0.resolved.configuration.exclusiveGraphID == claim.graphID
        }) else { return }
        contextClaims.removeValue(forKey: token)
    }

    private func validateContextClaim(_ resolved: ResolvedStore) throws {
        for claim in contextClaims.values where claim.key == resolved.key || claim.graphID == resolved.configuration.exclusiveGraphID {
            if resolved.configuration.access == .readOnly { continue }
            guard resolved.configuration.contextOwnerID == claim.owner else { throw StoreRuntimeError.configurationConflict(resolved.url) }
        }
    }

    package static let shared = StoreRegistry()

    /// Reuses runtime alias validation and canonical keys without acquiring a resource.
    package nonisolated static func resolve(_ configuration: StoreConfiguration) throws -> (key: StoreKey, configuration: StoreConfiguration) {
        let resolved = try ResolvedStore(configuration)
        return (resolved.key, resolved.configuration)
    }


    private struct Entry {
        let generation = UUID()
        let resolved: ResolvedStore
        let schema: StoreSchema
        let nativeMigrationDocument: Data?
        let recoveringAppGroupPurge: Bool
        let opening: Task<StoreResources, any Error>
        var fileIdentities: [StoreKey: FileIdentity] = [:]
        var tokens: Set<UUID> = []
        var shutdown: Task<Void, any Error>?
        var destroyToken: UUID?
        var destroying = false
    }

    private let owner = UUID()
    private var entries: [StoreKey: Entry] = [:]
    private let hooks: StoreLifecycleHooks

    init(hooks: StoreLifecycleHooks = StoreLifecycleHooks()) { self.hooks = hooks }

    /// Check a restart-supplied App Group path without admitting a second native owner.
    package nonisolated static func validateAppGroupIdentity(_ configuration: StoreConfiguration, storeID: String) async throws {
        let resolved = try ResolvedStore(configuration)
        guard configuration.appGroup != nil, let url = resolved.url, let graphID = configuration.exclusiveGraphID else {
            throw StoreRuntimeError.resourceReserved
        }
        let writer = try await StoreProcessLock.acquire(resolved)
        defer { writer.release() }
        let presenter = AppGroupStorePresenter(directory: url.deletingLastPathComponent())
        try await AppGroupStoreAccess(presenter: presenter, associatePresenter: false).run {
            try StoreResources.validateDestructionIdentity(url, graphID: graphID, storeID: storeID)
        }
    }

    package func open(_ configuration: StoreConfiguration, schema: StoreSchema,
                      nativeMigration: StoreNativeMigration? = nil,
                      mode: StoreOpeningMode = .openOrCreate) async throws -> StoreHandle {
        try Task.checkCancellation()
        let resolved = try ResolvedStore(configuration)
        if mode.isAppGroupPurgeRecovery, configuration.appGroup == nil {
            throw StoreRuntimeError.invalidConfiguration("App Group purge recovery requires App Group admission.")
        }
        if configuration.appGroup != nil, mode == .openOrCreate {
            throw StoreRuntimeError.invalidConfiguration("App Group stores require explicit creation or opening.")
        }
        try validateContextClaim(resolved)
        while true {
            if let entry = entries[resolved.key], let shutdown = entry.shutdown {
                try await shutdown.value
                if entries[resolved.key]?.generation == entry.generation { entries.removeValue(forKey: resolved.key) }
                try Task.checkCancellation()
                continue
            }
            let identities = try resolved.resourceIdentities()
            let requestedKeys = Set(try resolved.resources.map(\.key))
            for (key, entry) in entries where key != resolved.key {
                let ownedKeys = Set(try entry.resolved.resources.map(\.key))
                guard requestedKeys.isDisjoint(with: ownedKeys) else {
                    throw StoreRuntimeError.configurationConflict(resolved.url)
                }
                let observed = (try? entry.resolved.resourceIdentities()) ?? [:]
                let ownedIdentities = entry.fileIdentities.merging(observed) { recorded, _ in recorded }
                if !Set(identities.values).isDisjoint(with: Set(ownedIdentities.values)), let url = resolved.url {
                    throw StoreRuntimeError.unsupportedFileAlias(url)
                }
            }
            if let entry = entries[resolved.key] {
                if mode == .new, let url = resolved.url { throw StoreRuntimeError.storeAlreadyExists(url) }
                guard !mode.isAppGroupPurgeRecovery, !entry.recoveringAppGroupPurge else {
                    throw StoreRuntimeError.resourceReserved
                }
                guard try entry.resolved.isCompatible(with: resolved), entry.schema.isCompatible(with: schema),
                      entry.nativeMigrationDocument == nativeMigration?.document else {
                    throw StoreRuntimeError.configurationConflict(resolved.url)
                }
                try validateIdentities(entry.fileIdentities, current: identities, resolved: resolved)
            } else {
                let hooks = hooks, owner = owner, expectedIdentity = identities[resolved.key]
                let opening = Task.detached {
                    try await StoreResources.open(resolved, schema: schema, hooks: hooks, owner: owner,
                        nativeMigration: nativeMigration, mode: mode, expectedIdentity: expectedIdentity)
                }
                entries[resolved.key] = Entry(resolved: resolved, schema: schema, nativeMigrationDocument: nativeMigration?.document,
                                             recoveringAppGroupPurge: mode.isAppGroupPurgeRecovery,
                                             opening: opening, fileIdentities: identities)
            }
            let token = UUID()
            entries[resolved.key]!.tokens.insert(token)
            let entry = entries[resolved.key]!
            if let didReserveHandle = hooks.didReserveHandle { await didReserveHandle() }
            do {
                _ = try await entry.opening.value
            } catch {
                if entries[resolved.key]?.generation == entry.generation {
                    if let quarantine = error as? StoreOpenQuarantine {
                        entries[resolved.key]?.tokens.removeAll()
                        entries[resolved.key]?.shutdown = Task { throw quarantine.failure }
                    } else { entries.removeValue(forKey: resolved.key) }
                }
                throw (error as? StoreOpenQuarantine)?.failure ?? error
            }
            do {
                let current = try resolved.resourceIdentities()
                guard let registered = entries[resolved.key], registered.generation == entry.generation,
                      registered.tokens.contains(token) else { throw StoreRuntimeError.closedHandle }
                try validateIdentities(registered.fileIdentities, current: current, resolved: resolved)
                if entries[resolved.key]?.generation == entry.generation {
                    entries[resolved.key]?.fileIdentities = current
                }
                // A successful native initializer has sealed a durable conversion.
                // Drain it and return its handle; the bootstrap reports any later
                // caller cancellation separately from that committed outcome.
                if nativeMigration == nil { try Task.checkCancellation() }
            } catch {
                try await release(resolved.key, generation: entry.generation, token: token)
                throw error
            }
            return StoreHandle(registry: self, key: resolved.key, generation: entry.generation, token: token)
        }
    }

    fileprivate func invalidationHub(_ key: StoreKey, generation: UUID, token: UUID) async throws -> StoreInvalidationHub {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        _ = try self.entry(for: key, generation: generation, token: token)
        return resources.invalidations
    }

    fileprivate func nativeOperation<Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID,
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.nativeOperation(body)
    }

    fileprivate func retain(_ key: StoreKey, generation: UUID, token: UUID) throws -> StoreHandle {
        _ = try entry(for: key, generation: generation, token: token)
        let next = UUID()
        entries[key]?.tokens.insert(next)
        return StoreHandle(registry: self, key: key, generation: generation, token: next)
    }

    fileprivate func cloudSetup(_ key: StoreKey, generation: UUID, token: UUID) async throws -> StoreCloudSetup {
        let entry = try entry(for: key, generation: generation, token: token)
        return await (try await entry.opening.value).cloudSetup()
    }

    fileprivate func snapshot(_ key: StoreKey, generation: UUID, token: UUID) async throws -> StoreRuntimeSnapshot {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.read(control: true) { _ in
            StoreRuntimeSnapshot(runtimeID: resources.id, location: entry.resolved.configuration.location,
                                 access: entry.resolved.configuration.access, schemaIdentifier: entry.schema.identifier)
        }
    }

    fileprivate func read<Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID, control: Bool = false, accountControl: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.read(control: control, accountControl: accountControl, body)
    }

    fileprivate func transaction<Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID, control: Bool = false, accountControl: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.transaction(control: control, accountControl: accountControl, body)
    }

    fileprivate func preparedControlTransaction<Snapshot: Sendable, Prepared: Sendable, Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID,
        prepare: @escaping @Sendable (NSManagedObjectContext) throws -> Snapshot,
        materialize: @escaping @Sendable (Snapshot, StoreNativeContext.CancellationCheck) async throws -> Prepared,
        finish: @escaping @Sendable (NSManagedObjectContext, Prepared) throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.preparedControlTransaction(prepare: prepare, materialize: materialize, finish: finish)
    }

    fileprivate func inheritAccount(_ key: StoreKey, generation: UUID, token: UUID, control: StoreAccountControl) async throws {
        let entry = try entry(for: key, generation: generation, token: token)
        try await entry.opening.value.inheritAccount(control)
    }
    fileprivate func accountAccess(_ key: StoreKey, generation: UUID, token: UUID) async throws -> StoreAccountAccess {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        _ = try self.entry(for: key, generation: generation, token: token)
        return await resources.effectiveAccountAccess
    }
    fileprivate func setAccountStatus(_ key: StoreKey, generation: UUID, token: UUID, value: StoreAccountStatus, revision: UInt64) async throws {
        let entry = try entry(for: key, generation: generation, token: token)
        try await entry.opening.value.setAccountStatus(value, revision: revision)
    }
    fileprivate func setDataAvailable(_ key: StoreKey, generation: UUID, token: UUID, value: Bool, terminal: Bool) async throws {
        let entry = try entry(for: key, generation: generation, token: token)
        try await entry.opening.value.setDataAvailable(value, terminal: terminal)
    }
    fileprivate func restrictActivation(_ key: StoreKey, generation: UUID, token: UUID, id: UUID, reads: Bool, release: Bool) async throws {
        let entry = try entry(for: key, generation: generation, token: token)
        try await entry.opening.value.restrictActivation(id, reads: reads, release: release)
    }
    fileprivate func reserve(_ key: StoreKey, generation: UUID, token: UUID, id: UUID, mode: StoreReservationMode) async throws {
        let value = try entry(for: key, generation: generation, token: token)
        try await value.opening.value.reserve(id, mode: mode)
    }
    fileprivate func releaseReservation(_ key: StoreKey, generation: UUID, id: UUID) async {
        guard let value = entries[key], value.generation == generation else { return }
        if let resources = try? await value.opening.value { await resources.releaseReservation(id) }
    }
    fileprivate func discardWorkspace(_ key: StoreKey, generation: UUID, token: UUID,
                                     _ body: @escaping @Sendable () throws -> Void) async throws {
        guard var value = entries[key], value.generation == generation, value.resolved.configuration.workspaceID != nil,
              value.destroyToken == token || (value.destroyToken == nil && value.tokens == [token] && value.shutdown == nil) else {
            throw StoreRuntimeError.configurationConflict(nil)
        }
        if value.destroying, let task = value.shutdown { return try await task.value }
        let opening = value.opening
        value.destroyToken = token; value.destroying = true; value.tokens.removeAll()
        let task = Task { try await opening.value.discardWorkspace(body) }
        value.shutdown = task; entries[key] = value
        do {
            try await task.value
            if entries[key]?.generation == generation { entries.removeValue(forKey: key) }
        } catch {
            if entries[key]?.generation == generation { entries[key]?.destroying = false }
            throw error
        }
    }
    fileprivate func publicationTransaction<Value: Sendable>(_ key: StoreKey, generation: UUID, token: UUID,
        graphID: UUID, reservation: UUID, _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        let value = try entry(for: key, generation: generation, token: token)
        return try await value.opening.value.publicationTransaction(graphID: graphID, reservation: reservation, body)
    }
    fileprivate func workspaceTransaction<Value: Sendable>(_ key: StoreKey, generation: UUID, token: UUID, reservation: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        let value = try entry(for: key, generation: generation, token: token)
        return try await value.opening.value.workspaceTransaction(reservation: reservation, body)
    }
    fileprivate func copyStore(_ key: StoreKey, generation: UUID, token: UUID, to url: URL, reservation: UUID) async throws {
        let value = try entry(for: key, generation: generation, token: token)
        try await value.opening.value.copyStore(to: url, reservation: reservation)
    }

    fileprivate func destroy(_ key: StoreKey, generation: UUID, token: UUID, graphID: UUID, storeID: String) async throws {
        guard var value = entries[key], value.generation == generation,
              value.resolved.configuration.exclusiveGraphID == graphID,
              value.destroyToken == token || (value.destroyToken == nil && value.tokens.contains(token) && value.shutdown == nil) else {
            throw StoreRuntimeError.closedHandle
        }
        if value.destroying, let job = value.shutdown { return try await job.value }
        if value.destroyToken == nil {
            try validateIdentities(value.fileIdentities, current: value.resolved.resourceIdentities(), resolved: value.resolved)
        }
        let opening = value.opening
        value.destroyToken = token; value.destroying = true; value.tokens.removeAll()
        let job = Task { try await opening.value.destroy(graphID: graphID, storeID: storeID) }
        value.shutdown = job; entries[key] = value
        do {
            try await job.value
            if entries[key]?.generation == generation { entries.removeValue(forKey: key) }
        } catch {
            if entries[key]?.generation == generation { entries[key]?.destroying = false }
            throw error
        }
    }

    private func entry(for key: StoreKey, generation: UUID, token: UUID) throws -> Entry {
        guard let entry = entries[key], entry.generation == generation,
              entry.shutdown == nil, entry.tokens.contains(token) else { throw StoreRuntimeError.closedHandle }
        try validateIdentities(entry.fileIdentities, current: entry.resolved.resourceIdentities(), resolved: entry.resolved)
        return entry
    }

    private func validateIdentities(_ previous: [StoreKey: FileIdentity], current: [StoreKey: FileIdentity],
                                    resolved: ResolvedStore) throws {
        for resource in try resolved.resources {
            if let identity = previous[resource.key], identity != current[resource.key], let url = resource.url {
                throw StoreRuntimeError.storeReplaced(url)
            }
        }
    }

    fileprivate func release(_ key: StoreKey, generation: UUID, token: UUID) async throws {
        guard var entry = entries[key], entry.generation == generation,
              entry.tokens.remove(token) != nil else { return }
        if !entry.tokens.isEmpty { entries[key] = entry; return }
        let opening = entry.opening
        let shutdown = Task { try await opening.value.close() }
        entry.shutdown = shutdown
        entries[key] = entry
        try await shutdown.value
        if entries[key]?.generation == generation { entries.removeValue(forKey: key) }
    }
}
