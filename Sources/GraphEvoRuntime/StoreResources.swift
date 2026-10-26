import CoreData
import Foundation

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var beforeDetach: (@Sendable () async throws -> Void)?
}

/// One container and one private context. Admission counts cover actor reentrancy.
actor StoreResources {
    let id = UUID()
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let resolved: ResolvedStore
    private let hooks: StoreLifecycleHooks
    private var closing = false
    private var admitted = 0
    private var drain: CheckedContinuation<Void, Never>?

    private init(container: NSPersistentContainer, resolved: ResolvedStore, hooks: StoreLifecycleHooks) {
        self.container = container
        self.resolved = resolved
        self.hooks = hooks
        context = container.newBackgroundContext()
    }

    static func open(
        _ resolved: ResolvedStore,
        schema: StoreSchema,
        hooks: StoreLifecycleHooks
    ) async throws -> StoreResources {
        try await hooks.beforeLoad?()
        let model = schema.makeModel()
        guard !schema.identifier.isEmpty, !schema.entityVersionHashes.isEmpty,
              model.entityVersionHashesByName == schema.entityVersionHashes else {
            throw StoreRuntimeError.invalidModel(schema.identifier)
        }
        let description: NSPersistentStoreDescription
        switch resolved.configuration.location {
        case .sqlite(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata: [String: Any]
                do {
                    metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
                } catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
                guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
                    throw StoreRuntimeError.incompatibleStore(url)
                }
            } else if resolved.configuration.access == .readOnly {
                throw StoreRuntimeError.invalidConfiguration("A read-only SQLite store must already exist.")
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
            description = NSPersistentStoreDescription(url: url)
            description.type = NSSQLiteStoreType
            description.isReadOnly = resolved.configuration.access == .readOnly
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        case .inMemory:
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        }
        description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        let container = NSPersistentContainer(name: schema.identifier, managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                container.loadPersistentStores { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch { throw StoreRuntimeError.loadFailed(resolved.url, underlying: error) }
        let resources = StoreResources(container: container, resolved: resolved, hooks: hooks)
        await resources.configureContext()
        return resources
    }

    private func configureContext() async {
        let context = context
        await context.perform {
            context.name = "GraphEvo.v2.runtime"
            context.undoManager = nil
            context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        }
    }

    /// Internal read boundary. A2 will add the distinct mutation/commit contract.
    func read<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        try Task.checkCancellation()
        admitted += 1
        defer {
            admitted -= 1
            if admitted == 0 { drain?.resume(); drain = nil }
        }
        let context = context
        return try await context.perform {
            defer { context.rollback(); context.reset() }
            let value = try body(context)
            guard !context.hasChanges else { throw StoreRuntimeError.mutationInReadScope }
            return value
        }
    }

    /// The registry invokes shutdown only once and retains ownership if detachment fails.
    func close() async throws {
        closing = true
        if admitted > 0 {
            await withCheckedContinuation { drain = $0 }
        }
        let context = context
        await context.perform { context.reset() }
        do {
            try await hooks.beforeDetach?()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        } catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
    }
}
