import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreLifecycleTests {
    @Test func openingIsCoalescedBeforeNativeLoadingCompletes() async throws {
        let loading = LifecycleGate()
        let reserved = LifecycleGate()
        await reserved.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await loading.enter() },
                                                              didReserveHandle: { await reserved.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let handlesTask = Task {
            try await withThrowingTaskGroup(of: StoreHandle.self) { group in
                for _ in 0..<20 { group.addTask { try await registry.open(configuration, schema: schema) } }
                var handles: [StoreHandle] = []
                for try await handle in group { handles.append(handle) }
                return handles
            }
        }
        await reserved.waitForArrivals(20)
        #expect(await loading.count() <= 1)
        await loading.release()
        let handles = try await handlesTask.value
        #expect(await loading.count() == 1)
        for handle in handles { try await handle.close() }
    }

    @Test func cancellingOneOpeningWaiterKeepsTheOtherLeaseUsable() async throws {
        let loading = LifecycleGate(), reserved = LifecycleGate()
        await reserved.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await loading.enter() },
                                                              didReserveHandle: { await reserved.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let cancelled = Task { try await registry.open(configuration, schema: schema) }
        await reserved.waitForArrivals()
        let survivor = Task { try await registry.open(configuration, schema: schema) }
        await reserved.waitForArrivals(2)
        cancelled.cancel()
        await loading.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let handle = try await survivor.value
        _ = try await handle.snapshot()
        #expect(await loading.count() == 1)
        try await handle.close()
    }

    @Test func aCancelledOnlyWaiterReleasesItsOwnerBeforeRetry() async throws {
        let loading = LifecycleGate()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await loading.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let opening = Task { try await registry.open(configuration, schema: schema) }
        await loading.waitForArrivals()
        opening.cancel()
        await loading.release()
        await #expect(throws: CancellationError.self) { try await opening.value }
        let retry = try await registry.open(configuration, schema: schema)
        #expect(await loading.count() == 2)
        try await retry.close()
    }

    @Test func anAlreadyCancelledCallerDoesNotStartNativeLoading() async throws {
        let started = LifecycleGate()
        await started.release()
        let caller = LifecycleGate()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await started.enter() }))
        let opening = Task {
            await caller.enter()
            return try await registry.open(StoreConfiguration(location: .inMemory(UUID())), schema: graphSchema())
        }
        await caller.waitForArrivals()
        opening.cancel()
        await caller.release()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await started.count() == 0)
    }

    @Test func concurrentCloseAndReopenWaitForFinalDetachment() async throws {
        let detaching = LifecycleGate(), loading = LifecycleGate()
        await loading.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: { await loading.enter() },
                                                              beforeDetach: { await detaching.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let first = try await registry.open(configuration, schema: schema)
        let originalID = try await first.snapshot().runtimeID
        let close = Task { try await first.close() }
        await detaching.waitForArrivals()
        close.cancel()
        let secondClose = Task { try await first.close() }
        let reopening = Task { try await registry.open(configuration, schema: schema) }
        #expect(await loading.count() == 1)
        await detaching.release()
        try await close.value
        try await secondClose.value
        let second = try await reopening.value
        #expect(await loading.count() == 2)
        #expect(try await second.snapshot().runtimeID != originalID)
        try await first.close()
        _ = try await second.snapshot()
        try await second.close()
    }

    @Test func droppingTheLastHandleInitiatesResourceRelease() async throws {
        let detaching = LifecycleGate()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { await detaching.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        var first: StoreHandle? = try await registry.open(configuration, schema: schema)
        let originalID = try await first!.snapshot().runtimeID
        first = nil
        await detaching.waitForArrivals()
        await detaching.release()
        let next = try await registry.open(configuration, schema: schema)
        #expect(try await next.snapshot().runtimeID != originalID)
        try await next.close()
    }

    @Test func aFailedShutdownRetainsOwnershipAndItsFailureForOtherOpeners() async throws {
        struct NativeFailure: Error {}
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { throw NativeFailure() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let handle = try await registry.open(configuration, schema: graphSchema())
        await #expect(throws: StoreRuntimeError.self) { try await handle.close() }
        await #expect(throws: StoreRuntimeError.self) { try await handle.close() }
        await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: graphSchema()) }
    }

    @Test func finalCloseDrainsAnAdmittedNativeRead() async throws {
        let entered = LifecycleGate()
        await entered.release()
        let detaching = LifecycleGate()
        await detaching.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeDetach: { await detaching.enter() }))
        let handle = try await registry.open(StoreConfiguration(location: .inMemory(UUID())), schema: graphSchema())
        let resume = DispatchSemaphore(value: 0)
        let reading = Task {
            try await handle.read { _ in
                Task { await entered.enter() }
                return resume.wait(timeout: .now() + 5) == .success
            }
        }
        await entered.waitForArrivals()
        let closing = Task { try await handle.close() }
        #expect(await detaching.count() == 0)
        resume.signal()
        #expect(try await reading.value)
        try await closing.value
        #expect(await detaching.count() == 1)
        await #expect(throws: StoreRuntimeError.self) { try await handle.snapshot() }
    }

    @Test func sharedOpeningFailureReleasesEveryWaiterAndAllowsRetry() async throws {
        struct LoadFailure: Error {}
        let loading = LifecycleGate(), reserved = LifecycleGate()
        await reserved.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: {
            await loading.enter()
            if await loading.count() == 1 { throw LoadFailure() }
        }, didReserveHandle: { await reserved.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let attempts = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        do {
                            let handle = try await registry.open(configuration, schema: schema)
                            try await handle.close()
                            return false
                        } catch is LoadFailure { return true }
                        catch { return false }
                    }
                }
                var failures = 0
                for await failed in group where failed { failures += 1 }
                return failures
            }
        }
        await reserved.waitForArrivals(20)
        await loading.release()
        #expect(await attempts.value == 20)
        let retry = try await registry.open(configuration, schema: schema)
        #expect(await loading.count() == 2)
        _ = try await retry.snapshot()
        try await retry.close()
    }

    @Test func lateFailedWaitersCannotRemoveTheNewOpeningGeneration() async throws {
        struct LoadFailure: Error {}
        let firstLoad = LifecycleGate(), retryLoad = LifecycleGate()
        let started = LifecycleGate(), reserved = LifecycleGate()
        await started.release()
        await reserved.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(beforeLoad: {
            await started.enter()
            if await started.count() == 1 {
                await firstLoad.enter()
                throw LoadFailure()
            }
            await retryLoad.enter()
        }, didReserveHandle: { await reserved.enter() }))
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let schema = graphSchema()
        let attempts = Task {
            try await withThrowingTaskGroup(of: StoreHandle.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        do { return try await registry.open(configuration, schema: schema) }
                        catch is LoadFailure { return try await registry.open(configuration, schema: schema) }
                    }
                }
                var handles: [StoreHandle] = []
                for try await handle in group { handles.append(handle) }
                return handles
            }
        }
        await reserved.waitForArrivals(20)
        await firstLoad.release()
        await reserved.waitForArrivals(40)
        await retryLoad.release()
        let handles = try await attempts.value
        var ids = Set<UUID>()
        for handle in handles { ids.insert(try await handle.snapshot().runtimeID) }
        #expect(ids.count == 1)
        #expect(await started.count() == 2)
        for handle in handles { try await handle.close() }
    }
}
