import CoreData
import Foundation
import os

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var processRole: StoreProcessRole?
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var afterCommit: (@Sendable () -> Void)?
    var didQueueWriter: (@Sendable () async -> Void)?
    var didRestrictWrites: (@Sendable () -> Void)?
    var didBeginClose: (@Sendable () async -> Void)?
    var beforeDetach: (@Sendable () async throws -> Void)?
    var beforeDestroy: (@Sendable () async throws -> Void)?
    var beforeDestroyedArtifactCleanup: (@Sendable () async throws -> Void)?
    var didDestroy: (@Sendable () async throws -> Void)?
    var didLoadStore: (@Sendable (URL?) throws -> Void)?
}

/// One container with operation-scoped private contexts. Admission covers actor reentrancy.
actor StoreResources {
    let id = UUID()
    private let gateways: [StoreGatewayLease]
    private let container: NSPersistentContainer
    private let resolved: ResolvedStore
    private let hooks: StoreLifecycleHooks
    private var legacyMirroring: LegacyStoreMirroring?
    private var changeObservers: [NSObjectProtocol] = []
    nonisolated let invalidations = StoreInvalidationHub()
    private var writerBusy = false
    private var writers: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var closing = false
    private var dataAvailable = true
    private var terminalDataBlock = false
    private var destructionIssued = false
    private struct DestructionArtifact: Equatable {
        let identity: FileIdentity
        let size: UInt64
        let modified: Date
    }
    private var destructionArtifacts: [URL: DestructionArtifact]?
    private var admitted = 0
    private var admittedWriters = 0
    private var reservations: [UUID: StoreReservationMode] = [:]
    private var reservationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
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
        try (hooks.processRole ?? StoreProcessRole.current).validate(resolved.configuration)
        let members = try resolved.resources
        let gateways = try members.map { try StoreGatewayLease.acquire($0.configuration, owner: owner) }
        try await hooks.beforeLoad?()
        let model = schema.makeModel()
        guard !schema.identifier.isEmpty, !schema.entityVersionHashes.isEmpty,
              model.entityVersionHashesByName == schema.entityVersionHashes,
              schema.requiredModelVersionIdentifier.map({ model.versionIdentifiers == [AnyHashable($0)] }) ?? true else {
            throw StoreRuntimeError.invalidModel(schema.identifier)
        }
        let descriptions = try members.map { member in
            try storeDescription(member, model: model, requiredModelVersionIdentifier: schema.requiredModelVersionIdentifier,
                                 nativeMirroring: resolved.configuration.cloudKitContainerIdentifier != nil)
        }
        let container: NSPersistentContainer
        if resolved.configuration.cloudKitContainerIdentifier != nil {
            container = try LegacyStoreMirroring.makeContainer(name: schema.identifier, model: model,
                descriptions: descriptions, configuration: resolved.configuration)
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
                                         requiredModelVersionIdentifier: String?, nativeMirroring: Bool) throws -> NSPersistentStoreDescription {
        let description: NSPersistentStoreDescription
        switch resolved.configuration.location {
        case .sqlite(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata: [String: Any]
                do { metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url) }
                catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
                if let marker = metadata[StoreNativeContext.workspaceKey] {
                    guard let expected = resolved.configuration.workspaceID,
                          marker as? String == expected.uuidString,
                          metadata[StoreNativeContext.historySyncGraphKey] as? String == resolved.configuration.exclusiveGraphID?.uuidString else {
                        throw StoreRuntimeError.invalidConfiguration("An isolated migration workspace requires its exact admission identity.")
                    }
                } else if resolved.configuration.workspaceID != nil {
                    throw StoreRuntimeError.invalidConfiguration("The migration workspace marker is missing.")
                }
                if nativeMirroring && metadata[StoreNativeContext.historySyncGraphKey] != nil {
                    throw StoreRuntimeError.invalidConfiguration("A history-sync store cannot be opened by native CloudKit mirroring.")
                }
                guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                      requiredModelVersionIdentifier.map({ metadata[NSStoreModelVersionIdentifiersKey] as? [String] == [$0] }) ?? true else {
                    throw StoreRuntimeError.incompatibleStore(url)
                }
            } else if resolved.configuration.workspaceID != nil || resolved.configuration.access == .readOnly {
                throw StoreRuntimeError.missingStore(url)
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
            hub.publish(.contextSave, transactionAuthor: context.transactionAuthor)
        })
        changeObservers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: coordinator, queue: nil) { _ in hub.publish(.storeChange) })
        legacyMirroring = LegacyStoreMirroring(container: container, invalidations: hub)
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
        let identifiers: [String] = container.persistentStoreCoordinator.persistentStores.map(\.identifier)
        return legacyMirroring?.snapshot(identifiers: identifiers) ?? StoreCloudSetup(configured: false,
            storeCount: identifiers.count, readyStoreCount: 0, latestFailureDomain: nil, latestFailureCode: nil)
    }

    /// Trusted adapter boundary: bodies return values and must never save or escape contexts.
    func read<Value: Sendable>(control: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard control || dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        try admit()
        defer { finish() }
        let cancellation = OperationCancellation()
        let sqlite = resolved.url != nil
        let memoryRequest = sqlite ? nil : UUID()
        let configuration = resolved.configuration, container = container
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // In-memory stores cannot pin a query generation. Keep their whole
            // multi-fetch read coherent with admitted local writers instead.
            if let memoryRequest { try await acquireWriter(memoryRequest, cancellation: cancellation) }
            defer { if memoryRequest != nil { releaseWriter() } }
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
        } onCancel: {
            cancellation.cancel()
            if let memoryRequest { Task { await self.cancelWriter(memoryRequest) } }
        }
    }

    /// FIFO among admitted local writers; native save is the cancellation boundary.
    func transaction<Value: Sendable>(control: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        guard control || dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        try admit(write: true)
        defer { finish(write: true) }
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
        try admit(write: true)
        defer { finish(write: true) }
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

    private func admit(write: Bool = false, reservation: UUID? = nil) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        try Task.checkCancellation()
        if let reservation {
            guard reservations[reservation] == .all else { throw StoreRuntimeError.resourceReserved }
        } else {
            guard !reservations.values.contains(.all) else { throw StoreRuntimeError.resourceReserved }
            if write, !reservations.isEmpty { throw StoreRuntimeError.writesSuspended }
        }
        admitted += 1
        if write { admittedWriters += 1 }
    }

    private func finish(write: Bool = false) {
        admitted -= 1
        if write { admittedWriters -= 1 }
        if admitted == 0 { drain?.resume(); drain = nil }
        for id in Array(reservationWaiters.keys) where reservationDrained(id) {
            reservationWaiters.removeValue(forKey: id)?.resume()
        }
    }

    func reserve(_ id: UUID, mode: StoreReservationMode) async throws {
        try Task.checkCancellation()
        guard !closing else { throw StoreRuntimeError.closedHandle }
        if mode == .all, reservations.values.contains(.all) { throw StoreRuntimeError.resourceReserved }
        reservations[id] = mode
        hooks.didRestrictWrites?()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) }
                    else if reservationDrained(id) { c.resume() }
                    else { reservationWaiters[id] = c }
                }
                try Task.checkCancellation()
                guard !closing else { throw StoreRuntimeError.closedHandle }
            } onCancel: { Task { await self.cancelReservation(id) } }
        } catch { releaseReservation(id); throw error }
    }
    private func reservationDrained(_ id: UUID) -> Bool {
        reservations[id] == .all ? admitted == 0 : admittedWriters == 0
    }
    private func cancelReservation(_ id: UUID) {
        releaseReservation(id)
    }
    func releaseReservation(_ id: UUID) {
        let mode = reservations.removeValue(forKey: id)
        reservationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if mode == .all { invalidations.publish(.storeChange) }
    }

    /// Native detachment precedes deletion; gateway claims are released only after owned cleanup.
    func discardWorkspace(_ body: @escaping @Sendable () throws -> Void) async throws {
        guard resolved.configuration.workspaceID != nil else { throw StoreRuntimeError.invalidConfiguration("Only a workspace can use detached workspace cleanup.") }
        closing = true; invalidations.finish()
        if admitted > 0 { await withCheckedContinuation { drain = $0 } }
        do { try await detach(releasing: false) }
        catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
        try body()
        for gateway in gateways { gateway.release() }
    }

    /// Only a workspace's drained exclusive reservation admits this control save.
    func workspaceTransaction<Value: Sendable>(reservation: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard resolved.configuration.workspaceID != nil, dataAvailable,
              reservations[reservation] == .all, admitted == 0 else { throw StoreRuntimeError.resourceReserved }
        try admit(write: true, reservation: reservation)
        defer { finish(write: true) }
        let cancellation = OperationCancellation(), container = container, configuration = resolved.configuration, hooks = hooks
        return try await withTaskCancellationHandler {
            try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context, configuration: configuration, container: container)
                context.userInfo[StoreNativeContext.cancellationKey] = { @Sendable in try cancellation.check() } as StoreNativeContext.CancellationCheck
                defer { context.rollback(); context.reset() }
                try cancellation.check()
                let result = try body(context)
                try cancellation.check()
                if context.hasChanges { try context.save(); hooks.afterCommit?() }
                return result
            }
        } onCancel: { cancellation.cancel() }
    }

    func copyStore(to destination: URL, reservation: UUID) async throws {
        guard dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        guard let source = resolved.url, resolved.configuration.exclusiveGraphID != nil,
              resolved.configuration.cloudKitContainerIdentifier == nil, resolved.configuration.sharedStoreURL == nil,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreRuntimeError.invalidConfiguration("A backup requires an exclusive local graph and an empty destination.")
        }
        try admit(reservation: reservation)
        defer { finish() }
        let container = container
        try await container.performBackgroundTask { _ in
            let copier = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
            try copier.replacePersistentStore(at: destination, destinationOptions: nil,
                withPersistentStoreFrom: source, sourceOptions: nil, ofType: NSSQLiteStoreType)
        }
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

    func setDataAvailable(_ value: Bool, terminal: Bool = false) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        if terminal { terminalDataBlock = true; dataAvailable = false }
        guard !value || !terminalDataBlock else { throw StoreRuntimeError.dataUnavailable }
        dataAvailable = value
    }

    /// Invalidate every lease, drain admitted work, and retain claims until native destruction succeeds.
    func destroy(graphID: UUID, storeID: String) async throws {
        guard resolved.configuration.exclusiveGraphID == graphID,
              resolved.configuration.access == .readWrite,
              resolved.configuration.cloudKitContainerIdentifier == nil,
              resolved.configuration.sharedStoreURL == nil, let url = resolved.url else {
            throw StoreRuntimeError.invalidConfiguration("Only an exclusive coordinated graph can be destroyed.")
        }
        closing = true; invalidations.finish()
        if admitted > 0 { await withCheckedContinuation { drain = $0 } }
        if !destructionIssued, FileManager.default.fileExists(atPath: url.path) {
            // Temporary Core Data metadata readers must release their SQLite connections before destruction.
            try autoreleasepool {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
                guard metadata[NSStoreUUIDKey] as? String == storeID,
                      metadata[StoreNativeContext.historySyncGraphKey] as? String == graphID.uuidString else {
                    throw StoreRuntimeError.storeReplaced(url)
                }
            }
            try await hooks.beforeDetach?()
            try await hooks.beforeDestroy?()
            try autoreleasepool {
                try container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            }
            destructionIssued = true
            destructionArtifacts = try destructionURLs(url).reduce(into: [:]) { result, artifact in
                if let identity = try destructionArtifact(artifact) { result[artifact] = identity }
            }
            try await detach(releasing: false, runHook: false)
        } else {
            try await detach(releasing: false)
        }
        try await hooks.beforeDestroyedArtifactCleanup?()
        // Core Data destroys the store/content first. Remove only its explicitly owned SQLite artifacts;
        // some SDK versions retain empty SQLite/WAL/SHM placeholders after the native destruction.
        guard destructionIssued, destructionArtifacts != nil else { throw StoreRuntimeError.storeReplaced(url) }
        // A path that was absent, replaced, modified or already cleaned is never adopted by a retry.
        for artifact in destructionURLs(url) {
            if let current = try destructionArtifact(artifact), destructionArtifacts?[artifact] != current {
                throw StoreRuntimeError.storeReplaced(artifact)
            }
        }
        for artifact in destructionURLs(url) {
            do {
                if FileManager.default.fileExists(atPath: artifact.path) { try FileManager.default.removeItem(at: artifact) }
            } catch let error as CocoaError where error.code == .fileNoSuchFile { }
            destructionArtifacts?.removeValue(forKey: artifact)
        }
        try await hooks.didDestroy?()
        for gateway in gateways { gateway.release() }
    }

    private func destructionURLs(_ url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
    }
    private func destructionArtifact(_ url: URL) throws -> DestructionArtifact? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw StoreRuntimeError.storeReplaced(url) }
        return DestructionArtifact(identity: FileIdentity(device: device.uint64Value, inode: inode.uint64Value),
                                   size: size.uint64Value, modified: modified)
    }

    private func detach(releasing: Bool = true, runHook: Bool = true) async throws {
        if runHook { try await hooks.beforeDetach?() }
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        legacyMirroring?.stop()
        legacyMirroring = nil
        for observer in changeObservers { NotificationCenter.default.removeObserver(observer) }
        changeObservers.removeAll()
        invalidations.finish()
        if releasing { for gateway in gateways { gateway.release() } }
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
