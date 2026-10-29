import CoreData
import CloudKit
import Foundation
import os

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var afterCommit: (@Sendable () -> Void)?
    var didQueueWriter: (@Sendable () async -> Void)?
    var didBeginClose: (@Sendable () async -> Void)?
    var beforeDetach: (@Sendable () async throws -> Void)?
    var didLoadStore: (@Sendable (URL?) throws -> Void)?
}

/// One container with operation-scoped private contexts. Admission covers actor reentrancy.
actor StoreResources {
    let id = UUID()
    private let gateways: [StoreGatewayLease]
    private let container: NSPersistentContainer
    private let resolved: ResolvedStore
    private let hooks: StoreLifecycleHooks
    private var eventObserver: NSObjectProtocol?
    private var changeObservers: [NSObjectProtocol] = []
    nonisolated let invalidations = StoreInvalidationHub()
    private let setupTracker = StoreCloudSetupTracker()
    private var writerBusy = false
    private var writers: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var closing = false
    private var admitted = 0
    private var drain: CheckedContinuation<Void, Never>?

    private init(container: NSPersistentContainer, resolved: ResolvedStore, hooks: StoreLifecycleHooks, gateways: [StoreGatewayLease]) {
        self.gateways = gateways
        self.container = container
        self.resolved = resolved
        self.hooks = hooks
    }

    static func open(
        _ resolved: ResolvedStore,
        schema: StoreSchema,
        hooks: StoreLifecycleHooks,
        owner: UUID
    ) async throws -> StoreResources {
        let members = try resolved.resources
        let gateways = try members.map { try StoreGatewayLease.acquire($0.configuration, owner: owner) }
        try await hooks.beforeLoad?()
        let model = schema.makeModel()
        guard !schema.identifier.isEmpty, !schema.entityVersionHashes.isEmpty,
              model.entityVersionHashesByName == schema.entityVersionHashes,
              schema.requiredModelVersionIdentifier.map({ model.versionIdentifiers == [AnyHashable($0)] }) ?? true else {
            throw StoreRuntimeError.invalidModel(schema.identifier)
        }
        let descriptions = try members.enumerated().map { index, member in
            let description = try storeDescription(member, model: model, requiredModelVersionIdentifier: schema.requiredModelVersionIdentifier)
            if let identifier = resolved.configuration.cloudKitContainerIdentifier {
                guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      resolved.url != nil, resolved.configuration.access == .readWrite else {
                    throw StoreRuntimeError.invalidConfiguration("Mirroring requires writable SQLite resources and a container identifier.")
                }
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
                options.databaseScope = index == 0 ? .private : .shared
                description.cloudKitContainerOptions = options
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
            return description
        }
        let container: NSPersistentContainer
        if resolved.configuration.cloudKitContainerIdentifier != nil {
            container = NSPersistentCloudKitContainer(name: schema.identifier, managedObjectModel: model)
        } else { container = NSPersistentContainer(name: schema.identifier, managedObjectModel: model) }
        container.persistentStoreDescriptions = descriptions
        let resources = StoreResources(container: container, resolved: resolved, hooks: hooks, gateways: gateways)
        do { try await resources.load() }
        catch {
            let failure = StoreRuntimeError.loadFailed(resolved.url, underlying: error)
            do { try await resources.detach() }
            catch {
                throw StoreOpenQuarantine(resources: resources,
                    failure: StoreRuntimeError.shutdownFailed(resolved.url, underlying: error))
            }
            throw failure
        }
        return resources
    }

    private static func storeDescription(_ resolved: ResolvedStore, model: NSManagedObjectModel,
                                         requiredModelVersionIdentifier: String?) throws -> NSPersistentStoreDescription {
        let description: NSPersistentStoreDescription
        switch resolved.configuration.location {
        case .sqlite(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata: [String: Any]
                do { metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url) }
                catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
                guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                      requiredModelVersionIdentifier.map({ metadata[NSStoreModelVersionIdentifiersKey] as? [String] == [$0] }) ?? true else {
                    throw StoreRuntimeError.incompatibleStore(url)
                }
            } else if resolved.configuration.access == .readOnly {
                throw StoreRuntimeError.invalidConfiguration("A read-only SQLite store must already exist.")
            }
            do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
            description = NSPersistentStoreDescription(url: url)
            description.type = NSSQLiteStoreType
            description.isReadOnly = resolved.configuration.access == .readOnly
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        case .inMemory:
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        }
        description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        return description
    }

    private func load() async throws {
        let hub = invalidations, coordinator = container.persistentStoreCoordinator
        changeObservers.append(NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
            object: nil, queue: nil) { [weak coordinator] note in
            // didSave is delivered on the saving context's queue; no context escapes this callback.
            guard let context = note.object as? NSManagedObjectContext,
                  let coordinator, context.persistentStoreCoordinator === coordinator else { return }
            hub.publish(.contextSave)
        })
        changeObservers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: coordinator, queue: nil) { _ in hub.publish(.storeChange) })
        if container is NSPersistentCloudKitContainer {
            changeObservers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged,
                object: nil, queue: nil) { _ in hub.publish(.accountChange) })
            changeObservers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container, queue: nil) { note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                      event.endDate != nil else { return }
                // Share metadata can change without a persistent-history transaction.
                hub.publish(.nativeOperation)
            })
        }
        if let cloud = container as? NSPersistentCloudKitContainer {
            let tracker = setupTracker
            eventObserver = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: cloud, queue: nil) { note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                      event.type == .setup, event.endDate != nil else { return }
                let identifier = event.storeIdentifier, success = event.succeeded
                let failure = event.error.map { (($0 as NSError).domain, ($0 as NSError).code) }
                tracker.record(identifier, success: success, failure: failure)
            }
        }
        let progress = StoreLoadProgress(count: container.persistentStoreDescriptions.count)
        let hook = hooks.didLoadStore
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { description, error in
                var failure: (any Error)? = error
                if failure == nil {
                    do { try hook?(description.url) } catch { failure = error }
                }
                if let result = progress.finish(failure) { continuation.resume(with: result) }
            }
        }
    }

    func cloudSetup() -> StoreCloudSetup {
        setupTracker.snapshot(configured: resolved.configuration.cloudKitContainerIdentifier != nil,
            identifiers: container.persistentStoreCoordinator.persistentStores.map(\.identifier))
    }

    /// Trusted adapter boundary: bodies return values and must never save or escape contexts.
    func read<Value: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        try admit()
        defer { finish() }
        let cancellation = OperationCancellation()
        let sqlite = resolved.url != nil
        let configuration = resolved.configuration, container = container
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context, configuration: configuration, container: container)
                let check: StoreNativeContext.CancellationCheck = { try cancellation.check() }
                context.userInfo[StoreNativeContext.cancellationKey] = check
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
            let hooks = hooks, configuration = resolved.configuration, container = container
            return try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context, configuration: configuration, container: container)
                let check: StoreNativeContext.CancellationCheck = { try cancellation.check() }
                context.userInfo[StoreNativeContext.cancellationKey] = check
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

    /// Privileged framework work; the completion must settle before this owner can detach.
    func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        try admit()
        defer { finish() }
        let request = UUID(), cancellation = OperationCancellation()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            try cancellation.check()
            // Native APIs own their cancellation semantics once started. Await their real outcome.
            defer { invalidations.publish(.nativeOperation) }
            return try await body(container)
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private static func prepare(_ context: NSManagedObjectContext, configuration: StoreConfiguration, container: NSPersistentContainer) {
        if case .sqlite(let url) = configuration.location { context.userInfo[StoreNativeContext.privateURLKey] = url }
        context.userInfo[StoreNativeContext.sharedURLKey] = configuration.sharedStoreURL
        context.userInfo[StoreNativeContext.containerKey] = container
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
        invalidations.finish()
        await hooks.didBeginClose?()
        if admitted > 0 {
            await withCheckedContinuation { drain = $0 }
        }
        do { try await detach() }
        catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
    }

    private func detach() async throws {
        try await hooks.beforeDetach?()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        eventObserver = nil
        for observer in changeObservers { NotificationCenter.default.removeObserver(observer) }
        changeObservers.removeAll()
        invalidations.finish()
        for gateway in gateways { gateway.release() }
    }
}

/// Retains a failed native owner if partial loading could not be safely detached.
struct StoreOpenQuarantine: Error {
    let resources: StoreResources
    let failure: any Error
}

private final class StoreLoadProgress: Sendable {
    private struct State: Sendable {
        var remaining: Int
        var error: (any Error)?
    }
    private let state: OSAllocatedUnfairLock<State>
    init(count: Int) { state = OSAllocatedUnfairLock(initialState: State(remaining: count)) }
    func finish(_ error: (any Error)?) -> Result<Void, any Error>? {
        state.withLock { state in
            if state.error == nil { state.error = error }
            state.remaining -= 1
            guard state.remaining == 0 else { return nil }
            return state.error.map { .failure($0) } ?? .success(())
        }
    }
}
