import CoreData
import Foundation

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var afterCommit: (@Sendable () -> Void)?
    var didQueueWriter: (@Sendable () async -> Void)?
    var didBeginClose: (@Sendable () async -> Void)?
    var beforeDetach: (@Sendable () async throws -> Void)?
}

/// One container with operation-scoped private contexts. Admission covers actor reentrancy.
actor StoreResources {
    let id = UUID()
    private let container: NSPersistentContainer
    private let resolved: ResolvedStore
    private let hooks: StoreLifecycleHooks
    private var writerBusy = false
    private var writers: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var closing = false
    private var admitted = 0
    private var drain: CheckedContinuation<Void, Never>?

    private init(container: NSPersistentContainer, resolved: ResolvedStore, hooks: StoreLifecycleHooks) {
        self.container = container
        self.resolved = resolved
        self.hooks = hooks
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
        return StoreResources(container: container, resolved: resolved, hooks: hooks)
    }

    /// Trusted adapter boundary: bodies return values and must never save or escape contexts.
    func read<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        try admit()
        defer { finish() }
        let cancellation = OperationCancellation()
        let sqlite = resolved.url != nil
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context)
                defer { context.rollback(); context.reset() }
                try cancellation.check()
                if sqlite { try context.setQueryGenerationFrom(.current) }
                let value = try body(context)
                guard !context.hasChanges else { throw StoreRuntimeError.mutationInReadScope }
                try cancellation.check()
                return value
            }
        } onCancel: { cancellation.cancel() }
    }

    /// FIFO among admitted local writers; native save is the cancellation boundary.
    func transaction<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        try admit()
        defer { finish() }
        let cancellation = OperationCancellation()
        let request = UUID()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            let hooks = hooks
            return try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context)
                defer { context.rollback(); context.reset() }
                try cancellation.check()
                let value = try body(context)
                try cancellation.check()
                if context.hasChanges { try context.save() }
                // A completed save is success even if cancellation arrives during save.
                hooks.afterCommit?()
                return value
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private static func prepare(_ context: NSManagedObjectContext) {
        context.name = "GraphEvo.v2.runtime"
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = "GraphEvo.v2.local"
    }

    private func admit() throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        try Task.checkCancellation()
        admitted += 1
    }

    private func finish() {
        admitted -= 1
        if admitted == 0 { drain?.resume(); drain = nil }
    }

    private func acquireWriter(_ request: UUID, cancellation: OperationCancellation) async throws {
        try cancellation.check()
        if !writerBusy { writerBusy = true; return }
        try await withCheckedThrowingContinuation { continuation in
            writers.append((request, continuation))
            if let hook = hooks.didQueueWriter { Task { await hook() } }
        }
    }

    private func cancelWriter(_ request: UUID) {
        guard let index = writers.firstIndex(where: { $0.0 == request }) else { return }
        writers.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseWriter() {
        if writers.isEmpty { writerBusy = false }
        else { writers.removeFirst().1.resume() }
    }

    /// The registry invokes shutdown only once and retains ownership if detachment fails.
    func close() async throws {
        closing = true
        await hooks.didBeginClose?()
        if admitted > 0 {
            await withCheckedContinuation { drain = $0 }
        }
        do {
            try await hooks.beforeDetach?()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        } catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
    }
}
