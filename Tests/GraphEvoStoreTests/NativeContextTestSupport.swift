import CoreData
import Dispatch
import Foundation
@testable import GraphEvoRuntime

extension NSPersistentContainer {
    func testNativeContext<Value>(_ body: (NSManagedObjectContext) throws -> Value) throws -> Value {
        let context = newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

/// Holds a Foundation accessor while the test submits a competing runtime operation.
struct TestSQLiteWriteGrant {
    private let gate: DispatchSemaphore
    private let job: Task<Void, any Error>

    static func acquire(_ resolved: ResolvedStore) async throws -> Self {
        let anchor = try SQLiteStoreCoordination.directory(resolved)
        let gate = DispatchSemaphore(value: 0), events = AsyncStream<Void>.makeStream()
        let job = Task {
            defer { events.continuation.finish() }
            try await CoordinatedFiles.run([.write(anchor)]) {
                events.continuation.yield(())
                guard gate.wait(timeout: .now() + 15) == .success else { throw CancellationError() }
            }
        }
        var iterator = events.stream.makeAsyncIterator()
        if await iterator.next() == nil { try await job.value; throw CancellationError() }
        return Self(gate: gate, job: job)
    }

    func release() { gate.signal() }
    func settle() async throws { try await job.value }
}
