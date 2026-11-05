import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime

private func preparedValues(_ context: NSManagedObjectContext) throws -> [String] {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RuntimeFixture"))
        .compactMap { $0.value(forKey: "value") as? String }.sorted()
}
private func preparedInsert(_ value: String, _ context: NSManagedObjectContext) {
    NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context).setValue(value, forKey: "value")
}
private enum PreparationFailure: Error { case disk, finalize }
private struct PreparedCommitGate: Sendable {
    let entered = LifecycleGate()
    let resume = DispatchSemaphore(value: 0)
    func block() {
        Task { await entered.enter() }
        _ = resume.wait(timeout: .now() + 10)
    }
}

@Suite(.timeLimit(.minutes(1))) struct StorePreparedTransactionTests {
    @Test func filePhaseRetainsWriterAndPendingContextWhileSQLiteReadersAndOtherStoresProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filePhase = LifecycleGate(), queued = LifecycleGate()
        await queued.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() }))
        let config = StoreConfiguration(location: .sqlite(root.appendingPathComponent("Store.sqlite")))
        let handle = try await registry.open(config, schema: fixtureSchema())
        let other = try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Other.sqlite"))), schema: fixtureSchema())
        let preparing = Task {
            try await handle.preparedControlTransaction(prepare: { context in
                preparedInsert("prepared", context)
                return try preparedValues(context)
            }, materialize: { snapshot, check in
                #expect(snapshot == ["prepared"])
                await filePhase.enter(); try check()
                return "finished"
            }, finish: { context, value throws -> Int in
                #expect(try preparedValues(context) == ["prepared"])
                preparedInsert(value, context); return 42
            })
        }
        await filePhase.waitForArrivals()
        #expect(try await handle.read(preparedValues).isEmpty)
        try await other.transaction { preparedInsert("independent", $0) }
        #expect(try await other.read(preparedValues) == ["independent"])
        let writing = Task { try await handle.transaction { preparedInsert("later", $0) } }
        await queued.waitForArrivals()
        #expect(try await handle.read(preparedValues).isEmpty)
        await filePhase.release()
        #expect(try await preparing.value == 42)
        try await writing.value
        #expect(try await handle.read(preparedValues) == ["finished", "later", "prepared"])
        try await other.close(); try await handle.close()
    }

    @Test func fileAndFinalizationFailureRollbackBothNativePhases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: fixtureSchema())
        await #expect(throws: PreparationFailure.self) {
            try await handle.preparedControlTransaction(prepare: { context in
                preparedInsert("discard", context); return 1
            }, materialize: { _, _ -> Int in throw PreparationFailure.disk }, finish: { _, value in value })
        }
        #expect(try await handle.read(preparedValues).isEmpty)
        await #expect(throws: PreparationFailure.self) {
            try await handle.preparedControlTransaction(prepare: { context in
                preparedInsert("discard", context); return 1
            }, materialize: { value, _ in value }, finish: { context, _ -> Void in
                preparedInsert("also-discard", context); throw PreparationFailure.finalize
            })
        }
        #expect(try await handle.read(preparedValues).isEmpty)
        try await handle.transaction { preparedInsert("usable", $0) }
        try await handle.close()
    }

    @Test func cancellationDuringFilesRollsBackAndCloseRetainsPresenceThroughCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filePhase = LifecycleGate(), closing = LifecycleGate()
        await closing.release()
        let registry = StoreRegistry(hooks: .init(didBeginClose: { await closing.enter() }))
        let config = StoreConfiguration(location: .sqlite(root.appendingPathComponent("Store.sqlite")))
        let resolved = try ResolvedStore(config)
        let handle = try await registry.open(config, schema: fixtureSchema())
        let preparing = Task {
            try await handle.preparedControlTransaction(prepare: { context in
                preparedInsert("discard", context); return 1
            }, materialize: { value, _ in
                await filePhase.enter(); return value
            }, finish: { context, value in
                preparedInsert("must-not-run", context); return value
            })
        }
        await filePhase.waitForArrivals()
        let close = Task { try await handle.close() }
        await closing.waitForArrivals()
        close.cancel(); preparing.cancel()
        await #expect(throws: StoreRuntimeError.self) {
            try AppGroupOwnerClaims.requireNoClaims(for: resolved)
        }
        await filePhase.release()
        await #expect(throws: CancellationError.self) { try await preparing.value }
        try await close.value
        try AppGroupOwnerClaims.requireNoClaims(for: resolved)
        let reopened = try await registry.open(config, schema: fixtureSchema())
        #expect(try await reopened.read(preparedValues).isEmpty)
        try await reopened.close()
    }

    @Test func nativeSaveFailureRollsBackAndDoesNotPoisonTheWriter() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = fixtureModel(); model.entities[0].attributesByName["value"]!.isOptional = false
        let schema = StoreSchema(identifier: "RequiredPreparedFixture", entityVersionHashes: model.entityVersionHashesByName) {
            let model = fixtureModel(); model.entities[0].attributesByName["value"]!.isOptional = false
            return model
        }
        let handle = try await StoreRegistry().open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: schema)
        await #expect(throws: NSError.self) {
            try await handle.preparedControlTransaction(prepare: { context in
                _ = NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context); return 1
            }, materialize: { value, _ in value }, finish: { _, value in value })
        }
        #expect(try await handle.read(preparedValues).isEmpty)
        try await handle.transaction { preparedInsert("usable", $0) }
        try await handle.close()
    }

    @Test func cancellationAfterNativeSaveReturnsTheCommittedResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreparedCommitGate(); await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(afterCommit: { gate.block() }))
        let handle = try await registry.open(.init(location: .sqlite(root.appendingPathComponent("Store.sqlite"))), schema: fixtureSchema())
        let preparing = Task {
            try await handle.preparedControlTransaction(prepare: { context in
                preparedInsert("committed", context); return 42
            }, materialize: { value, _ in value }, finish: { _, value in value })
        }
        await gate.entered.waitForArrivals()
        preparing.cancel(); gate.resume.signal()
        #expect(try await preparing.value == 42)
        #expect(try await handle.read(preparedValues) == ["committed"])
        try await handle.close()
    }
}
