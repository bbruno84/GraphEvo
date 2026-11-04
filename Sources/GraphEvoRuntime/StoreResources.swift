import CoreData
import Foundation
import os

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var processRole: StoreProcessRole?
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var afterCommit: (@Sendable () -> Void)?
    var didContendProcessLock: (@Sendable () -> Void)?
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
    private var maintenanceWriter: StoreProcessLock.Lease?
    private var processPresence: StoreProcessLock.Lease?
    private var legacyMirroring: LegacyStoreMirroring?
    private var changeObservers: [NSObjectProtocol] = []
    nonisolated let invalidations = StoreInvalidationHub()
    nonisolated let accountAccess = StoreAccountAccess()
    private var accountParent: StoreAccountControl?
    private var cancelAccountParent: (@Sendable () -> Void)?
    var effectiveAccountAccess: StoreAccountAccess { accountParent?.access ?? accountAccess }

    func inheritAccount(_ parent: StoreAccountControl) throws {
        guard !closing, accountParent == nil else { throw StoreRuntimeError.closedHandle }
        _ = try parent.access.permit()
        accountParent = parent
        let hub = invalidations
        cancelAccountParent = parent.access.onIsolation { [weak hub] in hub?.isolateAccount() }
    }
    private var writerBusy = false
    private var writers: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var closing = false
    private var dataAvailable = true
    private var activationRestriction: (id: UUID, reads: Bool)?
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

    private init(container: NSPersistentContainer, resolved: ResolvedStore, hooks: StoreLifecycleHooks, gateways: [StoreGatewayLease], processPresence: StoreProcessLock.Lease? = nil) {
        self.processPresence = processPresence
        self.gateways = gateways
        self.container = container
        self.resolved = resolved
        self.hooks = hooks
    }

    static func open(
        _ resolved: ResolvedStore,
        schema: StoreSchema,
        hooks: StoreLifecycleHooks,
        owner: UUID,
        nativeMigration: StoreNativeMigration? = nil
    ) async throws -> StoreResources {
        try (hooks.processRole ?? StoreProcessRole.current).validate(resolved.configuration)
        let members = try resolved.resources
        let gateways = try members.map { try StoreGatewayLease.acquire($0.configuration, owner: owner) }
        // GraphContextManager's coordinated path is the single writable v2 owner gateway.
        // Bootstrap holds the writer lock before native metadata/load. Presence prevents
        // replacement of a live coordinator; workspaces retain an exclusive claim.
        let processWriter = try await acquireProcessWriter(resolved, hooks: hooks)
        defer { processWriter?.release() }
        let presence: StoreProcessLock.Lease?
        if processWriter != nil {
            presence = try await StoreProcessLock.acquire(resolved, purpose: "owners",
                mode: resolved.configuration.workspaceID == nil ? .shared : .exclusive, wait: false)
        } else { presence = nil }
        try await hooks.beforeLoad?()
        let model = schema.makeModel()
        guard !schema.identifier.isEmpty, !schema.entityVersionHashes.isEmpty,
              model.entityVersionHashesByName == schema.entityVersionHashes,
              schema.requiredModelVersionIdentifier.map({ model.versionIdentifiers == [AnyHashable($0)] }) ?? true else {
            throw StoreRuntimeError.invalidModel(schema.identifier)
        }
        if let nativeMigration {
            try nativeMigration.seed(resolved)
            try await prepareNativeMigration(nativeMigration, resolved: resolved, hooks: hooks, gateways: gateways, presence: presence)
        }
        let descriptions = try members.map { member in
            try storeDescription(member, model: model, requiredModelVersionIdentifier: schema.requiredModelVersionIdentifier,
                                 nativeMirroring: resolved.configuration.cloudKitContainerIdentifier != nil,
                                 nativeMigration: nativeMigration)
        }
        let container: NSPersistentContainer
        if resolved.configuration.cloudKitContainerIdentifier != nil {
            container = try LegacyStoreMirroring.makeContainer(name: schema.identifier, model: model,
                descriptions: descriptions, configuration: resolved.configuration)
        } else { container = NSPersistentContainer(name: schema.identifier, managedObjectModel: model) }
        container.persistentStoreDescriptions = descriptions
        let resources = StoreResources(container: container, resolved: resolved, hooks: hooks, gateways: gateways, processPresence: presence)
        do {
            try await resources.load()
            if let nativeMigration { try await resources.finishNativeMigration(nativeMigration) }
        }
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
                                         requiredModelVersionIdentifier: String?, nativeMirroring: Bool,
                                         nativeMigration: StoreNativeMigration? = nil) throws -> NSPersistentStoreDescription {
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
                if metadata[StoreNativeContext.historySyncGraphKey] != nil, resolved.configuration.access == .readWrite {
                    guard resolved.configuration.exclusiveGraphID != nil else {
                        throw StoreRuntimeError.invalidConfiguration("A coordinated graph requires its exclusive manager entry point for writing.")
                    }
                }
                if nativeMirroring && metadata[StoreNativeContext.historySyncGraphKey] != nil {
                    throw StoreRuntimeError.invalidConfiguration("A history-sync store cannot be opened by native CloudKit mirroring.")
                }
                let targetMatches = model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) &&
                    (requiredModelVersionIdentifier.map({ metadata[NSStoreModelVersionIdentifiersKey] as? [String] == [$0] }) ?? true)
                let sourceMatches = nativeMigration.map {
                    metadata[StoreNativeMigration.documentKey] is Data &&
                    $0.sourceSchema.makeModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
                } ?? false
                guard targetMatches || sourceMatches else {
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
            if !resolved.configuration.legacyReadOnly {
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        case .inMemory:
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        }
        description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        if let nativeMigration { try nativeMigration.configure(description, model) }
        return description
    }

    private func finishNativeMigration(_ migration: StoreNativeMigration) throws {
        try migration.finish(container)
    }

    private func performNativePreparation(_ body: @Sendable (NSPersistentContainer) throws -> Void) throws {
        try body(container)
    }

    private static func prepareNativeMigration(_ migration: StoreNativeMigration, resolved: ResolvedStore,
                                              hooks: StoreLifecycleHooks, gateways: [StoreGatewayLease], presence: StoreProcessLock.Lease?) async throws {
        guard let prepare = migration.prepare, let url = resolved.url else { return }
        let model = migration.sourceSchema.makeModel()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        if !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }
        let description = try storeDescription(resolved, model: model,
            requiredModelVersionIdentifier: migration.sourceSchema.requiredModelVersionIdentifier, nativeMirroring: false)
        let container = NSPersistentContainer(name: migration.sourceSchema.identifier, managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        let staging = StoreResources(container: container, resolved: resolved, hooks: hooks, gateways: gateways, processPresence: presence)
        do {
            try await staging.load()
            try await staging.performNativePreparation(prepare)
        } catch {
            let failure = StoreRuntimeError.loadFailed(url, underlying: error)
            do { try await staging.detach(releasing: false) }
            catch { throw StoreOpenQuarantine(resources: staging, failure: StoreRuntimeError.shutdownFailed(url, underlying: error)) }
            throw failure
        }
        do { try await staging.detach(releasing: false) }
        catch { throw StoreOpenQuarantine(resources: staging, failure: StoreRuntimeError.shutdownFailed(url, underlying: error)) }
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
    func read<Value: Sendable>(control: Bool = false, accountControl: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        guard control || dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        let accountPermit = try accountControl ? nil : effectiveAccountAccess.permit()
        try admit(control: control)
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
                let check: StoreNativeContext.CancellationCheck = { try cancellation.check(); try accountPermit?.check() }
                context.userInfo[StoreNativeContext.cancellationKey] = check
                defer { context.rollback(); context.reset() }
                try check()
                if sqlite && !configuration.legacyReadOnly { try context.setQueryGenerationFrom(.current) }
                let value = try body(context)
                guard !context.hasChanges else { throw StoreRuntimeError.mutationInReadScope }
                try check()
                return value
            }
        } onCancel: {
            cancellation.cancel()
            if let memoryRequest { Task { await self.cancelWriter(memoryRequest) } }
        }
    }

    /// FIFO among admitted local writers; native save is the cancellation boundary.
    func transaction<Value: Sendable>(control: Bool = false, accountControl: Bool = false,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        guard control || dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        let accountPermit = try accountControl ? nil : effectiveAccountAccess.permit()
        try admit(write: true, control: control)
        defer { finish(write: true) }
        let cancellation = OperationCancellation()
        let request = UUID()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            let processWriter = try await acquireOwnedWriter()
            defer { processWriter?.release() }
            let hooks = hooks, configuration = resolved.configuration, container = container
            let held = processWriter == nil ? StoreProcessLock.held : StoreProcessLock.held.union([resolved.key])
            return try await StoreProcessLock.$held.withValue(held) {
                try await container.performBackgroundTask { @Sendable context in
                    Self.prepare(context, configuration: configuration, container: container)
                    context.userInfo[StoreNativeContext.mutationSessionKey] = configuration.exclusiveGraphID == nil ? nil : StoreMutationSession()
                    let check: StoreNativeContext.CancellationCheck = { try cancellation.check(); try accountPermit?.check() }
                    context.userInfo[StoreNativeContext.cancellationKey] = check
                    defer {
                        StoreNativeContext.clearMutationSession(in: context)
                        context.rollback(); context.reset()
                    }
                    try check()
                    let value = try body(context)
                    try check()
                    if context.hasChanges { try context.save() }
                    // A completed save is success even if cancellation arrives during save.
                    hooks.afterCommit?()
                    return value
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    /// File preparation stays outside native callbacks while the same admitted writer owns
    /// its pending context. Only Sendable values cross phases; consumers never receive this API.
    func preparedControlTransaction<Snapshot: Sendable, Prepared: Sendable, Value: Sendable>(
        prepare: @escaping @Sendable (NSManagedObjectContext) throws -> Snapshot,
        materialize: @escaping @Sendable (Snapshot, StoreNativeContext.CancellationCheck) async throws -> Prepared,
        finish: @escaping @Sendable (NSManagedObjectContext, Prepared) throws -> Value
    ) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        guard resolved.url != nil, !resolved.configuration.legacyReadOnly,
              resolved.configuration.cloudKitContainerIdentifier == nil, resolved.configuration.sharedStoreURL == nil else {
            throw StoreRuntimeError.invalidConfiguration("File preparation requires a plain writable SQLite store.")
        }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true, control: true)
        defer { self.finish(write: true) }
        let cancellation = OperationCancellation(), request = UUID()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            let processWriter = try await acquireOwnedWriter()
            defer { processWriter?.release() }
            let held = StoreProcessLock.held.union([resolved.key])
            let configuration = resolved.configuration, container = container, hooks = hooks
            return try await StoreProcessLock.$held.withValue(held) {
                let context = container.newBackgroundContext()
                let check: StoreNativeContext.CancellationCheck = { try cancellation.check(); try accountPermit.check() }
                do {
                    let snapshot = try await context.perform {
                        Self.prepare(context, configuration: configuration, container: container)
                        context.userInfo[StoreNativeContext.cancellationKey] = check
                        context.userInfo[StoreNativeContext.mutationSessionKey] = configuration.exclusiveGraphID == nil ? nil : StoreMutationSession()
                        try check()
                        return try prepare(context)
                    }
                    let prepared = try await materialize(snapshot, check)
                    let value = try await context.perform {
                        try check()
                        let value = try finish(context, prepared)
                        try check()
                        if context.hasChanges { try context.save(); hooks.afterCommit?() }
                        return value
                    }
                    await Self.resetPreparedContext(context)
                    return value
                } catch {
                    await Self.resetPreparedContext(context)
                    throw error
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private static func resetPreparedContext(_ context: NSManagedObjectContext) async {
        // Cleanup is queued and awaited even when the initiating task is cancelled.
        await withCheckedContinuation { continuation in
            context.perform {
                StoreNativeContext.clearMutationSession(in: context)
                context.rollback(); context.reset()
                continuation.resume()
            }
        }
    }

    /// Privileged framework work; the completion must settle before this owner can detach.
    func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true)
        defer { finish(write: true) }
        let request = UUID(), cancellation = OperationCancellation()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            let processWriter = try await acquireOwnedWriter()
            defer { processWriter?.release() }
            try cancellation.check(); try accountPermit.check()
            // Native APIs own their cancellation semantics once started. Await their real outcome.
            defer { invalidations.publish(.nativeOperation) }
            let held = processWriter == nil ? StoreProcessLock.held : StoreProcessLock.held.union([resolved.key])
            return try await StoreProcessLock.$held.withValue(held) {
                let result = try await body(container)
                try accountPermit.check()
                return result
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private static func checkProcessReentry(_ resolved: ResolvedStore) throws {
        guard !StoreProcessLock.held.contains(resolved.key) else {
            throw StoreRuntimeError.invalidConfiguration("A native operation cannot reenter its owned store while holding writer admission.")
        }
    }

    private static func acquireProcessWriter(_ resolved: ResolvedStore, hooks: StoreLifecycleHooks,
                                             cancellable: Bool = true) async throws -> StoreProcessLock.Lease? {
        try checkProcessReentry(resolved)
        guard let url = resolved.url, !resolved.configuration.legacyReadOnly,
              resolved.configuration.cloudKitContainerIdentifier == nil,
              resolved.configuration.sharedStoreURL == nil else { return nil }
        do {
            if resolved.configuration.access == .readOnly {
                guard FileManager.default.fileExists(atPath: url.path) else { throw StoreRuntimeError.missingStore(url) }
                // Preserve read-only unmarked/archive sources without requiring a writable
                // directory. Coordinated replicas participate in the live-owner protocol.
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                    at: url, options: [NSReadOnlyPersistentStoreOption: true])
                guard metadata[StoreNativeContext.historySyncGraphKey] != nil else { return nil }
            }
            return try await StoreProcessLock.acquire(resolved, cancellable: cancellable,
                                                       contended: hooks.didContendProcessLock)
        } catch is CancellationError { throw CancellationError() }
        catch let error as StoreRuntimeError { throw error }
        catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
    }

    private func acquireOwnedWriter(cancellable: Bool = true) async throws -> StoreProcessLock.Lease? {
        try Self.checkProcessReentry(resolved)
        if let borrowed = maintenanceWriter?.retained() { return borrowed }
        return try await Self.acquireProcessWriter(resolved, hooks: hooks, cancellable: cancellable)
    }

    /// Called under the process writer lock. Never destroy a store with another live coordinator.
    /// Failure restores our presence mode, retaining ownership for a safe later close/retry.
    private func requireSoleProcessOwner() async throws {
        guard processPresence != nil else { return }
        processPresence?.release(); processPresence = nil
        do {
            processPresence = try await StoreProcessLock.acquire(resolved, purpose: "owners", wait: false, cancellable: false)
        } catch {
            processPresence = try await StoreProcessLock.acquire(resolved, purpose: "owners",
                mode: resolved.configuration.workspaceID == nil ? .shared : .exclusive, cancellable: false)
            throw error
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

    private func admit(write: Bool = false, reservation: UUID? = nil, control: Bool = false) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        try Task.checkCancellation()
        if !control, let restriction = activationRestriction {
            if write { throw StoreRuntimeError.writesSuspended }
            if restriction.reads { throw StoreRuntimeError.dataUnavailable }
        }
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
        try Self.checkProcessReentry(resolved)
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
                if mode == .all {
                    let lock = try await Self.acquireProcessWriter(resolved, hooks: hooks)
                    do {
                        try Task.checkCancellation()
                        guard !closing, reservations[id] == .all else { throw StoreRuntimeError.closedHandle }
                        maintenanceWriter = lock
                    } catch { lock?.release(); throw error }
                }
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
        if mode == .all {
            maintenanceWriter?.release(); maintenanceWriter = nil
            invalidations.publish(.storeChange)
        }
    }

    /// Independent of sharing availability and caller-owned maintenance reservations.
    func restrictActivation(_ id: UUID, reads: Bool, release: Bool) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        guard activationRestriction == nil || activationRestriction?.id == id else { throw StoreRuntimeError.resourceReserved }
        if release {
            if activationRestriction?.id == id { activationRestriction = nil; invalidations.publish(.storeChange) }
        } else { activationRestriction = (id, reads) }
    }

    /// Native detachment precedes deletion; gateway claims are released only after owned cleanup.
    func discardWorkspace(_ body: @escaping @Sendable () throws -> Void) async throws {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.workspaceID != nil else { throw StoreRuntimeError.invalidConfiguration("Only a workspace can use detached workspace cleanup.") }
        closing = true; invalidations.finish()
        if admitted > 0 { await withCheckedContinuation { drain = $0 } }
        accountAccess.finish(); cancelAccountParent?(); cancelAccountParent = nil
        let processWriter = try await acquireOwnedWriter(cancellable: false)
        defer { processWriter?.release() }
        try await requireSoleProcessOwner()
        do { try await detach(releasing: false) }
        catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
        try body()
        processPresence?.release(); processPresence = nil
        maintenanceWriter?.release(); maintenanceWriter = nil
        for gateway in gateways { gateway.release() }
    }

    /// Workspace sealing cannot use the separate original-store publication capability.
    func workspaceTransaction<Value: Sendable>(reservation: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard resolved.configuration.workspaceID != nil else { throw StoreRuntimeError.resourceReserved }
        return try await reservedMigrationTransaction(reservation: reservation, body)
    }

    func publicationTransaction<Value: Sendable>(graphID: UUID, reservation: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        guard resolved.configuration.workspaceID == nil, resolved.configuration.exclusiveGraphID == graphID,
              resolved.configuration.cloudKitContainerIdentifier == nil, resolved.configuration.sharedStoreURL == nil else {
            throw StoreRuntimeError.resourceReserved
        }
        return try await reservedMigrationTransaction(reservation: reservation) { context in
            guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
                  let store = coordinator.persistentStores.first,
                  coordinator.metadata(for: store)[StoreNativeContext.historySyncGraphKey] as? String == graphID.uuidString,
                  coordinator.metadata(for: store)[StoreNativeContext.workspaceKey] == nil else { throw StoreRuntimeError.resourceReserved }
            return try body(context)
        }
    }

    private func reservedMigrationTransaction<Value: Sendable>(reservation: UUID,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard dataAvailable, reservations[reservation] == .all, admitted == 0 else { throw StoreRuntimeError.resourceReserved }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true, reservation: reservation)
        defer { finish(write: true) }
        let cancellation = OperationCancellation(), container = container, configuration = resolved.configuration, hooks = hooks
        return try await withTaskCancellationHandler {
            let processWriter = try await acquireOwnedWriter()
            defer { processWriter?.release() }
            return try await container.performBackgroundTask { @Sendable context in
                Self.prepare(context, configuration: configuration, container: container)
                context.userInfo[StoreNativeContext.mutationSessionKey] = configuration.exclusiveGraphID == nil ? nil : StoreMutationSession()
                context.userInfo[StoreNativeContext.cancellationKey] = { @Sendable in try cancellation.check(); try accountPermit.check() } as StoreNativeContext.CancellationCheck
                defer {
                    StoreNativeContext.clearMutationSession(in: context)
                    context.rollback(); context.reset()
                }
                try cancellation.check(); try accountPermit.check()
                let result = try body(context)
                try cancellation.check(); try accountPermit.check()
                if context.hasChanges { try context.save(); hooks.afterCommit?() }
                return result
            }
        } onCancel: { cancellation.cancel() }
    }

    func copyStore(to destination: URL, reservation: UUID) async throws {
        try Self.checkProcessReentry(resolved)
        guard dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        let accountPermit = try effectiveAccountAccess.permit()
        guard let source = resolved.url,
              (resolved.configuration.exclusiveGraphID != nil || resolved.configuration.access == .readOnly),
              resolved.configuration.cloudKitContainerIdentifier == nil, resolved.configuration.sharedStoreURL == nil,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreRuntimeError.invalidConfiguration("A backup requires an exclusive local graph or a read-only local source and an empty destination.")
        }
        try admit(reservation: reservation)
        defer { finish() }
        let sourceFence = maintenanceWriter?.retained()
        defer { sourceFence?.release() }
        let destinationResource = try ResolvedStore(.init(location: .sqlite(destination)))
        guard destinationResource.key != resolved.key else { throw StoreRuntimeError.configurationConflict(destination) }
        let lockedResources = (processPresence == nil || sourceFence != nil ? [destinationResource] : [resolved, destinationResource]).sorted {
            guard case .sqlite(let left) = $0.key, case .sqlite(let right) = $1.key else { return false }
            return left < right
        }
        var locks: [StoreProcessLock.Lease] = []
        defer { for lock in locks.reversed() { lock.release() } }
        for resource in lockedResources { locks.append(try await StoreProcessLock.acquire(resource)) }
        // An existing destination must not be replaced while another coordinator owns it.
        let destinationOwner = try await StoreProcessLock.acquire(destinationResource, purpose: "owners", wait: false)
        defer { destinationOwner.release() }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreRuntimeError.configurationConflict(destination) }
        let container = container, readOnly = resolved.configuration.access == .readOnly
        try await container.performBackgroundTask { _ in
            try accountPermit.check()
            let copier = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
            try copier.replacePersistentStore(at: destination, destinationOptions: nil,
                withPersistentStoreFrom: source, sourceOptions: readOnly ? [NSReadOnlyPersistentStoreOption: true] : nil, ofType: NSSQLiteStoreType)
        }
        try accountPermit.check()
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
        try Self.checkProcessReentry(resolved)
        closing = true
        invalidations.finish()
        await hooks.didBeginClose?()
        if admitted > 0 {
            await withCheckedContinuation { drain = $0 }
        }
        accountAccess.finish(); cancelAccountParent?(); cancelAccountParent = nil
        let processWriter = try await acquireOwnedWriter(cancellable: false)
        defer { processWriter?.release() }
        do { try await detach() }
        catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
    }

    func setAccountStatus(_ value: StoreAccountStatus, revision: UInt64) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        if accountAccess.update(value, revision: revision) { invalidations.isolateAccount() }
    }

    func setDataAvailable(_ value: Bool, terminal: Bool = false) throws {
        guard !closing else { throw StoreRuntimeError.closedHandle }
        if terminal { terminalDataBlock = true; dataAvailable = false }
        guard !value || !terminalDataBlock else { throw StoreRuntimeError.dataUnavailable }
        dataAvailable = value
    }

    /// Invalidate every lease, drain admitted work, and retain claims until native destruction succeeds.
    func destroy(graphID: UUID, storeID: String) async throws {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.exclusiveGraphID == graphID,
              resolved.configuration.access == .readWrite,
              resolved.configuration.cloudKitContainerIdentifier == nil,
              resolved.configuration.sharedStoreURL == nil, let url = resolved.url else {
            throw StoreRuntimeError.invalidConfiguration("Only an exclusive coordinated graph can be destroyed.")
        }
        closing = true; invalidations.finish()
        if admitted > 0 { await withCheckedContinuation { drain = $0 } }
        accountAccess.finish(); cancelAccountParent?(); cancelAccountParent = nil
        let processWriter = try await acquireOwnedWriter(cancellable: false)
        defer { processWriter?.release() }
        try await requireSoleProcessOwner()
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
        processPresence?.release(); processPresence = nil
        maintenanceWriter?.release(); maintenanceWriter = nil
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
        if releasing {
            processPresence?.release(); processPresence = nil
            for gateway in gateways { gateway.release() }
        }
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
