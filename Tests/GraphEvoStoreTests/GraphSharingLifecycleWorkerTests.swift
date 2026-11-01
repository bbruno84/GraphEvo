import CloudKit
import Foundation
import Testing
@testable import GraphEvoStore
@testable import GraphEvo

private actor LifecycleWorkBus {
    let ids = [GraphID(), GraphID()]
    var calls: [GraphID: Int] = [:]
    var failure: (any Error)?
    var generation = UUID()
    func replaceGeneration() { generation = UUID() }
    func setFailure(_ error: (any Error)?) { failure = error }
    func step(_ id: GraphID) -> (any Error)? { calls[id, default: 0] += 1; return id == ids[0] ? failure : nil }
}
private actor LifecycleStepGate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waits: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true; let values = arrivals; arrivals = []; for value in values { value.resume() }
        if !released { await withCheckedContinuation { waits.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; let values = waits; waits = []; for value in values { value.resume() } }
}
@Suite(.timeLimit(.minutes(1))) struct GraphSharingLifecycleWorkerTests {
    private func wait(_ test: @escaping () async -> Bool) async throws {
        for _ in 0..<5000 { if await test() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Lifecycle worker did not settle")
    }
    @Test func retryAfterActivityAndHintsRespectBackoffAndOtherGraphProgresses() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), ids = await bus.ids
        await bus.setFailure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 40.0]))
        let worker = GraphSharingLifecycleWorker(clock: clock.value, inventory: { ids }, step: { await bus.step($0) })
        await worker.setActive(true, revision: 1)
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[ids[1]]; return idle && count == 1 }
        #expect(await worker.retryDeadline(ids[0]) == 40)
        await worker.request(ids, explicit: true)
        try await wait { await worker.diagnosticIdle }
        #expect(await bus.calls[ids[0]] == 1)
        await worker.setActive(false, revision: 2)
        clock.advance(39)
        await worker.setActive(true, revision: 3)
        try await wait { await worker.diagnosticIdle }
        #expect(await bus.calls[ids[0]] == 1)
        clock.advance(1)
        try await wait { let count = await bus.calls[ids[0]]; let idle = await worker.diagnosticIdle; return count == 2 && idle }
        #expect((await bus.calls[ids[1]] ?? 0) >= 2)
        await worker.shutdown()
    }
    @Test func permanentErrorsNeedExplicitRetryAndInactivityDoesNoNewWork() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), ids = await bus.ids
        await bus.setFailure(CKError(.quotaExceeded))
        let worker = GraphSharingLifecycleWorker(clock: clock.value, inventory: { ids }, step: { await bus.step($0) })
        await worker.setActive(true, revision: 1)
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[ids[0]]; return idle && count == 1 }
        clock.advance(60)
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[ids[1]]; return idle && count == 2 }
        #expect(await bus.calls[ids[0]] == 1)
        await bus.setFailure(nil)
        await worker.request([ids[0]], explicit: true)
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[ids[0]]; return idle && count == 2 }
        await worker.setActive(false, revision: 2)
        clock.advance(300)
        await worker.request(ids, explicit: true)
        #expect(await bus.calls[ids[0]] == 2)
        await worker.shutdown()
    }
    @Test func hintDuringSuccessfulTurnRunsAgainWithoutWaitingForPeriodicTimer() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), gate = LifecycleStepGate(), id = GraphID()
        let worker = GraphSharingLifecycleWorker(clock: clock.value, inventory: { [id] }, step: { _ in
            _ = await bus.step(id)
            await gate.enter()
            return nil
        })
        await worker.setActive(true, revision: 1)
        await gate.wait()
        await worker.request([id])
        await gate.release()
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[id]; return idle && count == 2 }
        #expect(clock.now == 0)
        #expect(await bus.calls[id] == 2)
        #expect(await worker.retryDeadline(id) == 60)
        await worker.shutdown()
    }

    @Test func replacementGenerationDoesNotInheritOldFailureOrBackoff() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), gate = LifecycleStepGate()
        let id = bus.ids[0]
        let worker = GraphSharingLifecycleWorker(clock: clock.value, generation: { _ in await bus.generation }, inventory: { [id] }, step: { _ in
            let failure = await bus.step(id)
            await gate.enter()
            return failure
        })
        await bus.setFailure(CKError(.quotaExceeded))
        await worker.setActive(true, revision: 1)
        await gate.wait()
        await bus.replaceGeneration(); await bus.setFailure(nil)
        await worker.request([id])
        await gate.release()
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[id]; return idle && count == 2 }
        #expect(await worker.retryDeadline(id) == 60)
        // A later replacement also clears an already recorded permanent failure.
        await bus.setFailure(CKError(.quotaExceeded)); await worker.request([id])
        try await wait { await worker.retryDeadline(id) == .infinity }
        await bus.replaceGeneration(); await bus.setFailure(nil); await worker.request([id])
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[id]; return idle && count == 4 }
        #expect(clock.now == 0)
        await worker.shutdown()
    }

    @Test func inactivityDuringGenerationLookupDoesNotAdmitAnotherTurn() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), gate = LifecycleStepGate(), id = GraphID(), generation = UUID()
        let worker = GraphSharingLifecycleWorker(clock: clock.value, generation: { _ in
            await gate.enter(); return generation
        }, inventory: { [id] }, step: { await bus.step($0) })
        await worker.setActive(true, revision: 1)
        await gate.wait()
        await worker.setActive(false, revision: 2)
        await gate.release()
        await worker.shutdown()
        #expect(await bus.calls.isEmpty)
    }

    @Test func hintDuringInFlightFailureDoesNotBypassResultingBackoff() async throws {
        let clock = AutomaticTestClock(), bus = LifecycleWorkBus(), gate = LifecycleStepGate(), id = GraphID()
        await bus.setFailure(CKError(.networkUnavailable))
        let worker = GraphSharingLifecycleWorker(clock: clock.value, inventory: { [id] }, step: { _ in
            await gate.enter()
            _ = await bus.step(id)
            return CKError(.networkUnavailable)
        })
        await worker.setActive(true, revision: 1)
        await gate.wait()
        await worker.request([id], explicit: true)
        await gate.release()
        try await wait { await worker.diagnosticIdle }
        #expect(await worker.retryDeadline(id) == 5)
        clock.advance(4)
        await worker.request([id])
        try await wait { await worker.diagnosticIdle }
        #expect(await bus.calls[id] == 1)
        clock.advance(1)
        try await wait { let idle = await worker.diagnosticIdle; let count = await bus.calls[id]; return idle && count == 2 }
        await worker.shutdown()
    }
}
