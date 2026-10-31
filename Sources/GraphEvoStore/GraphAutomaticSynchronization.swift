import CloudKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package struct GraphAutomaticSyncStatus: Sendable, Equatable {
    package enum Phase: Sendable { case suspended, idle, running, waitingRetry, blocked }
    package let phase: Phase
    package let retryAfter: TimeInterval?
    /// Payload-free diagnostic; never an account, path or native error description.
    package let failure: String?
    package let pendingWork: Bool
}

struct GraphAutomaticClock: Sendable {
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double
    static var live: Self {
        let origin = ContinuousClock.now
        return Self(now: {
            let value = origin.duration(to: .now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }, sleep: { try await ContinuousClock().sleep(until: origin.advanced(by: .seconds($0))) }, jitter: { Double.random(in: 0.8...1.2) })
    }
}

struct GraphAutomaticGraph: Sendable, Equatable {
    let id: GraphID
    let generation: UUID
    let scope: GraphCloudScope
    let paused: Bool
}

struct GraphAutomaticDriver: Sendable {
    let inventory: @Sendable () async throws -> [GraphAutomaticGraph]
    let subscribe: @Sendable (GraphAutomaticGraph) async throws -> StoreInvalidationFeed
    let fetch: @Sendable (GraphCloudScope, Set<GraphID>) async throws -> Void
    let turn: @Sendable (GraphAutomaticGraph) async throws -> (GraphCloudSendReport, Int)
    let sessionFailure: @Sendable () async -> GraphCloudError?
}

/// A scheduler of hints only. Persistent History, inbox and receipts own all durable work.
actor GraphAutomaticSynchronizer {
    private struct GraphWork {
        var graph: GraphAutomaticGraph
        let feed: StoreInvalidationFeed
        var listener: Task<Void, Never>?
        var needsInitialTurn = true
        var dirty = true
        var firstEdit: TimeInterval?
        var due: TimeInterval = 0
        var retryAt: TimeInterval = 0
        var failures = 0
        var blocked: String?
        var lastFailure: String?
        var running = false
    }
    private struct Lane {
        var task: Task<Void, Never>?
        var fetching = Set<GraphID>()
        var needsFetch = true
        var retryAt: TimeInterval = 0
        var failures = 0
        var blocked: String?
        var lastFailure: String?
        var last: GraphID?
    }
    private let driver: GraphAutomaticDriver
    private let clock: GraphAutomaticClock
    private var active = false
    private var stopped = false
    private var stickyFailure = false
    private var refreshing = false
    private var refreshNeeded = false
    private var graphs: [GraphID: GraphWork] = [:]
    private var lanes: [GraphCloudScope: Lane] = [:]
    private var timer: Task<Void, Never>?
    private var timerID = UUID()
    private var nextReconciliation: TimeInterval = 0
    private var observers: [GraphID: [UUID: AsyncStream<GraphAutomaticSyncStatus>.Continuation]] = [:]

    init(driver: GraphAutomaticDriver, clock: GraphAutomaticClock) { self.driver = driver; self.clock = clock }

    deinit {
        timer?.cancel()
        for value in graphs.values { value.listener?.cancel(); value.feed.cancel() }
        for values in observers.values { for observer in values.values { observer.finish() } }
    }

    func setActive(_ value: Bool) async {
        guard !stopped else { return }
        let changed = active != value
        active = value
        if changed && value {
            nextReconciliation = clock.now() + 60
            await changedInventory()
            request()
        }
        publishAll(); pump()
    }

    func changedInventory() async {
        guard !stopped else { return }
        refreshNeeded = true
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; publishAll(); pump() }
        while refreshNeeded && !stopped {
            refreshNeeded = false
            do {
                let inventory = try await driver.inventory()
                guard !stopped else { return }
                let current = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
                for (id, old) in graphs where current[id]?.generation != old.graph.generation {
                    old.listener?.cancel(); old.feed.cancel(); graphs.removeValue(forKey: id)
                    if current[id] == nil {
                        for observer in observers.removeValue(forKey: id)?.values ?? [:].values { observer.finish() }
                    }
                }
                for graph in inventory {
                    if var existing = graphs[graph.id] {
                        if existing.graph.paused && !graph.paused { existing.dirty = true; existing.due = clock.now(); existing.firstEdit = nil
                            lanes[graph.scope, default: Lane()].needsFetch = true }
                        existing.graph = graph; graphs[graph.id] = existing
                    } else {
                        let feed = try await driver.subscribe(graph)
                        guard !stopped else { feed.cancel(); return }
                        var work = GraphWork(graph: graph, feed: feed)
                        work.listener = Task { [weak self] in
                            for await signal in feed.stream {
                                guard !Task.isCancelled else { break }
                                if signal.reason != .initial { await self?.localChange(graph) }
                            }
                        }
                        graphs[graph.id] = work
                        lanes[graph.scope, default: Lane()].needsFetch = true
                    }
                }
            } catch {
                // A concurrent final close can invalidate inventory/subscription. Its lifecycle hint refreshes it.
                if let failure = await driver.sessionFailure() { blockSession(failure) }
            }
        }
    }

    func request(scope: GraphCloudScope? = nil, explicit: Bool = false) {
        guard !stopped else { return }
        for id in graphs.keys where scope == nil || graphs[id]!.graph.scope == scope {
            graphs[id]!.dirty = true; graphs[id]!.due = clock.now(); graphs[id]!.firstEdit = nil
            if explicit && !stickyFailure { graphs[id]!.blocked = nil }
        }
        for key in lanes.keys where scope == nil || key == scope {
            lanes[key]!.needsFetch = true
            if explicit && !stickyFailure { lanes[key]!.blocked = nil }
        }
        publishAll(); pump()
    }

    private func localChange(_ graph: GraphAutomaticGraph) {
        guard !stopped, var work = graphs[graph.id], work.graph.generation == graph.generation else { return }
        let now = clock.now()
        let first = work.firstEdit ?? now
        work.firstEdit = first
        work.due = min(now + 0.25, first + 1)
        work.dirty = true
        graphs[graph.id] = work; publish(graph.id); pump()
    }

    func status(_ id: GraphID) throws -> GraphAutomaticSyncStatus {
        guard let work = graphs[id] else { throw GraphStoreError.missingGraph }
        let lane = lanes[work.graph.scope] ?? Lane()
        func value(_ phase: GraphAutomaticSyncStatus.Phase, delay: TimeInterval? = nil, failure: String? = nil) -> GraphAutomaticSyncStatus {
            .init(phase: phase, retryAfter: delay, failure: failure,
                  pendingWork: work.dirty || lane.needsFetch || work.running || lane.fetching.contains(id))
        }
        if !active || work.graph.paused { return value(.suspended, failure: work.blocked ?? lane.blocked) }
        if let failure = work.blocked ?? lane.blocked { return value(.blocked, failure: failure) }
        if work.running || lane.fetching.contains(id) { return value(.running) }
        let delay = max(work.retryAt, lane.retryAt) - clock.now()
        if delay > 0 { return value(.waitingRetry, delay: delay, failure: work.lastFailure ?? lane.lastFailure) }
        return value(.idle)
    }

    func observe(_ id: GraphID) throws -> AsyncStream<GraphAutomaticSyncStatus> {
        let initial = try status(id), token = UUID()
        let pair = AsyncStream<GraphAutomaticSyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id, default: [:]][token] = pair.continuation
        pair.continuation.yield(initial)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id, token) } }
        return pair.stream
    }
    private func removeObserver(_ id: GraphID, _ token: UUID) { observers[id]?.removeValue(forKey: token) }
    private func publish(_ id: GraphID) {
        guard let value = try? status(id) else { return }
        for observer in observers[id]?.values ?? [:].values { observer.yield(value) }
    }
    private func publishAll() { for id in graphs.keys { publish(id) } }

    private func eligible(_ work: GraphWork) -> Bool { !work.graph.paused && work.blocked == nil }
    private func pump() {
        timer?.cancel(); timer = nil; timerID = UUID()
        guard active && !stopped else { return }
        let now = clock.now()
        if now >= nextReconciliation {
            nextReconciliation = now + 60
            for id in graphs.keys { graphs[id]!.dirty = true; graphs[id]!.due = now }
            for scope in lanes.keys { lanes[scope]!.needsFetch = true }
        }
        var wake = nextReconciliation
        for scope in lanes.keys {
            guard lanes[scope]!.task == nil, lanes[scope]!.blocked == nil else { continue }
            let work = graphs.values.filter { $0.graph.scope == scope && eligible($0) }
            guard !work.isEmpty else { continue }
            let candidates = work.map { max($0.retryAt, $0.dirty ? $0.due : .infinity) }
            let fetchDue = lanes[scope]!.needsFetch ? (work.map(\.retryAt).min() ?? .infinity) : .infinity
            let due = max(lanes[scope]!.retryAt, min(fetchDue, candidates.min() ?? .infinity))
            if due <= now {
                lanes[scope]!.task = Task { [weak self] in await self?.run(scope) }
            } else { wake = min(wake, due) }
        }
        let id = timerID, clock = clock
        timer = Task { [weak self] in
            do { try await clock.sleep(wake); try Task.checkCancellation(); await self?.timerFired(id) }
            catch { }
        }
    }
    private func timerFired(_ id: UUID) { guard timerID == id else { return }; pump() }

    private func run(_ scope: GraphCloudScope) async {
        defer { lanes[scope]?.task = nil; publishAll(); pump() }
        guard active && !stopped else { return }
        let now = clock.now()
        let targets = graphs.values.filter { $0.graph.scope == scope && eligible($0) && $0.retryAt <= now }.map(\.graph)
        if lanes[scope]?.needsFetch == true && !targets.isEmpty && !targets.contains(where: { graphs[$0.id]?.needsInitialTurn == true }) {
            lanes[scope]!.needsFetch = false
            lanes[scope]!.fetching = Set(targets.map(\.id)); publishAll()
            defer { lanes[scope]!.fetching.removeAll() }
            do {
                try await driver.fetch(scope, Set(targets.map(\.id)))
                lanes[scope]!.failures = 0; lanes[scope]!.retryAt = 0; lanes[scope]!.lastFailure = nil
                for graph in targets where graphs[graph.id]?.graph.generation == graph.generation {
                    graphs[graph.id]!.dirty = true; graphs[graph.id]!.due = clock.now()
                }
            } catch {
                lanes[scope]!.needsFetch = true
                if let failure = await driver.sessionFailure() { blockSession(failure) }
                else { laneFailed(scope, error) }
                return
            }
        }
        guard active && !stopped else { return }
        let ready = graphs.values.filter {
            $0.graph.scope == scope && eligible($0) && $0.dirty && max($0.due, $0.retryAt) <= clock.now()
        }.map(\.graph).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        // Publish initial pending data before fetching a newly bound private zone.
        // This lets the existing send path create the zone without inventing a second zone writer.
        let initial = ready.filter { graphs[$0.id]?.needsInitialTurn == true }
        let ordered = initial.isEmpty ? ready : initial
        guard let graph = ordered.first(where: { $0.id.rawValue.uuidString > (lanes[scope]?.last?.rawValue.uuidString ?? "") }) ?? ordered.first else { return }
        lanes[scope]!.last = graph.id
        graphs[graph.id]!.dirty = false; graphs[graph.id]!.firstEdit = nil; graphs[graph.id]!.running = true
        publish(graph.id)
        do {
            let (report, pending) = try await driver.turn(graph)
            guard graphs[graph.id]?.graph.generation == graph.generation else { return }
            if let failure = await driver.sessionFailure() { blockSession(failure) }
            else if !report.failures.isEmpty {
                let errors = report.failures.map { NSError(domain: "CKErrorDomain", code: $0.code) }
                let error = errors.first(where: { !transient($0) }) ?? errors[0]
                graphFailed(graph, error, retryAfter: report.retryAfter)
            } else if let error = report.transportError { graphFailed(graph, error, retryAfter: report.retryAfter)
            } else if report.pendingRetry || report.cleanupPending {
                graphFailed(graph, GraphCloudError.transportUnavailable, retryAfter: report.retryAfter)
            } else {
                graphs[graph.id]!.failures = 0; graphs[graph.id]!.retryAt = 0; graphs[graph.id]!.lastFailure = nil
                if graphs[graph.id]!.needsInitialTurn { graphs[graph.id]!.needsInitialTurn = false; lanes[scope]!.needsFetch = true }
                if pending > 0 { graphs[graph.id]!.dirty = true; graphs[graph.id]!.due = clock.now() }
            }
        } catch {
            guard graphs[graph.id]?.graph.generation == graph.generation else { return }
            if let failure = await driver.sessionFailure() { blockSession(failure) }
            else { graphFailed(graph, error) }
        }
        if graphs[graph.id]?.graph.generation == graph.generation { graphs[graph.id]!.running = false }
    }

    private func retry(_ count: Int, advice: TimeInterval?) -> TimeInterval {
        let delays: [Double] = [5, 15, 30, 60, 120, 300]
        let jitter = min(1.2, max(0.8, clock.jitter()))
        let server = advice.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        return max(delays[min(count, delays.count - 1)] * jitter, server)
    }
    private func transient(_ error: any Error) -> Bool {
        if error as? GraphCloudError == .transportUnavailable { return true }
        let native = error as NSError
        return (native.domain == NSURLErrorDomain && [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1020].contains(native.code)) ||
            (native.domain == "CKErrorDomain" && [3, 4, 6, 7, 23].contains(native.code))
    }
    private func advice(_ error: any Error) -> TimeInterval? { (error as NSError).userInfo[CKErrorRetryAfterKey] as? Double }
    private func graphFailed(_ graph: GraphAutomaticGraph, _ error: any Error, retryAfter: TimeInterval? = nil) {
        guard var work = graphs[graph.id], work.graph.generation == graph.generation else { return }
        work.dirty = true; work.lastFailure = diagnostic(error)
        if error as? GraphCloudError == .graphPaused {
            // Inventory owns pause state. A pause/resume may already have crossed this failed admission.
            work.retryAt = max(work.retryAt, clock.now() + 1)
        } else if error as? GraphCloudError == .busy || error as? GraphSyncError == .busy {
            work.retryAt = max(work.retryAt, clock.now() + 1)
        } else if transient(error) {
            work.retryAt = clock.now() + retry(work.failures, advice: max(retryAfter ?? 0, advice(error) ?? 0)); work.failures += 1
        } else { work.blocked = diagnostic(error) }
        graphs[graph.id] = work
    }
    private func laneFailed(_ scope: GraphCloudScope, _ error: any Error) {
        lanes[scope]!.lastFailure = diagnostic(error)
        if error as? GraphCloudError == .busy { lanes[scope]!.retryAt = max(lanes[scope]!.retryAt, clock.now() + 1) }
        else if transient(error) {
            let count = lanes[scope]!.failures
            lanes[scope]!.retryAt = clock.now() + retry(count, advice: advice(error)); lanes[scope]!.failures += 1
        } else { lanes[scope]!.blocked = diagnostic(error) }
    }
    private func diagnostic(_ error: any Error) -> String {
        let value = error as NSError
        // Only fixed error families and numeric codes, never localizedDescription/userInfo.
        let family: String
        if error is GraphCloudError { family = "session:" }
        else if error is GraphStoreError { family = "store:" }
        else if error is GraphSyncError { family = "history:" }
        else if value.domain == "CKErrorDomain" { family = "cloud:" }
        else if value.domain == NSURLErrorDomain { family = "network:" }
        else { family = "local:" }
        return family + String(value.code)
    }
    private func blockSession(_ failure: GraphCloudError) {
        stickyFailure = true
        for scope in lanes.keys { lanes[scope]!.blocked = diagnostic(failure) }
    }

    func diagnosticDeadline(_ id: GraphID) -> TimeInterval? { graphs[id]?.dirty == true ? graphs[id]?.due : nil }
    var diagnosticIdle: Bool { lanes.values.allSatisfy { $0.task == nil } && graphs.values.allSatisfy { !$0.dirty || $0.graph.paused || $0.blocked != nil || lanes[$0.graph.scope]?.blocked != nil || $0.retryAt > clock.now() } }

    func shutdown() async {
        stopped = true; active = false; timer?.cancel(); timer = nil
        for work in graphs.values { work.listener?.cancel(); work.feed.cancel() }
        let tasks = lanes.values.compactMap(\.task)
        for task in tasks { await task.value }
        for values in observers.values { for observer in values.values { observer.finish() } }
        observers.removeAll(); graphs.removeAll()
    }
}
