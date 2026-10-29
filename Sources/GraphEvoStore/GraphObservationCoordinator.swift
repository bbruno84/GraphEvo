import Foundation
import GraphEvoModel
import GraphEvoRuntime
import os

package struct GraphSharedObservationSnapshot: Sendable {
    package var executions = 0
    package var activeGroups = 0
    package var subscribers = 0
}

/// Payload-free counters owned by one coordinator, never global query state.
private final class SharedObservationCounters: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: GraphSharedObservationSnapshot())
    func execution() { state.withLock { $0.executions += 1 } }
    func group(_ delta: Int) { state.withLock { $0.activeGroups += delta } }
    func subscriber(_ delta: Int) { state.withLock { $0.subscribers += delta } }
    var snapshot: GraphSharedObservationSnapshot { state.withLock { $0 } }
}

private enum SharedObservationInput: Sendable {
    case snapshot(GraphQueryOutput, GraphQueryLocalView)
    case failure(any Error)
}
private enum SharedDeliveryStatus { case active, closed, accountChanged }

private protocol SharedObservationGroup: AnyObject, Sendable {}

/// Shares native reads for exact descriptors on one logical handle.
/// Application decoding and delivery remain independent for every subscriber.
actor GraphObservationCoordinator {
    private struct Entry: Sendable {
        let token: UUID
        let definition: GraphQueryDefinition
        let budget: GraphQueryBudget
        let limit: Int?
        let model: ObjectIdentifier
        let group: any SharedObservationGroup
    }
    private weak var graph: GraphStore?
    private let counters = SharedObservationCounters()
    private let source: @Sendable () async throws -> StoreInvalidationFeed
    private let beforeRead: @Sendable () async -> Void
    private var groups: [Entry] = []
    init(graph: GraphStore, source: (@Sendable () async throws -> StoreInvalidationFeed)? = nil,
                 beforeRead: @escaping @Sendable () async -> Void = {}) {
        self.graph = graph; self.source = source ?? { [weak graph] in
            guard let graph else { throw GraphStoreError.closed }
            return try await graph.observationFeed()
        }; self.beforeRead = beforeRead
    }
    var diagnostics: GraphSharedObservationSnapshot { counters.snapshot }

    func observe<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphObservation<GraphQueryState<Model>> {
        guard let graph else { throw GraphStoreError.closed }
        guard query.cursor == nil else { throw GraphQueryError.invalidCursor }
        try GraphQueryValidation.request(query.request, graphID: graph.id)
        try await graph.observationAdmission()
        let matching = groups.firstIndex { $0.definition == query.definition && $0.budget == query.budget &&
            $0.limit == query.rowLimit && $0.model == ObjectIdentifier(Model.self) }
        var group: SharedTypedObservationGroup<Model>?
        var observation: GraphObservation<GraphQueryState<Model>>?
        if let matching, let current = groups[matching].group as? SharedTypedObservationGroup<Model> {
            observation = current.subscribe()
            if observation != nil { group = current } else { groups.remove(at: matching) }
        }
        if group == nil {
            let token = UUID()
            let fresh = SharedTypedObservationGroup<Model>(graph: graph, query: query, counters: counters, source: source, beforeRead: beforeRead) { [weak self] in
                Task { await self?.retire(token) }
            }
            groups.append(Entry(token: token, definition: query.definition, budget: query.budget,
                                limit: query.rowLimit, model: ObjectIdentifier(Model.self), group: fresh))
            observation = fresh.subscribe(); group = fresh
            fresh.start()
        }
        guard let group, let observation else { throw GraphStoreError.closed }
        do {
            // Return only after native source registration; joins always queue a fresh read.
            try await group.ready()
            try Task.checkCancellation()
            return observation
        } catch { observation.cancel(); throw error }
    }
    private func retire(_ token: UUID) { groups.removeAll { $0.token == token } }
}

/// All mutable state is locked. No continuation delivery, cancellation, application-value
/// destruction or asynchronous work executes while the lock is held. No result is cached.
private final class SharedTypedObservationGroup<Model: GraphModel>: SharedObservationGroup {
    private struct State: Sendable {
        var closed = false
        var subscribers: [UUID: AsyncStream<SharedObservationInput>.Continuation] = [:]
        var accountChanged = false
        var worker: Task<Void, Never>?
        var refresh: (@Sendable () -> Void)?
        var cancelSource: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let graph: GraphStore
    private let query: GraphQuery<Model>
    private let counters: SharedObservationCounters
    private let retired: @Sendable () -> Void
    private let registration: Task<StoreInvalidationFeed, any Error>
    private let beforeRead: @Sendable () async -> Void

    init(graph: GraphStore, query: GraphQuery<Model>, counters: SharedObservationCounters,
         source: @escaping @Sendable () async throws -> StoreInvalidationFeed,
         beforeRead: @escaping @Sendable () async -> Void, retired: @escaping @Sendable () -> Void) {
        self.graph = graph; self.query = query; self.counters = counters; self.retired = retired
        self.beforeRead = beforeRead
        registration = Task { try await source() }
        counters.group(1)
    }
    func ready() async throws { _ = try await registration.value }
    func subscribe() -> GraphObservation<GraphQueryState<Model>>? {
        let token = UUID(), pair = AsyncStream<GraphQueryState<Model>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let raw = AsyncStream<SharedObservationInput>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        raw.continuation.onTermination = { [weak self] _ in self?.remove(token) }
        let added = state.withLock { state in
            guard !state.closed else { return false }
            state.subscribers[token] = raw.continuation; return true
        }
        guard added else { raw.continuation.finish(); pair.continuation.finish(); return nil }
        counters.subscriber(1)
        let worker = Task { [weak self] in
            defer { pair.continuation.finish() }
            for await input in raw.stream {
                guard !Task.isCancelled else { break }
                switch self?.deliveryStatus(token) ?? .closed {
                case .closed: return
                case .accountChanged: pair.continuation.yield(.failure(GraphObservationError.accountChanged)); return
                case .active: break
                }
                let value: GraphQueryState<Model>
                switch input {
                case .failure(let error): value = .failure(error)
                case .snapshot(let output, let view):
                    do {
                        let result = try GraphQueryResult(items: output.records.map { try $0.decoded(as: Model.self) },
                            nextCursor: output.cursor, view: view, diagnostics: output.diagnostics)
                        value = .value(result)
                    } catch { value = .failure(error) }
                }
                guard !Task.isCancelled else { break }
                switch self?.deliveryStatus(token) ?? .closed {
                case .closed: return
                case .accountChanged: pair.continuation.yield(.failure(GraphObservationError.accountChanged)); return
                case .active: pair.continuation.yield(value)
                }
            }
        }
        control.install(worker, refresh: { [weak self] in self?.requestRefresh() }, finish: { [self] in
            remove(token); pair.continuation.finish()
        })
        requestRefresh()
        return GraphObservation(stream: pair.stream, control: control)
    }
    private func deliveryStatus(_ token: UUID) -> SharedDeliveryStatus {
        state.withLock { state in
            if state.accountChanged { return .accountChanged }
            return !state.closed && state.subscribers[token] != nil ? .active : .closed
        }
    }
    func start() {
        let registration = registration, graph = graph, query = query, counters = counters, beforeRead = beforeRead
        let task = Task { [weak self] in
            do {
                let feed = try await registration.value
                defer { feed.cancel() }
                self?.installSource(refresh: feed.refresh, cancel: feed.cancel)
                // Enter next() even if already cancelled, so the source subscription is released.
                for await invalidation in feed.stream {
                    guard !Task.isCancelled else { break }
                    if case .accountChange = invalidation.reason {
                        self?.finish(.failure(GraphObservationError.accountChanged)); return
                    }
                    // A late join cannot receive a query begun before its registration.
                    let targets = self?.targets() ?? []
                    guard !targets.isEmpty else { break }
                    do {
                        await beforeRead()
                        try Task.checkCancellation()
                        counters.execution()
                        let (output, view) = try await graph.sharedObservationOutput(query)
                        try await graph.observationAdmission()
                        guard !Task.isCancelled else { break }
                        if feed.stream.accountHasChanged {
                            self?.finish(.failure(GraphObservationError.accountChanged)); return
                        }
                        self?.offer(.snapshot(output, view), to: targets)
                    } catch is CancellationError { break }
                    catch {
                        if case GraphStoreError.closed = error { break }
                        guard !Task.isCancelled else { break }
                        if feed.stream.accountHasChanged {
                            self?.finish(.failure(GraphObservationError.accountChanged)); return
                        }
                        self?.offer(.failure(error), to: targets)
                    }
                }
                self?.finish()
            } catch { self?.finish(.failure(error)) }
        }
        let cancelled = state.withLock { state in
            guard !state.closed else { return true }
            state.worker = task; return false
        }
        if cancelled { task.cancel() }
    }
    private func installSource(refresh: @escaping @Sendable () -> Void, cancel: @escaping @Sendable () -> Void) {
        let installed = state.withLock { state in
            guard !state.closed else { return false }
            state.refresh = refresh; state.cancelSource = cancel; return true
        }
        if installed { refresh() } else { cancel() }
    }
    private func requestRefresh() { state.withLock { $0.refresh }?() }
    private func targets() -> Set<UUID> { state.withLock { Set($0.subscribers.keys) } }
    private func offer(_ value: SharedObservationInput, to targets: Set<UUID>) {
        let continuations = state.withLock { state in targets.compactMap { state.subscribers[$0] } }
        for continuation in continuations { continuation.yield(value) }
    }
    private func remove(_ token: UUID) {
        let removed = state.withLock { $0.subscribers.removeValue(forKey: token) }
        guard let removed else { return }
        counters.subscriber(-1)
        removed.finish()
        finish(ifEmpty: true)
    }
    private func finish(_ terminal: SharedObservationInput? = nil, ifEmpty: Bool = false) {
        let work = state.withLock { state -> State? in
            guard !state.closed, !ifEmpty || state.subscribers.isEmpty else { return nil }
            let previous = state
            if case .failure(let error)? = terminal, error is GraphObservationError { state.accountChanged = true }
            state.closed = true; state.subscribers = [:]; state.worker = nil; state.refresh = nil; state.cancelSource = nil
            return previous
        }
        guard let work else { return }
        counters.group(-1); counters.subscriber(-work.subscribers.count)
        work.cancelSource?(); work.worker?.cancel()
        for continuation in work.subscribers.values {
            if let terminal { continuation.yield(terminal) }
            continuation.finish()
        }
        retired()
    }
    deinit { finish() }
}
