import CoreData
import Foundation
import os

/// Test seams for native lifecycle boundaries, never exposed by the Graph API.
struct StoreLifecycleHooks: Sendable {
    var processRole: StoreProcessRole?
    var beforeLoad: (@Sendable () async throws -> Void)?
    var didReserveHandle: (@Sendable () async -> Void)?
    var afterCommit: (@Sendable () -> Void)?
    var didSubmitSQLiteAccess: (@Sendable () -> Void)?
    var didQueueWriter: (@Sendable () async -> Void)?
    var didSubmitCoordinatedWrite: (@Sendable () -> Void)?
    var didRestrictWrites: (@Sendable () -> Void)?
    var didBeginClose: (@Sendable () async -> Void)?
    var beforeDetach: (@Sendable () async throws -> Void)?
    var beforeDestroy: (@Sendable () throws -> Void)?
    var beforeFailedOpenDetach: (@Sendable () throws -> Void)?
    var beforeNativePreparationDetach: (@Sendable () throws -> Void)?
    var beforeAppGroupArtifactCleanup: (@Sendable () throws -> Void)?
    var beforeDestroyedArtifactCleanup: (@Sendable () throws -> Void)?
    var didDestroy: (@Sendable () throws -> Void)?
    var didLoadStore: (@Sendable (URL?) throws -> Void)?
}

/// One container with operation-scoped private contexts. Admission covers actor reentrancy.
actor StoreResources {
    let id = UUID()
    private let gateways: [StoreGatewayLease]
    private let container: NSPersistentContainer
    private let resolved: ResolvedStore
    private let hooks: StoreLifecycleHooks
    private let coordinatesReads: Bool
    private let removeOwnedContent: (@Sendable (URL, String) throws -> Void)?
    private var appGroupPresenter: AppGroupStorePresenter?
    private let attachedIdentity: FileIdentity?
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
    private var appGroupDestructionStarted = false
    private var destructionIssued = false
    struct DestructionArtifact: Equatable, Sendable {
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

    private init(container: NSPersistentContainer, resolved: ResolvedStore, hooks: StoreLifecycleHooks, gateways: [StoreGatewayLease], appGroupPresenter: AppGroupStorePresenter? = nil, attachedIdentity: FileIdentity? = nil, coordinatesReads: Bool = false, removeOwnedContent: (@Sendable (URL, String) throws -> Void)? = nil) {
        self.coordinatesReads = coordinatesReads
        self.attachedIdentity = attachedIdentity
        self.appGroupPresenter = appGroupPresenter
        self.gateways = gateways
        self.container = container
        self.resolved = resolved
        self.hooks = hooks
        self.removeOwnedContent = removeOwnedContent
    }

    static func open(
        _ resolved: ResolvedStore,
        schema: StoreSchema,
        hooks: StoreLifecycleHooks,
        owner: UUID,
        nativeMigration: StoreNativeMigration?,
        mode: StoreOpeningMode,
        expectedIdentity: FileIdentity?
    ) async throws -> StoreResources {
        try (hooks.processRole ?? StoreProcessRole.current).validate(resolved.configuration)
        let members = try resolved.resources
        let gateways = try members.map { try StoreGatewayLease.acquire($0.configuration, owner: owner) }
        // GraphContextManager's coordinated path is the single writable v2 owner gateway.
        // Apple coordinates native metadata, attachment and mutation at the store location.
        if resolved.configuration.appGroup != nil {
            guard ["GraphEvo.v2.schema.4", "GraphEvo.v2.schema.6"].contains(schema.identifier), nativeMigration == nil, mode != .openOrCreate else {
                throw StoreRuntimeError.invalidConfiguration("App Group stores require explicit S04 or S06 creation or opening.")
            }
            try await hooks.beforeLoad?()
            return try await openCoordinated(resolved, schema: schema, hooks: hooks, gateways: gateways,
                mode: mode, expectedIdentity: expectedIdentity)
        }
        if try SQLiteStoreCoordination.participates(resolved) {
            try await hooks.beforeLoad?()
            return try await openCoordinated(resolved, schema: schema, hooks: hooks, gateways: gateways,
                mode: mode, expectedIdentity: expectedIdentity, nativeMigration: nativeMigration)
        }
        guard nativeMigration == nil else {
            throw StoreRuntimeError.invalidConfiguration("Native migration requires an isolated local SQLite workspace.")
        }
        try await hooks.beforeLoad?()
        try validateOpeningIntent(resolved, mode: mode, expectedIdentity: expectedIdentity)
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
        let resources = StoreResources(container: container, resolved: resolved, hooks: hooks, gateways: gateways, coordinatesReads: schema.coordinatesReads)
        do {
            try await resources.load()
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

    /// Registration and synchronous native open share one Apple grant.
    private static func openCoordinated(_ resolved: ResolvedStore, schema: StoreSchema,
                              hooks: StoreLifecycleHooks, gateways: [StoreGatewayLease],
                              mode: StoreOpeningMode, expectedIdentity: FileIdentity?,
                              nativeMigration: StoreNativeMigration? = nil) async throws -> StoreResources {
        guard let url = resolved.url else { throw StoreRuntimeError.resourceReserved }
        if mode == .new, resolved.configuration.appGroup != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let directory = try SQLiteStoreCoordination.directory(resolved)
        let directoryIdentity = try resolved.configuration.appGroup == nil ? SQLiteStoreCoordination.identity(directory) : nil
        let presenter = AppGroupStorePresenter(directory: directory, directoryIdentity: directoryIdentity)
        let recovery = mode.isPurgeRecovery
        let exclusive = recovery || resolved.configuration.workspaceID != nil
        let request = AppGroupStoreAccess(presenter: presenter, associatePresenter: false,
                                          options: exclusive ? .forDeleting : [], reportDenial: exclusive,
                                          onSubmit: resolved.configuration.appGroup == nil ? hooks.didSubmitSQLiteAccess : nil)
        let resources: StoreResources
        do {
            resources = try await request.run {
                let model = schema.makeModel()
                guard !schema.identifier.isEmpty, !schema.entityVersionHashes.isEmpty,
                      model.entityVersionHashesByName == schema.entityVersionHashes,
                      schema.requiredModelVersionIdentifier.map({ model.versionIdentifiers == [AnyHashable($0)] }) ?? true else {
                    throw StoreRuntimeError.invalidModel(schema.identifier)
                }
                try validateOpeningIntent(resolved, mode: mode, expectedIdentity: expectedIdentity)
                if case .appGroupPurgeRecovery(let storeID) = mode {
                    guard let graphID = resolved.configuration.exclusiveGraphID else { throw StoreRuntimeError.resourceReserved }
                    try AppGroupOwnerClaims.requireNoClaims(for: resolved)
                    try validateDestructionIdentity(url, graphID: graphID, storeID: storeID)
                }
                if let bytes = try StoreOperationJournal.readUnderGrant(resolved) {
                    struct Header: Decodable {
                        struct Graph: Decodable { let rawValue: UUID }
                        let operationID: UUID
                        let graphID: Graph
                        let storeID: String
                    }
                    let header = try JSONDecoder().decode(Header.self, from: bytes)
                    guard case .graphDeletionRecovery(let storeID, let operationID) = mode,
                          header.operationID == operationID, header.storeID == storeID,
                          header.graphID.rawValue == resolved.configuration.exclusiveGraphID else { throw StoreRuntimeError.resourceReserved }
                    try AppGroupOwnerClaims.requireNoClaims(for: resolved, allowMissing: true)
                    try validateDestructionIdentity(url, graphID: header.graphID.rawValue, storeID: storeID)
                }
                let initialDescription = try nativeMigration == nil ? storeDescription(resolved, model: model,
                    requiredModelVersionIdentifier: schema.requiredModelVersionIdentifier, nativeMirroring: false) : nil
                let creating = mode == .new || (mode == .openOrCreate && !FileManager.default.fileExists(atPath: url.path))
                if let nativeMigration, creating {
                    try AppGroupOwnerClaims.requireNoClaims(for: resolved, allowMissing: true)
                    try AppGroupOwnerClaims.checkCreationArtifacts(resolved)
                    // An interrupted seed has no attached coordinator to register.
                    do { try nativeMigration.seed(resolved) }
                    catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
                }
                try AppGroupOwnerClaims.publish(presenter.generation, for: resolved, creating: creating && nativeMigration == nil)
                presenter.register()
                var container = NSPersistentContainer(name: schema.identifier, managedObjectModel: model)
                do {
                    if let nativeMigration {
                        if let prepare = nativeMigration.prepare {
                            let source = nativeMigration.sourceSchema, sourceModel = source.makeModel()
                            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
                            if sourceModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                                let description = try storeDescription(resolved, model: sourceModel,
                                    requiredModelVersionIdentifier: source.requiredModelVersionIdentifier, nativeMirroring: false)
                                let target = container
                                container = NSPersistentContainer(name: source.identifier, managedObjectModel: sourceModel)
                                try loadSynchronous(container, description: description, hooks: hooks)
                                try prepare(container)
                                do {
                                    try hooks.beforeNativePreparationDetach?()
                                    try detachStores(container)
                                } catch {
                                    let resource = StoreResources(container: container, resolved: resolved, hooks: hooks,
                                        gateways: gateways, appGroupPresenter: presenter)
                                    throw StoreOpenQuarantine(resources: resource,
                                        failure: StoreRuntimeError.shutdownFailed(url, underlying: error))
                                }
                                container = target
                            }
                        }
                    }
                    let description = try initialDescription ?? storeDescription(resolved, model: model,
                        requiredModelVersionIdentifier: schema.requiredModelVersionIdentifier, nativeMirroring: false,
                        nativeMigration: nativeMigration)
                    try loadSynchronous(container, description: description, hooks: hooks)
                    try nativeMigration?.finish(container)
                    let identity = try resolved.fileIdentity()
                    guard identity != nil else { throw StoreRuntimeError.missingStore(url) }
                    return StoreResources(container: container, resolved: resolved, hooks: hooks,
                        gateways: gateways, appGroupPresenter: presenter, attachedIdentity: identity, coordinatesReads: schema.coordinatesReads,
                        removeOwnedContent: schema.removeOwnedContent)
                } catch let quarantine as StoreOpenQuarantine {
                    throw quarantine
                } catch {
                    let failure = StoreRuntimeError.loadFailed(url, underlying: error)
                    do {
                        try hooks.beforeFailedOpenDetach?()
                        try detachCoordinatedStores(container, presenter: presenter, resolved: resolved)
                    }
                    catch {
                        let resource = StoreResources(container: container, resolved: resolved, hooks: hooks,
                            gateways: gateways, appGroupPresenter: presenter)
                        throw StoreOpenQuarantine(resources: resource,
                            failure: StoreRuntimeError.shutdownFailed(url, underlying: error))
                    }
                    throw failure
                }
            }
        } catch is AppGroupAccessDenied {
            throw StoreRuntimeError.resourceReserved
        }
        await resources.installLoadObservers()
        return resources
    }

    private static func validateOpeningIntent(_ resolved: ResolvedStore, mode: StoreOpeningMode,
                                              expectedIdentity: FileIdentity?) throws {
        guard let url = resolved.url else { return }
        switch mode {
        case .openOrCreate:
            if let expectedIdentity, try resolved.fileIdentity() != expectedIdentity {
                throw StoreRuntimeError.storeReplaced(url)
            }
        case .existing, .appGroupPurgeRecovery, .graphDeletionRecovery:
            guard let expectedIdentity, let identity = try resolved.fileIdentity() else {
                throw StoreRuntimeError.missingStore(url)
            }
            guard identity == expectedIdentity else { throw StoreRuntimeError.storeReplaced(url) }
        case .new:
            guard expectedIdentity == nil, !FileManager.default.fileExists(atPath: url.path) else {
                throw StoreRuntimeError.storeAlreadyExists(url)
            }
        }
    }

    private static func loadSynchronous(_ container: NSPersistentContainer,
                                        description: NSPersistentStoreDescription, hooks: StoreLifecycleHooks) throws {
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        let loaded = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)
        container.loadPersistentStores { description, error in
            let url = description.url
            loaded.withLock { result in
                result = Result {
                    if let error { throw error }
                    try hooks.didLoadStore?(url)
                }
            }
        }
        guard let result = loaded.withLock({ $0 }) else { throw StoreRuntimeError.resourceReserved }
        try result.get()
        guard container.persistentStoreCoordinator.persistentStores.count == 1 else { throw StoreRuntimeError.resourceReserved }
    }

    private static func detachStores(_ container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        guard coordinator.persistentStores.isEmpty else { throw StoreRuntimeError.resourceReserved }
    }

    private static func detachCoordinatedStores(_ container: NSPersistentContainer, presenter: AppGroupStorePresenter,
                                      resolved: ResolvedStore) throws {
        try detachStores(container)
        try AppGroupOwnerClaims.remove(presenter.generation, for: resolved, anchor: presenter.coordinationDirectory)
        presenter.unregister()
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

    private func installLoadObservers() {
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
    }

    private func load() async throws {
        installLoadObservers()
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

    var usesSQLiteCoordination: Bool { appGroupPresenter != nil }

    func cloudSetup() -> StoreCloudSetup {
        let identifiers: [String] = container.persistentStoreCoordinator.persistentStores.map(\.identifier)
        return legacyMirroring?.snapshot(identifiers: identifiers) ?? StoreCloudSetup(configured: false,
            storeCount: identifiers.count, readyStoreCount: 0, latestFailureDomain: nil, latestFailureCode: nil)
    }

    /// Trusted adapter boundary: bodies return values and must never save or escape contexts.
    func read<Value: Sendable>(control: Bool = false, accountControl: Bool = false, externalContent: Bool = true,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value
    ) async throws -> Value {
        let coordinate = coordinatesReads && externalContent
        if coordinate { try Self.checkProcessReentry(resolved) }
        guard control || dataAvailable else { throw StoreRuntimeError.dataUnavailable }
        let accountPermit = try accountControl ? nil : effectiveAccountAccess.permit()
        try admit(control: control)
        defer { finish() }
        let cancellation = OperationCancellation()
        let sqlite = resolved.url != nil
        let localRequest = !sqlite || (coordinate && appGroupPresenter == nil) ? UUID() : nil
        let configuration = resolved.configuration, container = container
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Memory stores and uncoordinated internal owners join the local writer gate.
            if let localRequest { try await acquireWriter(localRequest, cancellation: cancellation) }
            defer { if localRequest != nil { releaseWriter() } }
            let native: @Sendable (NSManagedObjectContext) throws -> Value = { context in
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
            if coordinate, let presenter = appGroupPresenter {
                let resolved = resolved, identity = attachedIdentity
                let held = SQLiteStoreCoordination.held.union([resolved.key])
                // An unassociated reader also excludes writes made by this same presenter.
                let request = AppGroupStoreAccess(presenter: presenter, associatePresenter: false, reading: true, onSubmit: hooks.didSubmitSQLiteAccess)
                return try await request.run {
                    try Self.validateAttachedFile(resolved, identity)
                    let context = container.newBackgroundContext()
                    return try context.performAndWait {
                        try SQLiteStoreCoordination.$held.withValue(held) { try native(context) }
                    }
                }
            }
            return try await container.performBackgroundTask(native)
        } onCancel: {
            cancellation.cancel()
            if let localRequest { Task { await self.cancelWriter(localRequest) } }
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
            let hooks = hooks, configuration = resolved.configuration, container = container
            let resolved = resolved, identity = attachedIdentity
            let held = appGroupPresenter == nil ? SQLiteStoreCoordination.held : SQLiteStoreCoordination.held.union([resolved.key])
            let native: @Sendable (NSManagedObjectContext) throws -> Value = { context in
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
            if let presenter = appGroupPresenter {
                let request = AppGroupStoreAccess(presenter: presenter,
                    onSubmit: hooks.didSubmitCoordinatedWrite ?? hooks.didSubmitSQLiteAccess)
                return try await request.run {
                    try Self.validateAttachedFile(resolved, identity)
                    let context = container.newBackgroundContext()
                    return try context.performAndWait {
                        try SQLiteStoreCoordination.$held.withValue(held) { try native(context) }
                    }
                }
            }
            return try await SQLiteStoreCoordination.$held.withValue(held) {
                try await container.performBackgroundTask(native)
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    /// File preparation stays outside native callbacks. An App Group writer
    /// revalidates the persistent history boundary under its final Apple grant.
    func preparedControlTransaction<Snapshot: Sendable, Prepared: Sendable, Value: Sendable>(
        prepare: @escaping @Sendable (NSManagedObjectContext) throws -> Snapshot,
        materialize: @escaping @Sendable (Snapshot, @escaping StoreNativeContext.CancellationCheck) async throws -> Prepared,
        discard: @escaping @Sendable (Prepared) async -> Void,
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
            let held = SQLiteStoreCoordination.held.union([resolved.key])
            let configuration = resolved.configuration, container = container, hooks = hooks
            let presenter = appGroupPresenter, resolved = resolved, identity = attachedIdentity
            return try await SQLiteStoreCoordination.$held.withValue(held) {
                let phases = PreparedContext(container.newBackgroundContext())
                let check: StoreNativeContext.CancellationCheck = { try cancellation.check(); try accountPermit.check() }
                var staged: Prepared?
                do {
                    let (snapshot, boundary) = try await phases.perform(presenter: presenter, held: held) { context in
                        Self.prepare(context, configuration: configuration, container: container)
                        context.userInfo[StoreNativeContext.cancellationKey] = check
                        context.userInfo[StoreNativeContext.mutationSessionKey] = configuration.exclusiveGraphID == nil ? nil : StoreMutationSession()
                        try check()
                        try Self.validateAttachedFile(resolved, identity)
                        let boundary = try presenter.map { _ in try Self.preparationBoundary(context, resolved: resolved) }
                        return (try prepare(context), boundary)
                    }
                    let prepared = try await materialize(snapshot, check)
                    staged = prepared
                    let value = try await phases.perform(presenter: presenter, held: held) { context in
                        try check()
                        if let boundary {
                            let verification = container.newBackgroundContext()
                            try verification.performAndWait {
                                try Self.validatePreparationBoundary(boundary, in: verification, resolved: resolved)
                            }
                        }
                        let value = try finish(context, prepared)
                        try check()
                        if context.hasChanges { try context.save(); hooks.afterCommit?() }
                        return value
                    }
                    await phases.reset()
                    return value
                } catch {
                    await phases.reset()
                    if let staged { await discard(staged) }
                    throw error
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private struct PreparationBoundary: Sendable {
        let file: FileIdentity
        let storeID: String
        let historyToken: Data?
    }

    private static func preparationBoundary(_ context: NSManagedObjectContext,
                                            resolved: ResolvedStore) throws -> PreparationBoundary {
        guard let file = try resolved.fileIdentity(),
              let coordinator = context.persistentStoreCoordinator,
              coordinator.persistentStores.count == 1, let store = coordinator.persistentStores.first,
              let storeID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String else {
            throw StoreRuntimeError.resourceReserved
        }
        return PreparationBoundary(file: file, storeID: storeID,
            historyToken: try coordinator.currentPersistentHistoryToken(fromStores: [store]).map {
                try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            })
    }

    private static func validatePreparationBoundary(_ boundary: PreparationBoundary, in context: NSManagedObjectContext,
                                                    resolved: ResolvedStore) throws {
        guard let url = resolved.url, try resolved.fileIdentity() == boundary.file,
              let coordinator = context.persistentStoreCoordinator,
              coordinator.persistentStores.count == 1, let store = coordinator.persistentStores.first,
              coordinator.metadata(for: store)[NSStoreUUIDKey] as? String == boundary.storeID,
              let fetch = NSPersistentHistoryTransaction.fetchRequest else { throw StoreRuntimeError.resourceReserved }
        if let graphID = resolved.configuration.exclusiveGraphID,
           coordinator.metadata(for: store)[StoreNativeContext.historySyncGraphKey] != nil {
            try validateDestructionIdentity(url, graphID: graphID, storeID: boundary.storeID)
        }
        let before = try boundary.historyToken.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0)
        }
        let now = coordinator.currentPersistentHistoryToken(fromStores: [store])
        guard (before == nil && now == nil) || (before?.isEqual(now) == true) else {
            throw StoreRuntimeError.resourceReserved
        }
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: before)
        request.resultType = .transactionsOnly
        request.affectedStores = [store]
        fetch.fetchLimit = 1
        request.fetchRequest = fetch
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let changes = result.result as? [NSPersistentHistoryTransaction], changes.isEmpty else {
            throw StoreRuntimeError.resourceReserved
        }
    }

    /// The context spans preparation and commit. All access to its state is
    /// confined to its Core Data queue, including cleanup after cancellation.
    /// Older Core Data SDKs do not declare the context Sendable.
    private final class PreparedContext: @unchecked Sendable {
        private let context: NSManagedObjectContext

        init(_ context: NSManagedObjectContext) {
            self.context = context
        }

        func perform<Value: Sendable>(presenter: AppGroupStorePresenter?, held: Set<StoreKey>,
                                     _ body: @escaping @Sendable (NSManagedObjectContext) throws -> Value) async throws -> Value {
            guard let presenter else { return try await context.perform { try body(self.context) } }
            return try await AppGroupStoreAccess(presenter: presenter).run {
                try self.context.performAndWait {
                    try SQLiteStoreCoordination.$held.withValue(held) { try body(self.context) }
                }
            }
        }

        func reset() async {
            // Cleanup is queued and awaited even when the initiating task is cancelled.
            await withCheckedContinuation { continuation in
                context.perform {
                    StoreNativeContext.clearMutationSession(in: self.context)
                    self.context.rollback()
                    self.context.reset()
                    continuation.resume()
                }
            }
        }
    }

    /// Privileged framework work; the completion must settle before this owner can detach.
    func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) throws -> Value
    ) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.appGroup == nil else { throw StoreRuntimeError.resourceReserved }
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true)
        defer { finish(write: true) }
        let cancellation = OperationCancellation(), request = UUID()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            let container = container, resolved = resolved, identity = attachedIdentity
            let held = SQLiteStoreCoordination.held.union([resolved.key])
            let operation: @Sendable () throws -> Value = {
                try cancellation.check(); try accountPermit.check()
                try Self.validateAttachedFile(resolved, identity)
                return try SQLiteStoreCoordination.$held.withValue(held) { try body(container) }
            }
            defer { invalidations.publish(.nativeOperation) }
            if let presenter = appGroupPresenter {
                return try await AppGroupStoreAccess(presenter: presenter).run(operation)
            }
            return try operation()
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriter(request) }
        }
    }

    private static func validateAttachedFile(_ resolved: ResolvedStore, _ identity: FileIdentity?) throws {
        if let identity, let url = resolved.url, try resolved.fileIdentity() != identity {
            throw StoreRuntimeError.storeReplaced(url)
        }
    }

    func nativeOperation<Value: Sendable>(
        _ body: @escaping @Sendable (NSPersistentContainer) async throws -> Value
    ) async throws -> Value {
        try Self.checkProcessReentry(resolved)
        guard appGroupPresenter == nil else { throw StoreRuntimeError.resourceReserved }
        guard resolved.configuration.access == .readWrite else { throw StoreRuntimeError.readOnlyStore }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true)
        defer { finish(write: true) }
        let request = UUID(), cancellation = OperationCancellation()
        return try await withTaskCancellationHandler {
            try await acquireWriter(request, cancellation: cancellation)
            defer { releaseWriter() }
            try cancellation.check(); try accountPermit.check()
            // Native APIs own their cancellation semantics once started. Await their real outcome.
            defer { invalidations.publish(.nativeOperation) }
            let held = appGroupPresenter == nil ? SQLiteStoreCoordination.held : SQLiteStoreCoordination.held.union([resolved.key])
            return try await SQLiteStoreCoordination.$held.withValue(held) {
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
        guard !SQLiteStoreCoordination.held.contains(resolved.key) else {
            throw StoreRuntimeError.invalidConfiguration("A native operation cannot reenter its owned store while holding writer admission.")
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
        if mode == .all, resolved.configuration.appGroup != nil { throw StoreRuntimeError.resourceReserved }
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
        if mode == .all {
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
        guard let presenter = appGroupPresenter else { throw StoreRuntimeError.resourceReserved }
        try await hooks.beforeDetach?()
        let container = container, resolved = resolved
        do {
            try await AppGroupStoreAccess(presenter: presenter, cancellable: false,
                                           options: .forDeleting, reportDenial: true).run {
                try AppGroupOwnerClaims.requireSoleClaim(presenter.generation, for: resolved)
                do { try Self.detachStores(container) }
                catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
                try body()
                try AppGroupOwnerClaims.remove(presenter.generation, for: resolved, anchor: presenter.coordinationDirectory)
                presenter.unregister()
            }
        } catch is AppGroupAccessDenied { throw StoreRuntimeError.resourceReserved }
        appGroupPresenter = nil
        finishDetached(releasing: true)
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
        guard resolved.configuration.appGroup == nil else { throw StoreRuntimeError.resourceReserved }
        guard dataAvailable, reservations[reservation] == .all, admitted == 0 else { throw StoreRuntimeError.resourceReserved }
        let accountPermit = try effectiveAccountAccess.permit()
        try admit(write: true, reservation: reservation)
        defer { finish(write: true) }
        let cancellation = OperationCancellation(), container = container, configuration = resolved.configuration, hooks = hooks
        let resolved = resolved, identity = attachedIdentity
        return try await withTaskCancellationHandler {
            try await container.performBackgroundTask { @Sendable context in
                try Self.validateAttachedFile(resolved, identity)
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

    func copyStore<Value: Sendable>(to destination: URL, reservation: UUID,
        alongside: @escaping @Sendable (NSManagedObjectContext, URL, CoordinatedFiles.CancellationCheck) throws -> Value
    ) async throws -> Value {
        guard resolved.configuration.appGroup == nil else { throw StoreRuntimeError.resourceReserved }
        try AppGroupStoreLocation.rejectUncoordinated(destination)
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
        let destinationResource = try ResolvedStore(.init(location: .sqlite(destination)))
        guard destinationResource.key != resolved.key else { throw StoreRuntimeError.configurationConflict(destination) }
        if resolved.configuration.legacyReadOnly, let target = destinationResource.url {
            // The v1 caller has already stopped the source writers. Coordinate
            // the native snapshot and its private destination together.
            let container = container
            let value = try await CoordinatedFiles.run([.read(source), .write(target)]) { check in
                try accountPermit.check()
                let files = FileManager.default
                guard !files.fileExists(atPath: target.path),
                      (try? files.destinationOfSymbolicLink(atPath: target.path)) == nil else {
                    throw StoreRuntimeError.configurationConflict(target)
                }
                let copier = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
                try copier.replacePersistentStore(at: target, destinationOptions: nil,
                    withPersistentStoreFrom: source, sourceOptions: [NSReadOnlyPersistentStoreOption: true],
                    ofType: NSSQLiteStoreType)
                let context = container.newBackgroundContext()
                return try context.performAndWait { try alongside(context, target, check) }
            }
            try accountPermit.check()
            return value
        }
        guard let target = destinationResource.url else { throw StoreRuntimeError.resourceReserved }
        let destinationAnchor = try SQLiteStoreCoordination.directory(destinationResource)
        let destinationAnchorIdentity = try SQLiteStoreCoordination.identity(destinationAnchor)
        let sourceAnchorIdentity = appGroupPresenter?.directoryIdentity
        let sourceAccess: CoordinatedFiles.Access = if let presenter = appGroupPresenter {
            .read(presenter.coordinationDirectory)
        } else { .read(source) }
        let container = container, readOnly = resolved.configuration.access == .readOnly
        let sourceIdentity = try attachedIdentity ?? resolved.fileIdentity(), resolved = resolved
        let value: Value
        do {
            value = try await CoordinatedFiles.run([sourceAccess, .delete(destinationAnchor)], presenter: appGroupPresenter) { check in
                try accountPermit.check()
                try check()
                guard try SQLiteStoreCoordination.identity(destinationAnchor) == destinationAnchorIdentity else {
                    throw StoreRuntimeError.storeReplaced(target)
                }
                if let sourceAnchorIdentity, try SQLiteStoreCoordination.identity(sourceAccess.url) != sourceAnchorIdentity {
                    throw StoreRuntimeError.storeReplaced(source)
                }
                guard let sourceIdentity, try resolved.fileIdentity() == sourceIdentity else {
                    throw StoreRuntimeError.storeReplaced(source)
                }
                try AppGroupOwnerClaims.requireNoClaims(for: destinationResource, allowMissing: true)
                guard try destinationResource.fileIdentity() == nil,
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else {
                    throw StoreRuntimeError.configurationConflict(target)
                }
                let copier = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
                try copier.replacePersistentStore(at: target, destinationOptions: nil,
                    withPersistentStoreFrom: source, sourceOptions: readOnly ? [NSReadOnlyPersistentStoreOption: true] : nil,
                    ofType: NSSQLiteStoreType)
                let context = container.newBackgroundContext()
                return try context.performAndWait { try alongside(context, target, check) }
            }
        } catch is CoordinatedFiles.Denied { throw StoreRuntimeError.resourceReserved }
        try accountPermit.check()
        return value
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
        do {
            if appGroupPresenter != nil { try await detachCoordinatedOwner() }
            else { try await detach() }
        } catch { throw StoreRuntimeError.shutdownFailed(resolved.url, underlying: error) }
    }

    /// A normal Apple grant detaches this owner without deleting data.
    private func detachCoordinatedOwner() async throws {
        guard let presenter = appGroupPresenter else { throw StoreRuntimeError.resourceReserved }
        try await hooks.beforeDetach?()
        let container = container, resolved = resolved
        try await AppGroupStoreAccess(presenter: presenter, cancellable: false).run {
            try Self.detachCoordinatedStores(container, presenter: presenter, resolved: resolved)
        }
        appGroupPresenter = nil
        finishDetached(releasing: true)
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

    /// Invalidate every lease and drain admitted work. Release claims only after
    /// destruction succeeds or a pre-destruction refusal has safely detached.
    func destroy(graphID: UUID, storeID: String, operationID: UUID? = nil) async throws -> StoreDestructionOutcome {
        try await destroyCoordinated(graphID: graphID, storeID: storeID, operationID: operationID)
    }

    /// One Apple deletion grant covers identity, native destruction and cleanup.
    private func destroyCoordinated(graphID: UUID, storeID: String, operationID: UUID?) async throws -> StoreDestructionOutcome {
        try Self.checkProcessReentry(resolved)
        guard resolved.configuration.exclusiveGraphID == graphID, resolved.configuration.access == .readWrite,
              let url = resolved.url, let presenter = appGroupPresenter else {
            throw StoreRuntimeError.invalidConfiguration("Only a dedicated App Group graph can use coordinated destruction.")
        }
        closing = true; invalidations.finish()
        if admitted > 0 { await withCheckedContinuation { drain = $0 } }
        accountAccess.finish(); cancelAccountParent?(); cancelAccountParent = nil
        if !destructionIssued {
            try await hooks.beforeDetach?()
        }
        struct Progress: Sendable {
            var started: Bool
            var issued: Bool
            var artifacts: [URL: DestructionArtifact]?
        }
        let progress = OSAllocatedUnfairLock(initialState: Progress(
            started: appGroupDestructionStarted, issued: destructionIssued, artifacts: destructionArtifacts))
        let container = container, resolved = resolved, hooks = hooks, removeOwnedContent = removeOwnedContent
        let request = AppGroupStoreAccess(presenter: presenter, cancellable: false,
                                          options: .forDeleting, reportDenial: true)
        do {
            try await request.run {
                // A granted request has passed the live presenters. Any other
                // registration still on disk is unresolved recovery evidence.
                try AppGroupOwnerClaims.requireSoleClaim(presenter.generation, for: resolved)
                if !progress.withLock({ $0.issued }) {
                    try Self.validateDestructionIdentity(url, graphID: graphID, storeID: storeID)
                    if let operationID {
                        if let prior = try StoreDestructionReceipt.read(url, graphID: graphID) {
                            guard prior.operationID == operationID, prior.storeID == storeID else { throw StoreRuntimeError.resourceReserved }
                        }
                        try StoreDestructionReceipt(format: 1, operationID: operationID, graphID: graphID, storeID: storeID,
                            generation: presenter.generation, anchorName: try StoreDestructionReceipt.relativeAnchor(presenter.coordinationDirectory, storeURL: url), nativeDestroyed: false, artifacts: try StoreDestructionReceipt.capture(url))
                            .persist(url)
                    }
                    let coordinator = container.persistentStoreCoordinator
                    if !progress.withLock({ $0.started }) {
                        if resolved.configuration.appGroup == nil {
                            try AppGroupOwnerClaims.markRetiring(presenter.generation, for: resolved)
                        }
                        progress.withLock { $0.started = true }
                    }
                    try hooks.beforeDestroy?()
                    // Remove schema-owned bodies first: a crash after native destruction
                    // must not leave bytes whose ownership can no longer be verified.
                    try removeOwnedContent?(url, storeID)
                    try autoreleasepool {
                        try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
                    }
                    progress.withLock { $0.issued = true }
                    for store in coordinator.persistentStores { try coordinator.remove(store) }
                    guard coordinator.persistentStores.isEmpty else { throw StoreRuntimeError.resourceReserved }
                    let artifacts = try Self.destructionURLs(url).reduce(into: [URL: DestructionArtifact]()) { result, item in
                        if let value = try Self.destructionArtifact(item) { result[item] = value }
                    }
                    progress.withLock { $0.artifacts = artifacts }
                    if let operationID {
                        try StoreDestructionReceipt(format: 1, operationID: operationID, graphID: graphID, storeID: storeID,
                            generation: presenter.generation, anchorName: try StoreDestructionReceipt.relativeAnchor(presenter.coordinationDirectory, storeURL: url), nativeDestroyed: true, artifacts: try StoreDestructionReceipt.capture(url))
                            .persist(url)
                    }
                }
                guard let artifacts = progress.withLock({ $0.artifacts }) else {
                    throw StoreRuntimeError.storeReplaced(url)
                }
                try hooks.beforeAppGroupArtifactCleanup?()
                try hooks.beforeDestroyedArtifactCleanup?()
                let items = Self.destructionURLs(url)
                let existing = try items.filter { item in
                    guard let current = try Self.destructionArtifact(item) else {
                        if resolved.configuration.appGroup != nil, artifacts[item] != nil {
                            throw StoreRuntimeError.storeReplaced(item)
                        }
                        return false
                    }
                    guard current == artifacts[item] else { throw StoreRuntimeError.storeReplaced(item) }
                    return true
                }
                for item in existing {
                    try FileManager.default.removeItem(at: item)
                    progress.withLock { _ = $0.artifacts?.removeValue(forKey: item) }
                }
                try hooks.didDestroy?()
                try AppGroupOwnerClaims.remove(presenter.generation, for: resolved, anchor: presenter.coordinationDirectory)
                presenter.unregister()
            }
        } catch {
            let phase = progress.withLock { $0 }
            appGroupDestructionStarted = phase.started
            destructionIssued = phase.issued
            destructionArtifacts = phase.artifacts
            if !phase.started {
                switch error {
                case is AppGroupAccessDenied, StoreRuntimeError.resourceReserved:
                    do { try await detachCoordinatedOwner() }
                    catch { throw StoreRuntimeError.shutdownFailed(url, underlying: error) }
                    return .deferredAfterDetach
                default: break
                }
            }
            if let denied = error as? AppGroupAccessDenied { throw denied.underlying }
            throw error
        }
        appGroupPresenter = nil
        finishDetached(releasing: true)
        return .removed
    }

    static func destructionStoreID(_ url: URL, graphID: UUID) throws -> String {
        // Release temporary Core Data metadata readers before native destruction.
        try autoreleasepool {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw StoreRuntimeError.missingStore(url)
            }
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
            guard let storeID = metadata[NSStoreUUIDKey] as? String,
                  metadata[StoreNativeContext.historySyncGraphKey] as? String == graphID.uuidString else {
                throw StoreRuntimeError.storeReplaced(url)
            }
            return storeID
        }
    }

    static func validateDestructionIdentity(_ url: URL, graphID: UUID, storeID: String) throws {
        guard try destructionStoreID(url, graphID: graphID) == storeID else {
            throw StoreRuntimeError.storeReplaced(url)
        }
    }

    static func destructionURLs(_ url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
    }
    static func destructionArtifact(_ url: URL) throws -> DestructionArtifact? {
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
        finishDetached(releasing: releasing)
    }

    private func finishDetached(releasing: Bool) {
        legacyMirroring?.stop()
        legacyMirroring = nil
        for observer in changeObservers { NotificationCenter.default.removeObserver(observer) }
        changeObservers.removeAll()
        invalidations.finish()
        if releasing {
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
