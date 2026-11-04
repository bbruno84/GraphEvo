import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

private struct AccountBodyGate: Sendable {
    let entered = LifecycleGate()
    let resume = DispatchSemaphore(value: 0)
    func block() {
        Task { await entered.enter() }
        _ = resume.wait(timeout: .now() + 10)
    }
}
private func accountInsert(_ value: String, _ context: NSManagedObjectContext) {
    NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue(value, forKey: "value")
}
private func accountValues(_ context: NSManagedObjectContext) throws -> [String] {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RuntimeFixture")).compactMap { $0.value(forKey: "value") as? String }
}

@Suite(.timeLimit(.minutes(1))) struct StoreAccountAccessTests {
    @Test func admittedAndQueuedWritersCannotCrossIsolationEvenIfSameAccountResumes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let queued = LifecycleGate(); await queued.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() }))
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: fixtureSchema())
        let sibling = try await handle.newLease(), body = AccountBodyGate()
        let writer = Task { try await handle.transaction { context in accountInsert("first", context); body.block() } }
        await body.entered.waitForArrivals()
        let waiting = Task { try await sibling.transaction { context in accountInsert("queued", context) } }
        await queued.waitForArrivals()
        let control = try await handle.accountControl()
        control.update(.isolated(.signedOut), revision: 2)
        control.update(.available, revision: 3)
        body.resume.signal()
        await #expect { try await writer.value } throws: { if case StoreRuntimeError.accountIsolated = $0 { return true }; return false }
        await #expect { try await waiting.value } throws: { if case StoreRuntimeError.accountIsolated = $0 { return true }; return false }
        #expect(try await handle.read(accountValues).isEmpty)
        try await sibling.close(); try await handle.close()
    }

    @Test func asynchronousPreparationAndDetachedPermitsRemainInvalidAfterAnIdentityBoundary() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: fixtureSchema())
        let materializing = LifecycleGate(), permit = try await handle.accountPermit()
        let task = Task {
            try await handle.preparedControlTransaction(prepare: { context in accountInsert("pending", context); return 1 },
                materialize: { value, check in await materializing.enter(); try check(); return value },
                finish: { _, value in value })
        }
        await materializing.waitForArrivals()
        try await handle.setAccountStatus(.isolated(.differentAccount), revision: 2)
        await #expect { try await handle.read(accountValues) } throws: { if case StoreRuntimeError.accountIsolated = $0 { return true }; return false }
        try await handle.setAccountStatus(.available, revision: 3)
        #expect(throws: (any Error).self) { try permit.check() }
        await materializing.release()
        await #expect { try await task.value } throws: { if case StoreRuntimeError.accountIsolated = $0 { return true }; return false }
        #expect(try await handle.read(accountValues).isEmpty)
        try await handle.close()
    }

    @Test func staleAvailabilityCannotReopenIsolationAndOldFeedsStayTerminated() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: fixtureSchema())
        let old = try await handle.invalidationFeed(), control = try await handle.accountControl()
        control.update(.isolated(.signedOut), revision: 2)
        control.update(.available, revision: 1)
        #expect(try await handle.accountStatus() == .isolated(.signedOut))
        control.update(.available, revision: 3)
        #expect(old.stream.accountHasChanged)
        let fresh = try await handle.invalidationFeed()
        #expect(!fresh.stream.accountHasChanged)
        old.cancel(); fresh.cancel(); try await handle.close()
    }
}
