import CoreData
import Foundation

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

    fileprivate init(registry: StoreRegistry, key: StoreKey, generation: UUID, token: UUID) {
        self.registry = registry
        self.key = key
        self.generation = generation
        self.token = token
    }

    deinit {
        let registry = registry, key = key, generation = generation, token = token
        Task { try? await registry.release(key, generation: generation, token: token) }
    }

    package func newLease() async throws -> StoreHandle {
        guard closeTask == nil else { throw StoreRuntimeError.closedHandle }
        return try await registry.retain(key, generation: generation, token: token)
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

    package func close() async throws {
        if let closeTask { return try await closeTask.value }
        let registry = registry, key = key, generation = generation, token = token
        let task = Task { try await registry.release(key, generation: generation, token: token) }
        closeTask = task
        try await task.value
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
    package static let shared = StoreRegistry()

    private struct Entry {
        let generation = UUID()
        let resolved: ResolvedStore
        let schema: StoreSchema
        let opening: Task<StoreResources, any Error>
        var fileIdentity: FileIdentity?
        var tokens: Set<UUID> = []
        var shutdown: Task<Void, any Error>?
    }

    private let owner = UUID()
    private var entries: [StoreKey: Entry] = [:]
    private let hooks: StoreLifecycleHooks

    init(hooks: StoreLifecycleHooks = StoreLifecycleHooks()) { self.hooks = hooks }

    package func open(_ configuration: StoreConfiguration, schema: StoreSchema) async throws -> StoreHandle {
        try Task.checkCancellation()
        let resolved = try ResolvedStore(configuration)
        while true {
            if let entry = entries[resolved.key], let shutdown = entry.shutdown {
                try await shutdown.value
                if entries[resolved.key]?.generation == entry.generation { entries.removeValue(forKey: resolved.key) }
                try Task.checkCancellation()
                continue
            }
            let identity = try resolved.fileIdentity()
            for (key, entry) in entries where key != resolved.key {
                let ownedIdentity = entry.fileIdentity ?? (try? entry.resolved.fileIdentity())
                if let identity, identity == ownedIdentity, let url = resolved.url {
                    throw StoreRuntimeError.unsupportedFileAlias(url)
                }
            }
            if let entry = entries[resolved.key] {
                guard entry.resolved.configuration.access == resolved.configuration.access,
                      entry.resolved.configuration.cloudKitContainerIdentifier == resolved.configuration.cloudKitContainerIdentifier,
                      entry.schema.isCompatible(with: schema) else {
                    throw StoreRuntimeError.configurationConflict(resolved.url)
                }
                if let previous = entry.fileIdentity, previous != identity, let url = resolved.url {
                    throw StoreRuntimeError.storeReplaced(url)
                }
            } else {
                let hooks = hooks, owner = owner
                let opening = Task.detached { try await StoreResources.open(resolved, schema: schema, hooks: hooks, owner: owner) }
                entries[resolved.key] = Entry(resolved: resolved, schema: schema, opening: opening, fileIdentity: identity)
            }
            let token = UUID()
            entries[resolved.key]!.tokens.insert(token)
            let entry = entries[resolved.key]!
            if let didReserveHandle = hooks.didReserveHandle { await didReserveHandle() }
            do {
                _ = try await entry.opening.value
            } catch {
                if entries[resolved.key]?.generation == entry.generation { entries.removeValue(forKey: resolved.key) }
                throw error
            }
            do {
                let current = try resolved.fileIdentity()
                guard let registered = entries[resolved.key], registered.generation == entry.generation,
                      registered.tokens.contains(token) else { throw StoreRuntimeError.closedHandle }
                if let previous = registered.fileIdentity, previous != current, let url = resolved.url {
                    throw StoreRuntimeError.storeReplaced(url)
                }
                if entries[resolved.key]?.generation == entry.generation {
                    entries[resolved.key]?.fileIdentity = current
                }
                try Task.checkCancellation()
            } catch {
                try await release(resolved.key, generation: entry.generation, token: token)
                throw error
            }
            return StoreHandle(registry: self, key: resolved.key, generation: entry.generation, token: token)
        }
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

    fileprivate func snapshot(_ key: StoreKey, generation: UUID, token: UUID) async throws -> StoreRuntimeSnapshot {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.read { _ in
            StoreRuntimeSnapshot(runtimeID: resources.id, location: entry.resolved.configuration.location,
                                 access: entry.resolved.configuration.access, schemaIdentifier: entry.schema.identifier)
        }
    }

    fileprivate func read<Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.read(body)
    }

    fileprivate func transaction<Value: Sendable>(
        _ key: StoreKey, generation: UUID, token: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        let entry = try entry(for: key, generation: generation, token: token)
        let resources = try await entry.opening.value
        return try await resources.transaction(body)
    }

    private func entry(for key: StoreKey, generation: UUID, token: UUID) throws -> Entry {
        guard let entry = entries[key], entry.generation == generation,
              entry.shutdown == nil, entry.tokens.contains(token) else { throw StoreRuntimeError.closedHandle }
        if let previous = entry.fileIdentity, previous != (try entry.resolved.fileIdentity()), let url = entry.resolved.url {
            throw StoreRuntimeError.storeReplaced(url)
        }
        return entry
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
