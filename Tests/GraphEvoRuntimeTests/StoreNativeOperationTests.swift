import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreNativeOperationTests {
    @Test func nativeOperationsHoldTheWriterGateAndDrainBeforeDetach() async throws {
        let native = LifecycleGate(), queued = LifecycleGate(), closing = LifecycleGate(), detached = LifecycleGate()
        await queued.release(); await closing.release(); await detached.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(didQueueWriter: { await queued.enter() },
            didBeginClose: { await closing.enter() }, beforeDetach: { await detached.enter() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let operation = Task { try await handle.nativeOperation { _ in await native.enter(); return 42 } }
        await native.waitForArrivals()
        let writer = Task { try await handle.transaction { _ in 7 } }
        await queued.waitForArrivals()
        let close = Task { try await handle.close() }
        await closing.waitForArrivals()
        #expect(await detached.count() == 0)
        await native.release()
        #expect(try await operation.value == 42)
        #expect(try await writer.value == 7)
        try await close.value
        #expect(await detached.count() == 1)
    }

    @Test func cancellingAQueuedNativeOperationDoesNotInvokeItsBody() async throws {
        let native = LifecycleGate(), queued = LifecycleGate(), invoked = LifecycleGate()
        await queued.release(); await invoked.release()
        let registry = StoreRegistry(hooks: StoreLifecycleHooks(didQueueWriter: { await queued.enter() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let first = Task { try await handle.nativeOperation { _ in await native.enter() } }
        await native.waitForArrivals()
        let cancelled = Task { try await handle.nativeOperation { _ in await invoked.enter() } }
        await queued.waitForArrivals()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await invoked.count() == 0)
        await native.release()
        try await first.value
        try await handle.close()
    }

    @Test func localAndCloudConfigurationsCannotShareTheSameOwner() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let registry = StoreRegistry()
        let handle = try await registry.open(.init(location: .sqlite(url)), schema: fixtureSchema())
        await #expect(throws: StoreRuntimeError.self) {
            try await registry.open(.init(location: .sqlite(url), cloudKitContainerIdentifier: "iCloud.example.test"), schema: fixtureSchema())
        }
        try await handle.close()
    }
}
