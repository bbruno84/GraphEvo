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
    private let attachmentRefresh = GraphCloudAttachmentRefresh<Void>()
    private let attachmentFetch = GraphCloudAttachmentRefresh<Set<GraphID>>()
    private var automatic: [String: GraphAutomaticSynchronizer] = [:]
    private var automaticClosing: [String: UUID] = [:]
    private var automaticActivityRevision: [String: UInt64] = [:]
    private var synchronization: [GraphID: GraphCloudSyncControl] = [:]

    @available(iOS 17, macOS 14, *)
    package func startCloudSession(_ configuration: GraphCloudConfiguration) async throws -> GraphCloudStatus {
        try await startCloudSession(configuration, adapter: .live)
    }

    func startCloudSession(_ configuration: GraphCloudConfiguration, adapter: GraphCloudAdapter,
                           disk: GraphCloudDisk = .live) async throws -> GraphCloudStatus {
        try Task.checkCancellation()
        let key = configuration.namespace
        guard automaticClosing[key] == nil else { throw GraphCloudError.stopping }
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
        automaticChanged()
    }

    package func fetchCloudChanges(_ scope: GraphCloudScope, configuration: GraphCloudConfiguration) async throws {
        _ = try await fetchAdmitted(scope, configuration: configuration)
    }

    private func fetchAdmitted(_ scope: GraphCloudScope, configuration: GraphCloudConfiguration,
        inheriting parent: GraphCloudSyncPermit? = nil, only graphID: GraphID? = nil, eligibleIDs: Set<GraphID>? = nil) async throws -> Set<GraphID> {
        let session = try await cloud(configuration)
        let routes = try await session.routes(in: scope)
        let selected = routes.filter { route in
            (graphID == nil || route.graphID == graphID) && (eligibleIDs?.contains(route.graphID) ?? true) && canSynchronize(route.graphID, inheriting: parent)
        }
        // Preserve control-only fetches for an unbound scope; a fully paused bound scope does no network work.
        if selected.isEmpty && (!routes.isEmpty || eligibleIDs != nil) { return [] }
        let permits = try selected.map { try admitSynchronization($0.graphID, inheriting: parent) }
        defer { for permit in permits { finishSynchronization(permit) } }
        try await session.fetch(scope, zones: Set(selected.map(\.zone)))
        return Set(selected.map(\.graphID))
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
        automaticClosing[configuration.namespace] = opening.id
        let session: GraphCloudSession
        do { session = try await opening.task.value }
        catch let quarantine as GraphCloudQuarantine { session = quarantine.session }
        catch {
            if cloudSessions[configuration.namespace]?.id == opening.id { cloudSessions.removeValue(forKey: configuration.namespace) }
            if automaticClosing[configuration.namespace] == opening.id { automaticClosing.removeValue(forKey: configuration.namespace) }
            throw error
        }
        let revision = (automaticActivityRevision[configuration.namespace] ?? 0) + 1
        automaticActivityRevision[configuration.namespace] = revision
        await automatic[configuration.namespace]?.setActive(false, revision: revision)
        try await session.stop()
        guard cloudSessions[configuration.namespace]?.id == opening.id else { return }
        if let scheduler = automatic.removeValue(forKey: configuration.namespace) { await scheduler.shutdown() }
        if cloudSessions[configuration.namespace]?.id == opening.id {
            cloudSessions.removeValue(forKey: configuration.namespace)
            automaticClosing.removeValue(forKey: configuration.namespace)
        }
    }

    private func withTransport<Value: Sendable>(_ graphID: GraphID, configuration: GraphCloudConfiguration,
        body: @Sendable (GraphCloudSession, GraphStore, GraphCloudTransportBinding, GraphCloudSyncPermit) async throws -> Value) async throws -> Value {
        let permit = try admitSynchronization(graphID)
        defer { finishSynchronization(permit) }
        guard transportGraphs.insert(graphID).inserted else { throw GraphCloudError.busy }
        defer { transportGraphs.remove(graphID) }
        let session = try await cloud(configuration), route = try await session.route(for: graphID)
        let binding = GraphCloudTransportBinding(identity: try await session.identity(), route: route)
        guard let location = locations[graphID] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: graphID, at: location.url)
        do {
            try await graph.pruneTransport(binding, retained: session.retainedReceiptIDs(for: graphID))
            let result = try await body(session, graph, binding, permit)
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
        try await withTransport(graphID, configuration: configuration) { session, graph, binding, _ in
            let previous = try await Self.drainSent(session, graph: graph, binding: binding)
            let incoming = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: 4096)
            var succeeded = previous.succeeded, failures = previous.failures
            var resolved = previous.resolvedConflicts + incoming.resolvedConflicts
            var cleanup = previous.cleanupPending || incoming.cleanupPending
            var retry = previous.retryIDs.union(incoming.retryIDs)
            var error: (any Error)?
            var retryAfter: TimeInterval?
            for pass in 0..<2 {
                let batch = try await graph.prepareTransport(binding, maximum: maximumRecords, onlyIDs: pass == 0 ? nil : retry)
                if batch.items.isEmpty { retry.removeAll(); break }
                do { try await session.send(batch) } catch let caught { error = caught }
                if let delay = await session.retryDelay(binding.route.zone.scope) { retryAfter = max(retryAfter ?? 0, delay) }
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
                resolvedConflicts: resolved, pendingRetry: !retry.isEmpty, retryAfter: retryAfter)
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
        try await withTransport(graphID, configuration: configuration) { session, graph, binding, _ in
            let sent = try await Self.drainSent(session, graph: graph, binding: binding)
            let incoming = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: maximumEvents)
            return GraphCloudApplyReport(applied: incoming.applied, cleanupPending: sent.cleanupPending || incoming.cleanupPending,
                resolvedConflicts: sent.resolvedConflicts + incoming.resolvedConflicts, pendingRetry: sent.pendingRetry || incoming.pendingRetry)
        }
    }

    /// Exports a verified local snapshot, refreshing through the shared engine only if absent.
    package func exportCloudAttachment(_ id: GraphNodeID, to destination: URL,
        configuration: GraphCloudConfiguration, timeout: Duration = .seconds(300)) async throws -> GraphAttachmentMetadata {
        guard timeout > .zero else { throw GraphCloudError.invalidConfiguration }
        try Task.checkCancellation()
        guard let location = locations[id.graphID] else { throw GraphStoreError.missingGraph }
        let graph = try await openGraph(id: id.graphID, at: location.url)
        do {
            var content = try await graph.read { try $0.attachment(id) }
            if content == nil {
                guard canSynchronize(id.graphID) else { throw GraphCloudError.graphPaused }
                let refresh = attachmentRefresh
                let graphKey = configuration.namespace + ":graph:" + id.graphID.rawValue.uuidString
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await refresh.run(graphKey) {
                            try await self.refreshCloudAttachment(for: id.graphID, configuration: configuration)
                        }
                    }
                    group.addTask { try await Task.sleep(for: timeout); throw GraphCloudError.attachmentTimeout }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                content = try await graph.read { try $0.attachment(id) }
            }
            guard let content else { throw GraphStoreError.missingNode }
            try await GraphAttachmentIO.export(content.data, to: destination)
            try await graph.close()
            return content.metadata
        } catch {
            let original = error; try? await graph.close(); throw original
        }
    }

    private func refreshCloudAttachment(for id: GraphID, configuration: GraphCloudConfiguration) async throws {
        try await withTransport(id, configuration: configuration) { session, graph, binding, permit in
            let fetch = self.attachmentFetch
            let key = configuration.namespace + ":scope:" + binding.route.zone.scope.rawValue
            let covered = try await fetch.run(key) {
                try await self.fetchAdmitted(binding.route.zone.scope, configuration: configuration, inheriting: permit)
            }
            // A graph resumed after the shared fetch's snapshot may not be covered by it.
            if !covered.contains(id) {
                _ = try await self.fetchAdmitted(binding.route.zone.scope, configuration: configuration, inheriting: permit, only: id)
            }
            _ = try await Self.drainSent(session, graph: graph, binding: binding)
            _ = try await Self.drainIncoming(session, graph: graph, binding: binding, maximumEvents: 4096)
        }
    }

    private func requireOpenGraph(_ id: GraphID) throws {
        guard let entry = entries[id], entry.ready, entry.closing == nil else { throw GraphStoreError.missingGraph }
    }

    package func cloudSynchronizationState(for id: GraphID) throws -> GraphCloudSyncState {
        try requireOpenGraph(id)
        return synchronization[id]?.state ?? .active
    }

    package func observeCloudSynchronization(for id: GraphID) throws -> AsyncStream<GraphCloudSyncState> {
        try requireOpenGraph(id)
        let token = UUID()
        let pair = AsyncStream<GraphCloudSyncState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var control = synchronization[id] ?? GraphCloudSyncControl()
        control.observers[token] = pair.continuation
        synchronization[id] = control
        pair.continuation.yield(control.state)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSynchronizationObserver(id, token: token) }
        }
        return pair.stream
    }

    package func pauseCloudSynchronization(for id: GraphID) async throws {
        try Task.checkCancellation()
        try requireOpenGraph(id)
        var control = synchronization[id] ?? GraphCloudSyncControl()
        if control.state == .active {
            control.state = .pauseRequested
            synchronization[id] = control
            for observer in control.observers.values { observer.yield(.pauseRequested) }
            automaticChanged()
        }
        if control.operations.isEmpty {
            if control.state != .paused {
                control.state = .paused
                synchronization[id] = control
                for observer in control.observers.values { observer.yield(.paused) }
            }
            return
        }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                synchronization[id]!.waiters[token] = continuation
            }
        } onCancel: { Task { await self.cancelPauseWaiter(id, token: token) } }
    }

    package func resumeCloudSynchronization(for id: GraphID) throws {
        try requireOpenGraph(id)
        var control = synchronization[id] ?? GraphCloudSyncControl()
        guard control.state != .pauseRequested else { throw GraphCloudError.busy }
        if control.state == .paused {
            control.state = .active
            synchronization[id] = control
            for observer in control.observers.values { observer.yield(.active) }
            automaticChanged()
        }
    }

    private func canSynchronize(_ id: GraphID, inheriting permit: GraphCloudSyncPermit? = nil) -> Bool {
        let control = synchronization[id] ?? GraphCloudSyncControl()
        return control.state == .active || (permit?.graphID == id && permit.map { control.operations.contains($0.id) } == true)
    }

    private func admitSynchronization(_ id: GraphID, inheriting parent: GraphCloudSyncPermit? = nil) throws -> GraphCloudSyncPermit {
        guard canSynchronize(id, inheriting: parent) else { throw GraphCloudError.graphPaused }
        let permit = GraphCloudSyncPermit(graphID: id, id: UUID())
        if synchronization[id] == nil { synchronization[id] = GraphCloudSyncControl() }
        synchronization[id]!.operations.insert(permit.id)
        return permit
    }

    private func finishSynchronization(_ permit: GraphCloudSyncPermit) {
        guard var control = synchronization[permit.graphID], control.operations.remove(permit.id) != nil else { return }
        var completed: [CheckedContinuation<Void, any Error>] = []
        if control.operations.isEmpty && control.state == .pauseRequested {
            control.state = .paused
            completed = Array(control.waiters.values); control.waiters.removeAll()
            for observer in control.observers.values { observer.yield(.paused) }
        }
        synchronization[permit.graphID] = control
        for waiter in completed { waiter.resume() }
        resetClosedSynchronization(permit.graphID)
    }

    private func cancelPauseWaiter(_ id: GraphID, token: UUID) {
        synchronization[id]?.waiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
    private func removeSynchronizationObserver(_ id: GraphID, token: UUID) {
        synchronization[id]?.observers.removeValue(forKey: token)
    }
    private func resetClosedSynchronization(_ id: GraphID) {
        guard entries[id] == nil, let control = synchronization[id], control.operations.isEmpty else { return }
        synchronization.removeValue(forKey: id)
        for waiter in control.waiters.values { waiter.resume(throwing: GraphStoreError.closed) }
        for observer in control.observers.values { observer.finish() }
    }

    deinit {
        for scheduler in automatic.values { Task { await scheduler.shutdown() } }
        for control in synchronization.values {
            for waiter in control.waiters.values { waiter.resume(throwing: GraphStoreError.closed) }
            for observer in control.observers.values { observer.finish() }
        }
        for opening in cloudSessions.values {
            Task {
                do { try await opening.task.value.stop() }
                catch let quarantine as GraphCloudQuarantine { try? await quarantine.session.stop() }
                catch { }
            }
        }
    }


    private func automaticChanged() {
        for scheduler in automatic.values { Task { await scheduler.changedInventory() } }
    }

    private func automaticScheduler(_ config: GraphCloudConfiguration, clock: GraphAutomaticClock = .live) async throws -> GraphAutomaticSynchronizer {
        guard automaticClosing[config.namespace] == nil else { throw GraphCloudError.stopping }
        let openingID = cloudSessions[config.namespace]?.id
        _ = try await cloud(config).identity()
        guard automaticClosing[config.namespace] == nil else { throw GraphCloudError.stopping }
        guard cloudSessions[config.namespace]?.id == openingID else { throw GraphCloudError.stopped }
        if let existing = automatic[config.namespace] { return existing }
        let driver = GraphAutomaticDriver(inventory: { [weak self] in
            guard let self else { throw GraphCloudError.stopped }
            return try await self.automaticInventory(config)
        }, subscribe: { [weak self] graph in
            guard let self else { throw GraphCloudError.stopped }
            return try await self.automaticFeed(graph)
        }, fetch: { [weak self] scope, ids in
            guard let self else { throw GraphCloudError.stopped }
            _ = try await self.fetchAdmitted(scope, configuration: config, eligibleIDs: ids)
        }, turn: { [weak self] graph in
            guard let self else { throw GraphCloudError.stopped }
            return try await self.automaticTurn(graph, configuration: config)
        }, sessionFailure: { [weak self] in
            guard let self else { return .stopped }
            return (try? await self.cloudStatus(config))?.failure
        })
        let scheduler = GraphAutomaticSynchronizer(driver: driver, clock: clock)
        automatic[config.namespace] = scheduler
        return scheduler
    }

    private func automaticInventory(_ config: GraphCloudConfiguration) async throws -> [GraphAutomaticGraph] {
        let session = try await cloud(config)
        let routes = try await session.routes(in: .private) + session.routes(in: .shared)
        return routes.compactMap { route in
            guard let entry = entries[route.graphID], entry.ready, entry.closing == nil else { return nil }
            return GraphAutomaticGraph(id: route.graphID, generation: entry.generation, scope: route.zone.scope,
                                       paused: !canSynchronize(route.graphID))
        }
    }
    private func automaticFeed(_ graph: GraphAutomaticGraph) async throws -> StoreInvalidationFeed {
        guard let entry = entries[graph.id], entry.generation == graph.generation, entry.closing == nil else { throw GraphStoreError.closed }
        let feed = try await entry.opening.value.localCommitFeed()
        guard entries[graph.id]?.generation == graph.generation, entries[graph.id]?.closing == nil else { feed.cancel(); throw GraphStoreError.closed }
        return feed
    }
    private func automaticTurn(_ descriptor: GraphAutomaticGraph, configuration: GraphCloudConfiguration) async throws -> (GraphCloudSendReport, Int) {
        guard let entry = entries[descriptor.id], entry.generation == descriptor.generation, entry.ready, entry.closing == nil else { throw GraphStoreError.closed }
        let graph = try await openGraph(id: descriptor.id, at: entry.url)
        do {
            guard entries[descriptor.id]?.generation == descriptor.generation else { throw GraphStoreError.closed }
            let report = try await sendCloudChanges(for: descriptor.id, configuration: configuration)
            let remaining = try await graph.collectSyncChanges()
            try await graph.close()
            return (report, remaining)
        } catch { let original = error; try? await graph.close(); throw original }
    }

    package func setAutomaticCloudSynchronizationActive(_ active: Bool, configuration: GraphCloudConfiguration) async throws {
        try await setAutomaticCloudSynchronizationActive(active, configuration: configuration, clock: .live)
    }
    func setAutomaticCloudSynchronizationActive(_ active: Bool, configuration: GraphCloudConfiguration, clock: GraphAutomaticClock) async throws {
        try Task.checkCancellation()
        guard automaticClosing[configuration.namespace] == nil else { throw GraphCloudError.stopping }
        let revision = (automaticActivityRevision[configuration.namespace] ?? 0) + 1
        automaticActivityRevision[configuration.namespace] = revision
        let scheduler = try await automaticScheduler(configuration, clock: clock)
        await scheduler.setActive(active, revision: revision)
    }
    package func requestCloudSynchronization(configuration: GraphCloudConfiguration) async throws {
        let scheduler = try await automaticScheduler(configuration)
        await scheduler.changedInventory(); await scheduler.request(explicit: true)
    }
    package func notifyRemoteCloudChanges(in scope: GraphCloudScope, configuration: GraphCloudConfiguration) async throws {
        try await automaticScheduler(configuration).request(scope: scope)
    }
    package func automaticCloudSynchronizationStatus(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> GraphAutomaticSyncStatus {
        let scheduler = try await automaticScheduler(configuration)
        await scheduler.changedInventory(); return try await scheduler.status(id)
    }
    package func observeAutomaticCloudSynchronization(for id: GraphID, configuration: GraphCloudConfiguration) async throws -> AsyncStream<GraphAutomaticSyncStatus> {
        let scheduler = try await automaticScheduler(configuration)
        await scheduler.changedInventory(); return try await scheduler.observe(id)
    }

    func automaticSynchronizationDeadline(_ id: GraphID, configuration: GraphCloudConfiguration) async -> TimeInterval? {
        await automatic[configuration.namespace]?.diagnosticDeadline(id)
    }
    func automaticSynchronizationIdle(_ configuration: GraphCloudConfiguration) async -> Bool {
        await automatic[configuration.namespace]?.diagnosticIdle ?? true
    }

    // Internal lifecycle diagnostics for deterministic ownership tests.
    var attachmentRefreshWaiterCount: Int { get async { await attachmentRefresh.registeredWaiterCount } }
    var attachmentFetchWaiterCount: Int { get async { await attachmentFetch.registeredWaiterCount } }
    var automaticClosingCount: Int { automaticClosing.count }
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
                        removeClosedEntry(id, generation: entry.generation)
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
                    automaticChanged()
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
        removeClosedEntry(id, generation: generation)
    }

    private func removeClosedEntry(_ id: GraphID, generation: UUID) {
        guard entries[id]?.generation == generation else { return }
        entries.removeValue(forKey: id)
        // Either close or a waiting reopen may retire the owner first; both must reset idle pause state.
        resetClosedSynchronization(id)
        automaticChanged()
    }
}
