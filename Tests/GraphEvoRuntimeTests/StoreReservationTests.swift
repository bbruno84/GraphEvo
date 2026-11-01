import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

private struct ReservationWriterGate: Sendable {
    let entered = LifecycleGate()
    let resume = DispatchSemaphore(value: 0)
    func block() throws {
        Task { await entered.enter() }
        guard resume.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
    }
}
@Suite(.timeLimit(.minutes(1))) struct StoreReservationTests {
    @Test func cancelledMaintenancePublishesRecoveryHint() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let restricted = AsyncStream<Void>.makeStream(), gate = ReservationWriterGate()
        await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(didRestrictWrites: { restricted.continuation.yield(()) }))
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Graph.sqlite"))), schema: fixtureSchema())
        let feed = try await handle.invalidationFeed()
        var hints = feed.stream.makeAsyncIterator()
        #expect(await hints.next()?.reason == .initial)
        let reader = Task { try await handle.read { _ in try gate.block() } }
        await gate.entered.waitForArrivals()
        let maintenance = Task { try await handle.reserveMaintenance() }
        var entered = restricted.stream.makeAsyncIterator(); _ = await entered.next()
        await #expect(throws: (any Error).self) { try await handle.read { _ in true } }
        maintenance.cancel()
        await #expect(throws: CancellationError.self) { try await maintenance.value }
        _ = try await handle.read { _ in true }
        feed.cancel()
        #expect(await hints.next()?.reason == .storeChange)
        #expect(await hints.next() == nil)
        gate.resume.signal(); try await reader.value
        try await handle.close(); restricted.continuation.finish()
    }

    @Test func reservationDrainsAlreadyQueuedWritersAndRefusesNewBodies() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let restricted = AsyncStream<Void>.makeStream(), queued = LifecycleGate(), gate = ReservationWriterGate()
        await queued.release(); await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() }, didRestrictWrites: { restricted.continuation.yield(()) }))
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Graph.sqlite"))), schema: fixtureSchema())
        let writer = Task { try await handle.transaction { _ in try gate.block() } }
        await gate.entered.waitForArrivals()
        let queuedWriter = Task { try await handle.transaction { _ in 2 } }
        await queued.waitForArrivals()
        let pausing = Task { try await handle.suspendWrites() }
        var events = restricted.stream.makeAsyncIterator(); _ = await events.next()
        await #expect { try await handle.transaction { _ in Issue.record("A refused body must not run") } } throws: {
            if case StoreRuntimeError.writesSuspended = $0 { return true }; return false
        }
        _ = try await handle.read { _ in true }
        gate.resume.signal(); try await writer.value; #expect(try await queuedWriter.value == 2)
        let hold = try await pausing.value
        await #expect(throws: (any Error).self) { try await handle.controlTransaction { _ in () } }
        await hold.release(); _ = try await handle.transaction { _ in true }
        restricted.continuation.finish(); try await handle.close()
    }
    @Test func cancellingOneReservationNeverReleasesAnotherAndKeepsTheOwner() async throws {
        let restricted = AsyncStream<Void>.makeStream(), gate = ReservationWriterGate()
        await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(didRestrictWrites: { restricted.continuation.yield(()) }))
        let config = StoreConfiguration(location: .inMemory(UUID()))
        let handle = try await registry.open(config, schema: fixtureSchema())
        let writer = Task { try await handle.transaction { _ in try gate.block() } }
        await gate.entered.waitForArrivals()
        var events = restricted.stream.makeAsyncIterator()
        let cancelled = Task { try await handle.suspendWrites() }; _ = await events.next()
        let retained = Task { try await handle.suspendWrites() }; _ = await events.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: (any Error).self) { try await handle.transaction { _ in () } }
        gate.resume.signal(); try await writer.value
        let hold = try await retained.value
        let oldID = try await handle.snapshot().runtimeID
        try await handle.close()
        let reopened = try await registry.open(config, schema: fixtureSchema())
        #expect(try await reopened.snapshot().runtimeID == oldID)
        await #expect(throws: (any Error).self) { try await reopened.transaction { _ in () } }
        await hold.release(); await hold.release()
        _ = try await reopened.transaction { _ in true }
        try await reopened.close()
        let fresh = try await registry.open(config, schema: fixtureSchema())
        #expect(try await fresh.snapshot().runtimeID != oldID)
        await hold.release(); _ = try await fresh.transaction { _ in true }
        try await fresh.close(); restricted.continuation.finish()
    }
    @Test func maintenanceDrainsReadersRejectsNewAdmissionAndCancellationRestoresAccess() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let restricted = AsyncStream<Void>.makeStream(), gate = ReservationWriterGate()
        await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(didRestrictWrites: { restricted.continuation.yield(()) }))
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Graph.sqlite"))), schema: fixtureSchema())
        let reader = Task { try await handle.read { _ in try gate.block() } }
        await gate.entered.waitForArrivals()
        let pending = Task { try await handle.reserveMaintenance() }
        var events = restricted.stream.makeAsyncIterator(); _ = await events.next()
        await #expect(throws: (any Error).self) { try await handle.read { _ in () } }
        pending.cancel(); await #expect(throws: CancellationError.self) { try await pending.value }
        _ = try await handle.read { _ in true }
        gate.resume.signal(); try await reader.value
        let all = try await handle.reserveMaintenance()
        await #expect(throws: (any Error).self) { try await handle.reserveMaintenance() }
        await #expect(throws: (any Error).self) { try await handle.nativeOperation { _ in () } }
        await all.release(); _ = try await handle.transaction { _ in true }; try await handle.close()
        restricted.continuation.finish()
    }

    @Test func terminalDataBlockCannotBeClearedByStaleMetadataOrReservationRelease() async throws {
        let registry = StoreRegistry(), handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let hold = try await handle.suspendWrites()
        try await handle.setDataAvailable(false, terminal: true)
        await #expect(throws: (any Error).self) { try await handle.setDataAvailable(true) }
        _ = try await handle.controlRead { _ in true }
        await hold.release()
        await #expect(throws: (any Error).self) { try await handle.read { _ in true } }
        try await handle.close()
    }

}
