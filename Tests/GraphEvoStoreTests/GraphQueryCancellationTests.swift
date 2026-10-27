import Dispatch
import Foundation
import os
import Testing
import GraphEvo

private struct CancelQueryItem: GraphModel {
    static let graphType = "cancel.item"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}
@Suite(.timeLimit(.minutes(1))) struct GraphQueryCancellationTests {
    @Test func cancellationIsVisibleInsideAnAdmittedScopeBeforeQueryInventory() async throws {
        let graph = try await GraphStore.inMemory()
        let descriptor = GraphQuery<CancelQueryItem>(budget: try GraphQueryBudget(maximumCandidates: 100))
        let started = AsyncStream<Void>.makeStream(), gate = DispatchSemaphore(value: 0)
        let observed = OSAllocatedUnfairLock(initialState: false)
        defer { gate.signal(); started.continuation.finish() }
        let work = Task {
            try await graph.read { scope -> Int in
                started.continuation.yield(())
                guard gate.wait(timeout: .now() + 5) == .success else { throw GraphModelError.invalidValue }
                do { return try scope.count(descriptor).value }
                catch is CancellationError { observed.withLock { $0 = true }; throw CancellationError() }
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        work.cancel(); gate.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(observed.withLock { $0 })
        try await graph.close()
    }
}
