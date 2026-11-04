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
    private struct ConnectionEntry {
        let generation = UUID()
        let configuration: GraphCloudConnectionConfiguration
        let hub: GraphCloudConnectionHub
        let reservation: Task<Void, any Error>
        var tokens: Set<UUID> = []
        var startup: Task<Void, Never>?
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
        try validateStoreURL(storeURL)
        await prepareMonitoring()
        return await retained(try await manager.createGraph(id: id, at: storeURL, conflictPolicy: conflictPolicy))
    }

    /// Opens the selected existing graph without creating, converting or enabling transport.
    public func openGraph(id: GraphID, at storeURL: URL) async throws -> GraphStore {
        try validateStoreURL(storeURL)
        await prepareMonitoring()
        return await retained(try await manager.openGraph(id: id, at: storeURL))
    }

    private func retained(_ graph: GraphStore) async -> GraphStore {
        await graph.retainPublicContext(self, identity: identity)
        return graph
    }
    private func prepareMonitoring() async { await manager.setLocalAccountAdapter(adapter) }

    /// Forwards aggregate application scene activity; initially inactive.
    public func setForegroundActive(_ active: Bool) async throws {
        try Task.checkCancellation()
        foreground = active
        await prepareMonitoring()
        if active { await manager.refreshPublicAccounts() }
        for entry in connections.values where entry.closing == nil {
            await manager.setPublicForeground(active, configuration: entry.configuration.native)
        }
    }

    /// Schedules identity checks for observed accounts without starting stopped transport.
    public func refreshCloudAccounts() async throws {
        try Task.checkCancellation()
        await prepareMonitoring()
        await manager.refreshPublicAccounts()
    }

    /// Reserves transport and returns before account/network startup completes.
    public func connectCloud(using configuration: GraphCloudConnectionConfiguration) async throws -> GraphCloudConnection {
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
            await manager.setPublicForeground(foreground, configuration: configuration.native)
            start(key)
            return GraphCloudConnection(context: self, namespace: key, token: token, hub: entry.hub)
        } catch {
            let original = error
            try await releaseConnection(key, token: token)
            throw GraphCloudConnectionError.translate(original)
        }
    }

    private func start(_ key: String) {
        guard let entry = connections[key], entry.startup == nil, entry.closing == nil, entry.hub.current != .ready else { return }
        let generation = entry.generation
        connections[key]!.startup = Task { await self.startTransport(key, generation: generation) }
    }
    private func startTransport(_ key: String, generation: UUID) async {
        guard let entry = connections[key], entry.generation == generation else { return }
        do {
            _ = try await manager.startCloudSession(entry.configuration.native, adapter: adapter, disk: disk)
            await manager.setPublicForeground(foreground, configuration: entry.configuration.native)
            await manager.publishCloudConnectionState(key)
        } catch { await manager.publishCloudConnectionState(key, failure: error) }
        if connections[key]?.generation == generation { connections[key]?.startup = nil }
    }

    func retry(_ key: String, token: UUID) async throws {
        let entry = try connection(key, token: token)
        guard entry.startup == nil else { return }
        await manager.invalidatePublicAccountQuery(key)
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
        guard entry.hub.current == .ready else { throw GraphCloudConnectionError.notReady }
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
        let startup = entry.startup, reservation = entry.reservation, manager = manager, configuration = entry.configuration.native
        let task = Task {
            _ = try? await reservation.value
            await startup?.value
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
    func removePublicConnectionHub(_ namespace: String) { publicConnectionHubs.removeValue(forKey: namespace) }
    func refreshPublicAccounts() { for key in accountAuthorities.keys { scheduleAccountRefresh(key) } }
    func invalidatePublicAccountQuery(_ namespace: String) {
        accountAuthorities[namespace]?.query = UUID(); accountAuthorities[namespace]?.verification = nil
    }
    func setPublicForeground(_ active: Bool, configuration: GraphCloudConfiguration) async {
        accountAutomaticActivity[configuration.namespace] = active
        guard cloudSessions[configuration.namespace]?.session != nil else { return }
        do { try await setAutomaticCloudSynchronizationActive(active, configuration: configuration, clock: .live) }
        catch { await publishCloudConnectionState(configuration.namespace, failure: error) }
    }
}
