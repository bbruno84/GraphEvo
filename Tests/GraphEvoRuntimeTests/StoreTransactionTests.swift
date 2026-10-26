import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime
@testable import GraphEvo

/// These fixtures exercise the privileged persistence adapter, not application models.
private func values(_ context: NSManagedObjectContext) throws -> [String] {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RuntimeFixture"))
        .compactMap { $0.value(forKey: "value") as? String }.sorted()
}

private func insert(_ value: String, in context: NSManagedObjectContext) {
    NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context)
        .setValue(value, forKey: "value")
}

private struct NativeGate: Sendable {
    let entered = LifecycleGate()
    let resume = DispatchSemaphore(value: 0)

    func block() throws {
        Task { await entered.enter() }
        guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct StoreTransactionTests {
    @Test func writesCommitAndSurviveReopening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Main.sqlite")))
        let registry = StoreRegistry()
        let handle = try await registry.open(configuration, schema: fixtureSchema())
        let result = try await handle.transaction { context in insert("Ada", in: context); return 42 }
        #expect(result == 42)
        try await handle.close()
        let reopened = try await registry.open(configuration, schema: fixtureSchema())
        #expect(try await reopened.read(values) == ["Ada"])
        try await reopened.close()
    }

    @Test func bodyFailureRollsBackWithoutLeakingIntoTheNextWriter() async throws {
        struct BodyFailure: Error {}
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        await #expect(throws: BodyFailure.self) {
            try await handle.transaction { context in insert("discarded", in: context); throw BodyFailure() }
        }
        try await handle.transaction { context in insert("kept", in: context) }
        #expect(try await handle.read(values) == ["kept"])
        try await handle.close()
    }

    @Test func nativeValidationFailureRollsBackAndReleasesTheWriter() async throws {
        let model = fixtureModel()
        model.entities[0].attributesByName["value"]!.isOptional = false
        let schema = StoreSchema(identifier: "RequiredFixture", entityVersionHashes: model.entityVersionHashesByName) {
            let model = fixtureModel()
            model.entities[0].attributesByName["value"]!.isOptional = false
            return model
        }
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: schema)
        await #expect(throws: NSError.self) {
            try await handle.transaction { context in
                _ = NSEntityDescription.insertNewObject(forEntityName: "RuntimeFixture", into: context)
            }
        }
        try await handle.transaction { context in insert("valid", in: context) }
        #expect(try await handle.read(values) == ["valid"])
        try await handle.close()
    }

    @Test func writersAcrossHandlesSerializeReadModifyWrite() async throws {
        let registry = StoreRegistry()
        let configuration = StoreConfiguration(location: .inMemory(UUID()))
        let first = try await registry.open(configuration, schema: fixtureSchema())
        let second = try await registry.open(configuration, schema: fixtureSchema())
        try await first.transaction { context in insert("0", in: context) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let handle = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await handle.transaction { context in
                        let row = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RuntimeFixture"))[0]
                        let previous = Int(row.value(forKey: "value") as! String)!
                        row.setValue(String(previous + 1), forKey: "value")
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await first.read(values) == ["40"])
        try await first.close()
        try await second.close()
    }

    @Test func cancellationInsideBodyPreventsCommit() async throws {
        let gate = NativeGate()
        await gate.entered.release()
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let writing = Task {
            try await handle.transaction { context in insert("discarded", in: context); try gate.block() }
        }
        await gate.entered.waitForArrivals()
        writing.cancel()
        gate.resume.signal()
        await #expect(throws: CancellationError.self) { try await writing.value }
        #expect(try await handle.read(values).isEmpty)
        try await handle.close()
    }

    @Test func cancellationAfterSaveReturnsCommittedResult() async throws {
        let gate = NativeGate()
        await gate.entered.release()
        let registry = StoreRegistry(hooks: .init(afterCommit: { try? gate.block() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let writing = Task { try await handle.transaction { context in insert("committed", in: context); return 7 } }
        await gate.entered.waitForArrivals()
        writing.cancel()
        gate.resume.signal()
        #expect(try await writing.value == 7)
        #expect(try await handle.read(values) == ["committed"])
        try await handle.close()
    }

    @Test func cancelledQueuedWriterNeverRunsAndDoesNotWaitForActiveWriter() async throws {
        let gate = NativeGate(), queued = LifecycleGate()
        await gate.entered.release()
        await queued.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let first = Task { try await handle.transaction { context in try gate.block(); insert("first", in: context) } }
        await gate.entered.waitForArrivals()
        let second = Task { try await handle.transaction { context in insert("cancelled", in: context) } }
        await queued.waitForArrivals()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        gate.resume.signal()
        try await first.value
        #expect(try await handle.read(values) == ["first"])
        try await handle.close()
    }

    @Test func preCancelledWriterDoesNotRun() async throws {
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let gate = LifecycleGate()
        let writing = Task {
            await gate.enter()
            try await handle.transaction { context in insert("cancelled", in: context) }
        }
        await gate.waitForArrivals()
        writing.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await writing.value }
        #expect(try await handle.read(values).isEmpty)
        try await handle.close()
    }

    @Test func cancelledNativeReadReportsCancellation() async throws {
        let gate = NativeGate()
        await gate.entered.release()
        let handle = try await StoreRegistry().open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let reading = Task { try await handle.read { _ in try gate.block(); return 1 } }
        await gate.entered.waitForArrivals()
        reading.cancel()
        gate.resume.signal()
        await #expect(throws: CancellationError.self) { try await reading.value }
        try await handle.close()
    }

    @Test func finalCloseDrainsActiveAndQueuedWrites() async throws {
        let gate = NativeGate(), queued = LifecycleGate(), detaching = LifecycleGate(), closingStarted = LifecycleGate()
        await gate.entered.release()
        await queued.release()
        await detaching.release()
        await closingStarted.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() },
                                                  didBeginClose: { await closingStarted.enter() },
                                                  beforeDetach: { await detaching.enter() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let first = Task { try await handle.transaction { context in try gate.block(); insert("one", in: context) } }
        await gate.entered.waitForArrivals()
        let second = Task { try await handle.transaction { context in insert("two", in: context) } }
        await queued.waitForArrivals()
        let closing = Task { try await handle.close() }
        await closingStarted.waitForArrivals()
        closing.cancel()
        #expect(await detaching.count() == 0)
        gate.resume.signal()
        try await first.value
        try await second.value
        try await closing.value
        #expect(await detaching.count() == 1)
        await #expect { try await handle.transaction { _ in 0 } } throws: { error in
            guard case StoreRuntimeError.closedHandle = error else { return false }
            return true
        }
    }

    @Test func readOnlyStoreRejectsWritesBeforeInvokingBody() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let registry = StoreRegistry()
        let writer = try await registry.open(.init(location: .sqlite(url)), schema: fixtureSchema())
        try await writer.transaction { context in insert("kept", in: context) }
        try await writer.close()
        let reader = try await registry.open(.init(location: .sqlite(url), access: .readOnly), schema: fixtureSchema())
        await #expect {
            try await reader.transaction { context in insert("forbidden", in: context) }
        } throws: { error in
            guard case StoreRuntimeError.readOnlyStore = error else { return false }
            return true
        }
        #expect(try await reader.read(values) == ["kept"])
        try await reader.close()
    }

    @Test func sqliteReadRemainsOnItsPinnedViewWhileAnotherHandleCommits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = StoreRegistry()
        let configuration = StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Main.sqlite")))
        let reader = try await registry.open(configuration, schema: fixtureSchema())
        let writer = try await registry.open(configuration, schema: fixtureSchema())
        try await writer.transaction { context in insert("original", in: context) }
        let gate = NativeGate()
        await gate.entered.release()
        let reading = Task {
            try await reader.read { context in
                let before = try values(context)
                try gate.block()
                return (before, try values(context))
            }
        }
        await gate.entered.waitForArrivals()
        try await writer.transaction { context in insert("new", in: context) }
        gate.resume.signal()
        let (before, after) = try await reading.value
        #expect(before == ["original"])
        #expect(after == before)
        #expect(try await reader.read(values) == ["new", "original"])
        try await reader.close()
        try await writer.close()
    }

    @Test func pendingWritesAreInvisibleAndOtherStoresCanWriteIndependently() async throws {
        let registry = StoreRegistry()
        let first = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let other = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let gate = NativeGate()
        await gate.entered.release()
        let writing = Task {
            try await first.transaction { context in insert("pending", in: context); try gate.block() }
        }
        await gate.entered.waitForArrivals()
        #expect(try await first.read(values).isEmpty)
        try await other.transaction { context in insert("independent", in: context) }
        #expect(try await other.read(values) == ["independent"])
        gate.resume.signal()
        try await writing.value
        #expect(try await first.read(values) == ["pending"])
        try await first.close()
        try await other.close()
    }

    @Test func nonUIConsumerUsesGraphFacadesAndReturnsOnlyValues() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Graph.sqlite")))
        let registry = StoreRegistry()
        let handle = try await registry.open(configuration, schema: graphSchema())
        let name = try await handle.transaction { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            let author = Entity("Author", graph: graph)
            author[dynamicMember: "name"] = "Ada"
            author.add(tags: "active")
            author.add(to: "authors")
            let note = Entity("Note", graph: graph)
            author.is(relationship: "writes").of(note)
            author.will(action: "reviews").add(objects: note)
            return author[dynamicMember: "name"] as? String
        }
        #expect(name == "Ada")
        try await handle.close()
        let reopened = try await registry.open(configuration, schema: graphSchema())
        let counts = try await reopened.read { context in
            let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
            return [Search<Entity>(graph: graph).where(.type("Author") || .type("Note")).sync().count,
                    Search<Relationship>(graph: graph).where(.type("writes")).sync().count,
                    Search<Action>(graph: graph).where(.type("reviews")).sync().count]
        }
        #expect(counts == [2, 1, 1])
        try await reopened.close()
    }

    @Test func admittedWritersRunInFIFOOrder() async throws {
        let gate = NativeGate(), queued = LifecycleGate()
        await gate.entered.release()
        await queued.release()
        let registry = StoreRegistry(hooks: .init(didQueueWriter: { await queued.enter() }))
        let handle = try await registry.open(.init(location: .inMemory(UUID())), schema: fixtureSchema())
        let first = Task { try await handle.transaction { context in try gate.block(); insert("first", in: context) } }
        await gate.entered.waitForArrivals()
        let second = Task {
            try await handle.transaction { context in
                guard try values(context) == ["first"] else { throw CocoaError(.validationMissingMandatoryProperty) }
                insert("second", in: context)
            }
        }
        await queued.waitForArrivals()
        let third = Task {
            try await handle.transaction { context in
                guard try values(context) == ["first", "second"] else { throw CocoaError(.validationMissingMandatoryProperty) }
                insert("third", in: context)
            }
        }
        await queued.waitForArrivals(2)
        gate.resume.signal()
        try await first.value
        try await second.value
        try await third.value
        #expect(try await handle.read(values) == ["first", "second", "third"])
        try await handle.close()
    }
}
