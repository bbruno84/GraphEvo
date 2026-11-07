import Foundation
import CloudKit
import GraphEvoModel
import GraphEvoRuntime

/// Application-owned entry to coordinated graphs and optional cloud transport.
@available(iOS 17, macOS 14, *)
public actor GraphContext {
    package let manager: GraphContextManager
    private let adapter: GraphCloudAdapter
    private let disk: GraphCloudDisk
    nonisolated var identityForBootstrap: UUID { identity }
    var adapterForBootstrap: GraphCloudAdapter { adapter }
    private let identity: UUID
    private var foreground = false
    private var backgrounded = false
    private struct ConnectionEntry {
        let generation = UUID()
        let configuration: GraphCloudConnectionConfiguration
        let hub: GraphCloudConnectionHub
        let reservation: Task<Void, any Error>
        var tokens: Set<UUID> = []
        var startup: Task<Void, Never>?
        var suspension: Task<Void, any Error>?
        var retry: Task<Void, Never>?
        var retryDelay = 1
        var closing: Task<Void, any Error>?
    }
    private var connections: [String: ConnectionEntry] = [:]

    package init(manager: GraphContextManager) {
        self.init(manager: manager, adapter: .live)
    }

    init(manager: GraphContextManager, adapter: GraphCloudAdapter, disk: GraphCloudDisk = .live) {
        self.manager = manager; self.adapter = adapter; self.disk = disk
        identity = manager.contextOwnerID ?? UUID()
    }

    /// Creates one new graph at an exact SQLite URL, refusing existing files.
    public func createGraph(id: GraphID, at storeURL: URL, conflictPolicy: GraphConflictPolicy = .lastEditWins) async throws -> GraphStore {
        try requireOrdinaryContext()
        try validateStoreURL(storeURL)
        await prepareMonitoring()
        return await retained(try await manager.createGraph(id: id, at: storeURL, conflictPolicy: conflictPolicy))
    }

    /// Opens the selected existing graph without creating, converting or enabling transport.
    public func openGraph(id: GraphID, at storeURL: URL) async throws -> GraphStore {
        try requireOrdinaryContext()
        try validateStoreURL(storeURL)
        await prepareMonitoring()
        return await retained(try await manager.openGraph(id: id, at: storeURL))
    }

    /// The exact store location to pass to the ordinary graph open/create entry.
    package nonisolated func appGroupStoreURL(for id: GraphID) throws -> URL {
        guard let appGroup = manager.appGroup else { throw GraphStoreError.unsupportedLayout }
        return appGroup.storeURL(for: id.rawValue)
    }

    func retained(_ graph: GraphStore) async -> GraphStore {
        await graph.retainPublicContext(self, identity: identity)
        return graph
    }
    func prepareMonitoring() async { await manager.setLocalAccountAdapter(adapter) }

    /// Reports aggregate scene activity. On iOS, the host keeps background execution
    /// available while awaiting the stop that releases the session directory lock.
    public func setForegroundActive(_ active: Bool) async throws {
        try Task.checkCancellation()
        foreground = active
        backgrounded = !active
        let keys = Array(connections.keys)
        if active {
            for key in keys { start(key) }
            await prepareMonitoring()
            for key in keys {
                guard !backgrounded else { return }
                if let entry = connections[key], entry.suspension == nil, entry.closing == nil {
                    await manager.activatePublicTransport(entry.configuration.native)
                }
            }
            if !backgrounded {
                let starting = Set(connections.compactMap { key, entry in
                    entry.startup != nil || entry.suspension != nil || entry.retry != nil ? key : nil
                })
                await manager.refreshPublicAccounts(excluding: starting)
            }
        } else {
            let stops = keys.compactMap { suspend($0) }
            var failure: (any Error)?
            for stop in stops {
                do { try await stop.value }
                catch { if failure == nil { failure = error } }
            }
            if let failure { throw GraphCloudConnectionError.translate(failure) }
        }
    }

    private func suspend(_ key: String) -> Task<Void, any Error>? {
        guard let entry = connections[key] else { return nil }
        if let closing = entry.closing { return closing }
        if let suspension = entry.suspension { return suspension }
        entry.startup?.cancel()
        entry.retry?.cancel()
        connections[key]?.retry = nil
        connections[key]?.retryDelay = 1
        switch entry.hub.current {
        case .isolated: break
        default: entry.hub.publish(.temporarilyUnavailable)
        }
        let task = Task {
            do {
                try await manager.suspendPublicTransport(entry.configuration.native)
                if connections[key]?.generation == entry.generation {
                    connections[key]?.suspension = nil
                    start(key)
                }
            } catch {
                entry.hub.publish(.failed(.init(error)))
                throw error
            }
        }
        connections[key]?.suspension = task
        return task
    }

    /// Schedules identity checks for observed accounts without starting stopped transport.
    public func refreshCloudAccounts() async throws {
        try requireOrdinaryContext()
        try Task.checkCancellation()
        await prepareMonitoring()
        await manager.refreshPublicAccounts()
    }

    /// Reserves transport and returns before account/network startup completes.
    public func connectCloud(using configuration: GraphCloudConnectionConfiguration) async throws -> GraphCloudConnection {
        let configuration = configuration.withFileSupport([GraphFileDisk.schemaIdentifier, "GraphEvo.v2.schema.7.local-files"].contains(manager.schema.identifier))
        if let group = manager.publicAppGroup {
            guard group.role == .primary else { throw GraphStoreError.permissionDenied }
            guard group.allowsCloudSynchronization else { throw GraphStoreError.unsupportedLayout }
        }
        try Task.checkCancellation()
        guard Bundle.main.bundleURL.pathExtension != "appex" else { throw GraphCloudConnectionError.unavailableInExtension }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: configuration.directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw GraphCloudConnectionError.invalidConfiguration
        }
        let key = configuration.native.namespace
        if let entry = connections[key] {
            guard entry.closing == nil else { throw GraphCloudConnectionError.closed }
            guard entry.configuration == configuration else { throw GraphCloudConnectionError.ownershipConflict }
        } else {
            let identity = identity
            let reservation = Task {
                try await GraphCloudOwnership.shared.reserve(configuration.containerIdentifier, owner: identity, directory: configuration.directory)
            }
            connections[key] = ConnectionEntry(configuration: configuration, hub: GraphCloudConnectionHub(), reservation: reservation)
        }
        let token = UUID()
        connections[key]!.tokens.insert(token)
        let entry = connections[key]!
        do {
            try await entry.reservation.value
            try Task.checkCancellation()
            await manager.installPublicConnectionHub(entry.hub, namespace: key, adapter: adapter)
            if backgrounded { _ = suspend(key) }
            else { start(key) }
            return GraphCloudConnection(context: self, namespace: key, token: token, hub: entry.hub)
        } catch {
            let original = error
            try await releaseConnection(key, token: token)
            throw GraphCloudConnectionError.translate(original)
        }
    }

    private func start(_ key: String) {
        guard !backgrounded, let entry = connections[key], entry.startup == nil, entry.suspension == nil,
              entry.retry == nil, entry.closing == nil, !entry.tokens.isEmpty, entry.hub.current != .ready else { return }
        let generation = entry.generation
        connections[key]!.startup = Task { await self.startTransport(key, generation: generation) }
    }

    private func startTransport(_ key: String, generation: UUID) async {
        guard let entry = connections[key], entry.generation == generation else { return }
        var contended = false
        do {
            try Task.checkCancellation()
            await manager.resumePublicTransport(entry.configuration.native, foreground: foreground)
            try Task.checkCancellation()
            _ = try await manager.startCloudSession(entry.configuration.native, adapter: adapter, disk: disk)
            try Task.checkCancellation()
            await manager.publishCloudConnectionState(key)
        } catch {
            if !Task.isCancelled && !backgrounded {
                contended = error as? GraphCloudError == .directoryBusy
                await manager.publishCloudConnectionState(key, failure: error)
            }
        }
        guard connections[key]?.generation == generation else { return }
        connections[key]?.startup = nil
        if Task.isCancelled { start(key) }
        else if contended, foreground { scheduleRetry(key, generation: generation) }
        else { connections[key]?.retryDelay = 1 }
    }

    private func scheduleRetry(_ key: String, generation: UUID) {
        guard !backgrounded, let entry = connections[key], entry.closing == nil,
              entry.suspension == nil, entry.retry == nil else { return }
        let delay = entry.retryDelay
        connections[key]?.retryDelay = min(delay * 2, 8)
        connections[key]?.retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            await self?.retryAfterContention(key, generation: generation)
        }
    }

    private func retryAfterContention(_ key: String, generation: UUID) {
        guard !Task.isCancelled, connections[key]?.generation == generation else { return }
        connections[key]?.retry = nil
        start(key)
    }

    func retry(_ key: String, token: UUID) async throws {
        let entry = try connection(key, token: token)
        guard !backgrounded, entry.startup == nil, entry.suspension == nil else { return }
        entry.retry?.cancel()
        connections[key]?.retry = nil
        connections[key]?.retryDelay = 1
        await manager.invalidatePublicAccountQuery(key)
        guard !backgrounded, connections[key]?.closing == nil else { return }
        entry.hub.publish(.verifyingAccount)
        start(key)
    }

    func configuration(_ key: String, token: UUID) throws -> GraphCloudConfiguration {
        try connection(key, token: token).configuration.native
    }
    private func connection(_ key: String, token: UUID) throws -> ConnectionEntry {
        guard let entry = connections[key], entry.tokens.contains(token), entry.closing == nil else { throw GraphCloudConnectionError.closed }
        return entry
    }
    func requireReady(_ key: String, token: UUID) throws -> GraphCloudConfiguration {
        let entry = try connection(key, token: token)
        guard !backgrounded, entry.hub.current == .ready else { throw GraphCloudConnectionError.notReady }
        return entry.configuration.native
    }
    func bind(_ graph: GraphStore, zoneName: String, key: String, token: UUID) async throws {
        let configuration = try requireReady(key, token: token)
        guard await graph.publicContextIdentity == identity else { throw GraphStoreError.foreignGraph }
        try await graph.observationAdmission()
        try await manager.bindCloudZone(.init(scope: .private, owner: CKCurrentUserDefaultName, name: zoneName), to: graph.id, configuration: configuration)
    }

    func releaseConnection(_ key: String, token: UUID) async throws {
        guard var entry = connections[key], entry.tokens.remove(token) != nil else { return }
        entry.hub.finish(owner: token)
        connections[key] = entry
        guard entry.tokens.isEmpty else { return }
        entry.retry?.cancel()
        let startup = entry.startup, suspension = entry.suspension
        let reservation = entry.reservation, manager = manager, configuration = entry.configuration.native
        let task = Task {
            _ = try? await reservation.value
            await startup?.value
            try await suspension?.value
            try await manager.stopCloudSession(configuration)
        }
        connections[key]!.closing = task
        try await task.value
        await GraphCloudOwnership.shared.unreserve(configuration.containerIdentifier, owner: identity)
        await manager.removePublicConnectionHub(key)
        connections.removeValue(forKey: key)
    }

    package static func validateStoreURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
              url.pathExtension.lowercased() == "sqlite" else { throw GraphStoreError.unsupportedLayout }
    }
    private func validateStoreURL(_ url: URL) throws { try Self.validateStoreURL(url) }
}

extension GraphContextManager {
    func setLocalAccountAdapter(_ adapter: GraphCloudAdapter) { localAccountAdapter = adapter }
    func installPublicConnectionHub(_ hub: GraphCloudConnectionHub, namespace: String, adapter: GraphCloudAdapter) {
        publicConnectionHubs[namespace] = hub; localAccountAdapter = adapter
    }
    func removePublicConnectionHub(_ namespace: String) {
        publicConnectionHubs.removeValue(forKey: namespace)
        publicBackgroundSessions.remove(namespace)
    }
    func refreshPublicAccounts(excluding keys: Set<String> = []) {
        for key in accountAuthorities.keys where !keys.contains(key) { scheduleAccountRefresh(key) }
    }
    func invalidatePublicAccountQuery(_ namespace: String) {
        accountAuthorities[namespace]?.query = UUID(); accountAuthorities[namespace]?.verification = nil
    }
    func resumePublicTransport(_ configuration: GraphCloudConfiguration, foreground: Bool) {
        publicBackgroundSessions.remove(configuration.namespace)
        accountAutomaticActivity[configuration.namespace] = foreground
    }

    func activatePublicTransport(_ configuration: GraphCloudConfiguration) async {
        let key = configuration.namespace
        guard !publicBackgroundSessions.contains(key) else { return }
        accountAutomaticActivity[key] = true
        guard cloudSessions[key]?.session != nil else { return }
        do { try await setAutomaticCloudSynchronizationActive(true, configuration: configuration, clock: .live) }
        catch {
            if !publicBackgroundSessions.contains(key) { await publishCloudConnectionState(key, failure: error) }
        }
    }

    func suspendPublicTransport(_ configuration: GraphCloudConfiguration) async throws {
        let key = configuration.namespace
        publicBackgroundSessions.insert(key)
        accountAuthorities[key]?.wantsCloud = false
        accountAutomaticActivity[key] = false
        await publishCloudConnectionState(key)
        // A pending account check owns no directory lease. The admission guard
        // prevents it from constructing a session after this transition.
        if let opening = cloudSessions[key] {
            guard opening.configuration == configuration else { throw GraphCloudError.ownershipConflict }
            try await stopCloudSession(configuration, accountRecovery: false, discardFailedOpening: true)
        }
        await publishCloudConnectionState(key)
    }
}
