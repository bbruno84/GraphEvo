import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

/// Lock-protected virtual time; cancellation and wake delivery never run under the lock.
final class AutomaticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var sleepers: [UUID: (Double, CheckedContinuation<Void, any Error>)] = [:]
    var now: Double { lock.withLock { time } }
    var value: GraphAutomaticClock {
        .init(now: { self.now }, sleep: { try await self.sleep($0) }, jitter: { 1 })
    }
    private func sleep(_ seconds: Double) async throws {
        let token = UUID(), deadline = seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let result: Int = lock.withLock {
                    if Task.isCancelled { return 1 }
                    if deadline <= time { return 2 }
                    sleepers[token] = (deadline, c); return 0
                }
                if result == 1 { c.resume(throwing: CancellationError()) }
                if result == 2 { c.resume() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.sleepers.removeValue(forKey: token)?.1 }
            waiter?.resume(throwing: CancellationError())
        }
    }
    func advance(_ seconds: Double) {
        let ready = lock.withLock {
            time += seconds
            let values = sleepers.filter { $0.value.0 <= time }
            for id in values.keys { sleepers.removeValue(forKey: id) }
            return values.values.map(\.1)
        }
        for waiter in ready { waiter.resume() }
    }
}

private actor AutomaticGate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waits: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true; let ready = arrivals; arrivals = []; for c in ready { c.resume() }
        if !released { await withCheckedContinuation { waits.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; let ready = waits; waits = []; for c in ready { c.resume() } }
}

private actor AutomaticBus {
    var inventory: [GraphAutomaticGraph]
    let hubs: [GraphID: StoreInvalidationHub]
    var fetches: [(GraphCloudScope, Set<GraphID>)] = []
    var turns: [GraphID] = []
    var remaining: [GraphID: Int] = [:]
    var failures: [GraphID: [GraphCloudSendReport]] = [:]
    var fetchFailure: NSError?
    var sticky: GraphCloudError?
    var gate: AutomaticGate?
    init(_ count: Int = 2) {
        inventory = (0..<count).map { _ in .init(id: GraphID(), generation: UUID(), scope: .private, paused: false) }
        hubs = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, StoreInvalidationHub()) })
    }
    func fetch(_ scope: GraphCloudScope, _ ids: Set<GraphID>) async throws {
        fetches.append((scope, ids))
        if let fetchFailure { throw fetchFailure }
    }
    func turn(_ graph: GraphAutomaticGraph) async -> (GraphCloudSendReport, Int) {
        turns.append(graph.id)
        if let gate { await gate.enter() }
        if !(failures[graph.id] ?? []).isEmpty {
            return (failures[graph.id]!.removeFirst(), remaining[graph.id] ?? 0)
        }
        let count = remaining[graph.id] ?? 0
        remaining[graph.id] = max(0, count - 100)
        return (.init(succeeded: min(count, 100), failures: [], cleanupPending: false, transportError: nil), remaining[graph.id]!)
    }
    nonisolated var driver: GraphAutomaticDriver {
        .init(inventory: { await self.inventory }, subscribe: { graph in
            self.hubs[graph.id]!.subscribe(owner: graph.generation, localCommitsOnly: true)
        }, fetch: { try await self.fetch($0, $1) }, turn: { await self.turn($0) }, sessionFailure: { await self.sticky })
    }
    func fail(_ id: GraphID, reports: [GraphCloudSendReport]) { failures[id] = reports }
    func backlog(_ id: GraphID, _ count: Int) { remaining[id] = count }
    func block(_ gate: AutomaticGate?) { self.gate = gate }
    func setFetchFailure(_ error: NSError?) { fetchFailure = error }
    func setSticky(_ error: GraphCloudError?) { sticky = error }
    func pause(_ index: Int, _ value: Bool) {
        let old = inventory[index]
        inventory[index] = .init(id: old.id, generation: old.generation, scope: old.scope, paused: value)
    }
    func replace(_ index: Int) {
        let old = inventory[index]
        inventory[index] = .init(id: old.id, generation: UUID(), scope: old.scope, paused: false)
    }
    func moveToShared(_ index: Int) {
        let old = inventory[index]
        inventory[index] = .init(id: old.id, generation: old.generation, scope: .shared, paused: false)
    }
    func hint(_ id: GraphID, author: String? = "GraphEvo.v2.local") { hubs[id]!.publish(.contextSave, transactionAuthor: author) }
}

@Suite(.timeLimit(.minutes(2))) struct GraphAutomaticSynchronizationTests {
    private func wait(_ condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw GraphCloudError.invalidState }
            await Task.yield()
        }
    }
    private func settle(_ scheduler: GraphAutomaticSynchronizer) async throws { try await wait { await scheduler.diagnosticIdle } }

    @Test func activationPeriodicReconciliationAndNoMetadataFeedback() async throws {
        let bus = AutomaticBus(), clock = AutomaticTestClock(), scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.changedInventory()
        #expect(await bus.fetches.isEmpty)
        await scheduler.setActive(true); try await settle(scheduler)
        let id = await bus.inventory[0].id, initial = await bus.turns.count
        #expect(initial == 4)
        #expect(await bus.fetches.count == 1)
        await bus.hint(id, author: "GraphEvo.v2.import")
        await bus.hint(id, author: "GraphEvo.v2.syncMetadata")
        clock.advance(59); await scheduler.request(scope: .shared); try await settle(scheduler)
        #expect(await bus.turns.count == initial)
        clock.advance(1)
        try await wait { await bus.fetches.count == 2 }; try await settle(scheduler)
        #expect(await bus.turns.count == initial + 2)
        await scheduler.shutdown()
    }

    @Test func localDebounceHasMaximumLatencyAndUnknownAuthorsAreHints() async throws {
        let bus = AutomaticBus(1), clock = AutomaticTestClock(), scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); try await settle(scheduler)
        let graph = await bus.inventory[0], initial = await bus.turns.count
        for index in 0..<5 {
            await bus.hint(graph.id, author: index == 0 ? nil : "GraphEvo.v2.local")
            let expected = min(clock.now + 0.25, 1)
            try await wait { guard let due = await scheduler.diagnosticDeadline(graph.id) else { return false }; return abs(due - expected) < 0.00001 }
            if index < 4 { clock.advance(0.2) }
        }
        clock.advance(0.19)
        #expect(await bus.turns.count == initial)
        clock.advance(0.01)
        try await wait { await bus.turns.count > initial }; try await settle(scheduler)
        #expect(await bus.fetches.count == 1)
        await scheduler.shutdown()
    }

    @Test func backlogRoundRobinAndIndependentScopes() async throws {
        let bus = AutomaticBus(3), clock = AutomaticTestClock()
        await bus.moveToShared(2)
        let graphs = await bus.inventory
        await bus.backlog(graphs[0].id, 250); await bus.backlog(graphs[1].id, 150)
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); try await settle(scheduler)
        let turns = await bus.turns.filter { $0 != graphs[2].id }
        #expect(turns.count == 5 && Set(turns.prefix(2)).count == 2)
        #expect(await bus.fetches.count == 2)
        await scheduler.shutdown()
    }

    @Test func retryAfterAndNewHintsDoNotBypassBackoff() async throws {
        let bus = AutomaticBus(), clock = AutomaticTestClock(), id = await bus.inventory[0].id
        let network = NSError(domain: "CKErrorDomain", code: 4)
        await bus.fail(id, reports: [.init(succeeded: 0, failures: [], cleanupPending: false, transportError: network, retryAfter: 90)])
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); try await settle(scheduler)
        #expect(try await scheduler.status(id).phase == .waitingRetry)
        #expect(try await scheduler.status(id).retryAfter == 90)
        await scheduler.request(explicit: true)
        clock.advance(60); try await settle(scheduler)
        #expect(await bus.turns.filter { $0 == id }.count == 1)
        clock.advance(30)
        try await wait { await bus.turns.filter { $0 == id }.count >= 2 }; try await settle(scheduler)
        #expect(try await scheduler.status(id).phase == .idle)
        await scheduler.shutdown()
    }

    @Test func busyWaitsAndPermanentFailuresAreGraphScoped() async throws {
        let bus = AutomaticBus(), clock = AutomaticTestClock(), graphs = await bus.inventory
        await bus.fail(graphs[0].id, reports: [
            .init(succeeded: 0, failures: [], cleanupPending: false, transportError: GraphCloudError.busy),
            .init(succeeded: 0, failures: [.init(recordName: "bad", code: 25)], cleanupPending: false, transportError: nil)
        ])
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); try await settle(scheduler)
        #expect(await bus.turns.filter { $0 == graphs[0].id }.count == 1)
        clock.advance(1)
        try await wait { try await scheduler.status(graphs[0].id).phase == .blocked }
        await scheduler.request(scope: .private)
        clock.advance(60); try await settle(scheduler)
        #expect(await bus.turns.filter { $0 == graphs[0].id }.count == 2)
        #expect(await bus.turns.filter { $0 == graphs[1].id }.count >= 2)
        await scheduler.request(explicit: true); try await settle(scheduler)
        #expect(try await scheduler.status(graphs[0].id).phase == .idle)
        await scheduler.shutdown()
    }

    @Test func pauseInactivityAndGenerationChangesRetainWork() async throws {
        let bus = AutomaticBus(), clock = AutomaticTestClock(), scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await bus.pause(0, true)
        await scheduler.setActive(true); try await settle(scheduler)
        let graphs = await bus.inventory
        let firstFetch = await bus.fetches[0]
        #expect(firstFetch.1 == [graphs[1].id])
        #expect(try await scheduler.status(graphs[0].id).phase == .suspended)
        await bus.hint(graphs[0].id); clock.advance(1)
        await scheduler.setActive(false); let before = await bus.fetches.count
        clock.advance(120); await scheduler.request(); #expect(await bus.fetches.count == before)
        await bus.pause(0, false); await bus.replace(0)
        await scheduler.setActive(true); try await settle(scheduler)
        #expect(await bus.turns.contains(graphs[0].id))
        #expect(await bus.fetches.last?.1 == Set(graphs.map(\.id)))
        await scheduler.shutdown()
    }

    @Test func admittedTurnDrainsWhileInactiveAndStickyAccountDoesNotReset() async throws {
        let bus = AutomaticBus(1), clock = AutomaticTestClock(), gate = AutomaticGate()
        await bus.block(gate)
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); await gate.wait()
        await scheduler.setActive(false)
        await gate.release(); try await settle(scheduler)
        let id = await bus.inventory[0].id
        #expect(try await scheduler.status(id).phase == .suspended)
        await bus.setSticky(.accountChanged)
        await scheduler.setActive(true); try await settle(scheduler)
        #expect(try await scheduler.status(id).phase == .blocked)
        let before = await bus.fetches.count
        await scheduler.request(explicit: true); clock.advance(600)
        #expect(await bus.fetches.count == before)
        await scheduler.shutdown()
    }

    @Test func exponentialRetrySequenceCapsAndSuccessResetsIt() async throws {
        let bus = AutomaticBus(1), clock = AutomaticTestClock(), id = await bus.inventory[0].id
        let failure = GraphCloudSendReport(succeeded: 0, failures: [], cleanupPending: false,
                                          transportError: NSError(domain: "CKErrorDomain", code: 7))
        await bus.fail(id, reports: Array(repeating: failure, count: 7))
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true)
        for (index, delay) in [5.0, 15, 30, 60, 120, 300, 300].enumerated() {
            try await wait { await bus.turns.count == index + 1 }; try await settle(scheduler)
            #expect(try await scheduler.status(id).retryAfter == delay)
            clock.advance(delay)
        }
        try await wait { await bus.turns.count >= 8 }; try await settle(scheduler)
        #expect(try await scheduler.status(id).phase == .idle)
        await bus.fail(id, reports: [failure]); await scheduler.request()
        try await wait { try await scheduler.status(id).phase == .waitingRetry }
        #expect(try await scheduler.status(id).retryAfter == 5)
        await scheduler.shutdown()
    }

    @Test func filterPrecedesBufferingAndRetainsQueryInvalidations() async throws {
        let hub = StoreInvalidationHub(), owner = UUID()
        let local = hub.subscribe(owner: owner, localCommitsOnly: true)
        let queries = hub.subscribe(owner: owner)
        var changes = local.stream.makeAsyncIterator(), query = queries.stream.makeAsyncIterator()
        _ = await changes.next(); _ = await query.next()
        hub.publish(.contextSave, transactionAuthor: "GraphEvo.v2.local")
        hub.publish(.contextSave, transactionAuthor: "GraphEvo.v2.import")
        hub.publish(.contextSave, transactionAuthor: "GraphEvo.v2.syncMetadata")
        hub.publish(.storeChange)
        #expect(await changes.next()?.reason == .contextSave)
        #expect(await query.next()?.reason == .storeChange)
        hub.publish(.accountChange)
        #expect(await changes.next()?.reason == .accountChange)
        local.cancel(); queries.cancel()
        #expect(hub.subscriberCount == 0)
    }

    @Test func mixedPartialFailureBlocksRatherThanRetryingItsPermanentPart() async throws {
        let bus = AutomaticBus(), clock = AutomaticTestClock(), id = await bus.inventory[0].id
        await bus.fail(id, reports: [.init(succeeded: 1, failures: [
            .init(recordName: "temporary", code: 7), .init(recordName: "quota", code: 25)
        ], cleanupPending: false, transportError: NSError(domain: "CKErrorDomain", code: 2))])
        let scheduler = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        await scheduler.setActive(true); try await settle(scheduler)
        #expect(try await scheduler.status(id).phase == .blocked)
        #expect(try await scheduler.status(id).failure == "cloud:25")
        clock.advance(600); await scheduler.request(); try await settle(scheduler)
        #expect(await bus.turns.filter { $0 == id }.count == 1)
        await scheduler.shutdown()
    }

    @Test func idleSchedulerDoesNotRetainItselfThroughTimerOrFeed() async throws {
        let bus = AutomaticBus(1), clock = AutomaticTestClock()
        var scheduler: GraphAutomaticSynchronizer? = GraphAutomaticSynchronizer(driver: bus.driver, clock: clock.value)
        weak var reference = scheduler
        await scheduler!.setActive(true); try await settle(scheduler!)
        scheduler = nil
        try await wait { reference == nil }
        #expect(bus.hubs.values.allSatisfy { $0.subscriberCount == 0 })
    }
}
