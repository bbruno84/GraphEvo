import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Process-local graph orchestration and explicit package-only CloudKit sessions.
package actor GraphContextManager {
    private struct Entry {
        let generation = UUID()
        let key: StoreKey
        let creating: Bool
        let opening: Task<GraphCoordinator, any Error>
        var ready = false
        var tokens: Set<UUID> = []
        var closing: Task<Void, any Error>?
    }
    private let registry: StoreRegistry
    private let schema: StoreSchema
    private let adapter: GraphCoordinatorAdapter
    private var entries: [GraphID: Entry] = [:]
    private struct CloudOpening {
        let id = UUID()
        let configuration: GraphCloudConfiguration
        let task: Task<GraphCloudSession, any Error>
    }
    private var cloudSessions: [String: CloudOpening] = [:]

    @available(iOS 17, macOS 14, *)
    package func startCloudSession(_ configuration: GraphCloudConfiguration) async throws -> GraphCloudStatus {
        try await startCloudSession(configuration, adapter: .live)
    }

    func startCloudSession(_ configuration: GraphCloudConfiguration, adapter: GraphCloudAdapter,
                           disk: GraphCloudDisk = .live) async throws -> GraphCloudStatus {
        try Task.checkCancellation()
        let key = configuration.namespace
        if let existing = cloudSessions[key] {
            guard existing.configuration == configuration else { throw GraphCloudError.ownershipConflict }
        } else {
            let task = Task.detached { try await GraphCloudSession.open(configuration, adapter: adapter, disk: disk) }
            cloudSessions[key] = CloudOpening(configuration: configuration, task: task)
        }
        let opening = cloudSessions[key]!
        let session: GraphCloudSession
        do { session = try await opening.task.value }
        catch {
            if !(error is GraphCloudQuarantine), cloudSessions[key]?.id == opening.id { cloudSessions.removeValue(forKey: key) }
            throw error
        }
        return try await session.startStatus()
    }

    private func cloud(_ configuration: GraphCloudConfiguration) async throws -> GraphCloudSession {
        guard let opening = cloudSessions[configuration.namespace], opening.configuration == configuration else { throw GraphCloudError.stopped }
        return try await opening.task.value
    }

    package func bindCloudZone(_ zone: GraphCloudZone, to graphID: GraphID,
                               configuration: GraphCloudConfiguration) async throws {
        guard let entry = entries[graphID], entry.closing == nil else { throw GraphStoreError.missingGraph }
        let owner = try await entry.opening.value
        try await owner.validateCloudBinding(adapter.initialize)
        guard case .sqlite(let path) = entry.key else { throw GraphStoreError.unsupportedLayout }
        let resolved = try StoreRegistry.resolve(.init(location: .sqlite(URL(fileURLWithPath: path)), exclusiveGraphID: graphID.rawValue))
        guard case .sqlite(let url) = resolved.configuration.location else { throw GraphStoreError.unsupportedLayout }
        try await cloud(configuration).bind(GraphCloudBinding(zone: zone, graphID: graphID, storeURL: url))
    }

    package func fetchCloudChanges(_ scope: GraphCloudScope, configuration: GraphCloudConfiguration) async throws {
        try await cloud(configuration).fetch(scope)
    }
    package func cloudStatus(_ configuration: GraphCloudConfiguration) async throws -> GraphCloudStatus {
        await (try cloud(configuration)).status()
    }
    package func cloudInbox(_ configuration: GraphCloudConfiguration, limit: Int = 100) async throws -> [GraphCloudInboxEntry] {
        try await cloud(configuration).inbox(limit: limit)
    }
    package func cloudBinding(for zone: GraphCloudZone, configuration: GraphCloudConfiguration) async throws -> GraphCloudBinding? {
        await (try cloud(configuration)).binding(for: zone)
    }
    package func stopCloudSession(_ configuration: GraphCloudConfiguration) async throws {
        guard let opening = cloudSessions[configuration.namespace], opening.configuration == configuration else { return }
        let session: GraphCloudSession
        do { session = try await opening.task.value }
        catch let quarantine as GraphCloudQuarantine { session = quarantine.session }
        try await session.stop()
        if cloudSessions[configuration.namespace]?.id == opening.id { cloudSessions.removeValue(forKey: configuration.namespace) }
    }

    deinit {
        for opening in cloudSessions.values {
            Task {
                do { try await opening.task.value.stop() }
                catch let quarantine as GraphCloudQuarantine { try? await quarantine.session.stop() }
                catch { }
            }
        }
    }

    // Internal lifecycle diagnostics for deterministic ownership tests.
    var registeredGraphCount: Int { entries.count }
    var registeredHandleCount: Int { entries.values.reduce(0) { $0 + $1.tokens.count } }

    package init(registry: StoreRegistry = .shared, schema: StoreSchema, adapter: GraphCoordinatorAdapter) {
        self.registry = registry; self.schema = schema; self.adapter = adapter
    }

    package func createGraph(id: GraphID, at url: URL) async throws -> GraphStore {
        try await request(id: id, url: url, creating: true)
    }

    package func openGraph(id: GraphID, at url: URL) async throws -> GraphStore {
        try await request(id: id, url: url, creating: false)
    }

    private func request(id: GraphID, url: URL, creating: Bool) async throws -> GraphStore {
        do {
            try Task.checkCancellation()
            let resolved = try StoreRegistry.resolve(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue))
            while true {
                try Task.checkCancellation()
                if let entry = entries[id] {
                    guard entry.key == resolved.key else { throw GraphStoreError.ownershipConflict }
                    if let closing = entry.closing {
                        try await closing.value
                        if entries[id]?.generation == entry.generation { entries.removeValue(forKey: id) }
                        continue
                    }
                    if creating && (entry.ready || !entry.creating) { throw GraphStoreError.duplicateIdentity }
                } else {
                    guard !entries.values.contains(where: { $0.key == resolved.key }) else { throw GraphStoreError.ownershipConflict }
                    let registry = registry, schema = schema, adapter = adapter, configuration = resolved.configuration
                    let opening = Task.detached {
                        try await GraphCoordinator.open(id: id, configuration: configuration, creating: creating,
                                                        registry: registry, schema: schema, adapter: adapter)
                    }
                    entries[id] = Entry(key: resolved.key, creating: creating, opening: opening)
                }
                let token = UUID()
                entries[id]!.tokens.insert(token)
                let entry = entries[id]!
                let owner: GraphCoordinator
                do { owner = try await entry.opening.value }
                catch {
                    if entries[id]?.generation == entry.generation {
                        entries[id]?.tokens.remove(token)
                        if let quarantine = error as? GraphCoordinatorQuarantine {
                            entries[id]?.closing = Task { throw quarantine.failure }
                        } else if let runtime = error as? StoreRuntimeError,
                                  case .shutdownFailed = runtime {
                            // StoreRegistry already retains a partially loaded native owner.
                            entries[id]?.closing = Task { throw runtime }
                        } else if entries[id]?.tokens.isEmpty == true { entries.removeValue(forKey: id) }
                    }
                    throw (error as? GraphCoordinatorQuarantine)?.failure ?? error
                }
                entries[id]?.ready = true
                let generation = entry.generation
                do {
                    // A successful shared creation commit must return its result even if cancelled.
                    if !creating { try Task.checkCancellation() }
                    return try await owner.lease { try await self.release(id, generation: generation, token: token) }
                } catch {
                    try await release(id, generation: entry.generation, token: token)
                    throw error
                }
            }
        } catch { throw GraphStore.translate(error) }
    }

    private func release(_ id: GraphID, generation: UUID, token: UUID) async throws {
        guard var entry = entries[id], entry.generation == generation,
              entry.tokens.remove(token) != nil else { return }
        if !entry.tokens.isEmpty { entries[id] = entry; return }
        let opening = entry.opening
        let closing = Task { try await opening.value.close() }
        entry.closing = closing
        entries[id] = entry
        try await closing.value
        if entries[id]?.generation == generation { entries.removeValue(forKey: id) }
    }
}
