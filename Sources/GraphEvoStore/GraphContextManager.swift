import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Process-local graph orchestration and explicit package-only CloudKit sessions.
package actor GraphContextManager {
    private struct Entry {
        let generation = UUID()
        let key: StoreKey
        let url: URL
        let creating: Bool
        let initialPolicy: GraphConflictPolicy
        let opening: Task<GraphCoordinator, any Error>
        var ready = false
        var tokens: Set<UUID> = []
        var closing: Task<Void, any Error>?
    }
    private let registry: StoreRegistry
    private let schema: StoreSchema
    private let adapter: GraphCoordinatorAdapter
    private var entries: [GraphID: Entry] = [:]
    private struct GraphLocation { let key: StoreKey; let url: URL }
    // Runtime-only registrations. App bootstrap supplies current sandbox/App Group URLs after relaunch.
    private var locations: [GraphID: GraphLocation] = [:]
    private struct CloudOpening {
        let id = UUID()
        let configuration: GraphCloudConfiguration
        let task: Task<GraphCloudSession, any Error>
    }
    private var cloudSessions: [String: CloudOpening] = [:]
    private var transportGraphs = Set<GraphID>()

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
        try await cloud(configuration).bind(GraphCloudBinding(zone: zone, graphID: graphID))
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

    private func withTransport<Value: Sendable>(_ graphID: GraphID, configuration: GraphCloudConfiguration,
        body: @Sendable (GraphCloudSession, GraphStore, GraphCloudTransportBinding) async throws -> Value) async throws -> Value {
        guard transportGraphs.insert(graphID).inserted else { throw GraphCloudError.busy }
        defer { transportGraphs.remove(graphID) }
        let session = try await cloud(configuration), route = try await session.route(for: graphID)
        let binding = GraphCloudTransportBinding(identity: try await session.identity(), route: route)
        guard let location = locations[graphID] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: graphID, at: location.url)
        do {
            try await graph.pruneTransport(binding, retained: session.retainedReceiptIDs(for: graphID))
            let result = try await body(session, graph, binding)
            try await graph.close(); return result
        } catch {
            let original = error; try? await graph.close(); throw original
        }
    }
    private static func drainSent(_ session: GraphCloudSession, graph: GraphStore, binding: GraphCloudTransportBinding) async throws -> GraphCloudSendReport {
        let receipts = try await session.sentReceipts(for: graph.id)
        var succeeded = 0, failures: [GraphCloudRecordFailure] = [], cleanup = false, resolved = 0
        var retry = Set<GraphNodeID>()
        var pendingIDs: Set<GraphNodeID>?
        let batches = receipts.reduce(into: [UUID]()) { if !$0.contains($1.batchID) { $0.append($1.batchID) } }
        for batch in batches {
            let group = receipts.filter { $0.batchID == batch }, ids = Set(group.map(\.id))
            _ = try await session.identity()
            let result = try await graph.commitTransport(binding, receipts: group)
            try await session.consume(ids)
            do { try await graph.trimTransport(binding, receipts: ids) } catch { cleanup = true }
            succeeded += group.reduce(0) { $0 + $1.saved.count + $1.deletedNames.count }
            failures += result.failures; resolved += result.resolved; retry.formUnion(result.rebased)
            pendingIDs = result.pendingIDs
        }
        return GraphCloudSendReport(succeeded: succeeded, failures: failures, cleanupPending: cleanup, transportError: nil,
            resolvedConflicts: resolved, pendingRetry: !retry.isEmpty, retryIDs: retry, pendingIDs: pendingIDs)
    }
    package func sendCloudChanges(for graphID: GraphID, configuration: GraphCloudConfiguration,
                                  maximumRecords: Int = 100) async throws -> GraphCloudSendReport {
        try await withTransport(graphID, configuration: configuration) { session, graph, binding in
            let previous = try await Self.drainSent(session, graph: graph, binding: binding)
            let incoming = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: 4096)
            var succeeded = previous.succeeded, failures = previous.failures
            var resolved = previous.resolvedConflicts + incoming.resolvedConflicts
            var cleanup = previous.cleanupPending || incoming.cleanupPending
            var retry = previous.retryIDs.union(incoming.retryIDs)
            var error: (any Error)?
            for pass in 0..<2 {
                let batch = try await graph.prepareTransport(binding, maximum: maximumRecords, onlyIDs: pass == 0 ? nil : retry)
                if batch.items.isEmpty { retry.removeAll(); break }
                do { try await session.send(batch) } catch let caught { error = caught }
                let result = try await Self.drainSent(session, graph: graph, binding: binding)
                succeeded += result.succeeded; failures += result.failures; resolved += result.resolvedConflicts
                cleanup = cleanup || result.cleanupPending
                // Keep earlier rebases outside this bounded batch; only committed queue state can settle them.
                if let pending = result.pendingIDs { retry.formIntersection(pending) }
                retry.formUnion(result.retryIDs)
                // Expected record conflicts may accompany a partial-failure error; only resolved cases qualify for a retry.
                if let native = error as? NSError, native.domain == "CKErrorDomain", [2, 11, 14].contains(native.code), result.resolvedConflicts > 0, result.failures.isEmpty { error = nil }
                if retry.isEmpty || error != nil || !result.failures.isEmpty { break }
            }
            return GraphCloudSendReport(succeeded: succeeded, failures: failures, cleanupPending: cleanup, transportError: error,
                resolvedConflicts: resolved, pendingRetry: !retry.isEmpty)
        }
    }
    private static func drainIncoming(_ session: GraphCloudSession, graph: GraphStore, binding: GraphCloudTransportBinding,
                                      maximumEvents: Int) async throws -> GraphCloudApplyReport {
        var entries = try await session.incoming(for: binding.route.zone, limit: maximumEvents)
        // Access reduction must not wait for unrelated application payload decoding.
        if entries.contains(where: { $0.change.kind == .zoneDeleted }) { entries = entries.filter { $0.change.kind == .zoneDeleted } }
        if entries.isEmpty { return GraphCloudApplyReport(applied: 0, cleanupPending: false) }
        let effects = try entries.map { try GraphCloudEffect($0, binding: binding.route) }
        _ = try await session.identity()
        let result = try await graph.applyTransport(binding, effects: effects)
        let ids = Set(entries.map(\.id))
        try await session.consume(ids)
        var cleanup = false
        do { try await graph.trimTransport(binding, receipts: ids) } catch { cleanup = true }
        return GraphCloudApplyReport(applied: entries.count, cleanupPending: cleanup, resolvedConflicts: result.resolved,
            pendingRetry: !result.rebased.isEmpty, retryIDs: result.rebased)
    }
    package func applyCloudInbox(for graphID: GraphID, configuration: GraphCloudConfiguration,
                                 maximumEvents: Int = 4096) async throws -> GraphCloudApplyReport {
        try await withTransport(graphID, configuration: configuration) { session, graph, binding in
            let sent = try await Self.drainSent(session, graph: graph, binding: binding)
            let incoming = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: maximumEvents)
            return GraphCloudApplyReport(applied: incoming.applied, cleanupPending: sent.cleanupPending || incoming.cleanupPending,
                resolvedConflicts: sent.resolvedConflicts + incoming.resolvedConflicts, pendingRetry: sent.pendingRetry || incoming.pendingRetry)
        }
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

    package func createGraph(id: GraphID, at url: URL, conflictPolicy: GraphConflictPolicy = .lastEditWins) async throws -> GraphStore {
        try await request(id: id, url: url, creating: true, conflictPolicy: conflictPolicy)
    }

    package func openGraph(id: GraphID, at url: URL) async throws -> GraphStore {
        try await request(id: id, url: url, creating: false)
    }

    private func request(id: GraphID, url: URL, creating: Bool, conflictPolicy: GraphConflictPolicy = .lastEditWins) async throws -> GraphStore {
        do {
            try Task.checkCancellation()
            let resolved = try StoreRegistry.resolve(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue))
            if let existing = locations[id], existing.key != resolved.key { throw GraphStoreError.ownershipConflict }
            while true {
                try Task.checkCancellation()
                if let entry = entries[id] {
                    guard entry.key == resolved.key else { throw GraphStoreError.ownershipConflict }
                    if let closing = entry.closing {
                        try await closing.value
                        if entries[id]?.generation == entry.generation { entries.removeValue(forKey: id) }
                        continue
                    }
                    if creating && entry.initialPolicy != conflictPolicy { throw GraphStoreError.ownershipConflict }
                    if creating && (entry.ready || !entry.creating) { throw GraphStoreError.duplicateIdentity }
                } else {
                    guard !entries.values.contains(where: { $0.key == resolved.key }) else { throw GraphStoreError.ownershipConflict }
                    let registry = registry, schema = schema, adapter = adapter, configuration = resolved.configuration
                    let opening = Task.detached {
                        try await GraphCoordinator.open(id: id, configuration: configuration, creating: creating,
                                                        registry: registry, schema: schema, adapter: adapter, conflictPolicy: conflictPolicy)
                    }
                    guard case .sqlite(let canonicalURL) = resolved.configuration.location else { throw GraphStoreError.unsupportedLayout }
                    entries[id] = Entry(key: resolved.key, url: canonicalURL, creating: creating, initialPolicy: conflictPolicy, opening: opening)
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
                    let graph = try await owner.lease { try await self.release(id, generation: generation, token: token) }
                    locations[id] = GraphLocation(key: entry.key, url: entry.url)
                    return graph
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
