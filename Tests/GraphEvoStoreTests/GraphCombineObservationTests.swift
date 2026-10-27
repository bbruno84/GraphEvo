import Combine
import Foundation
import GraphEvo
import os
import Testing

/// Test subscriber state is locked; callbacks only enqueue Sendable values for the async test.
private final class DemandSubscriber<Value: Sendable>: Subscriber, @unchecked Sendable {
    typealias Input = Value
    typealias Failure = any Error
    private struct CapturedSubscription: @unchecked Sendable { let value: any Subscription }
    private struct State: Sendable {
        var subscription: CapturedSubscription?
        var received = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let values = AsyncStream<Value>.makeStream()
    let completions = AsyncStream<Bool>.makeStream()
    func receive(subscription: any Subscription) {
        let box = CapturedSubscription(value: subscription)
        state.withLock { $0.subscription = box }
    }
    func receive(_ input: Value) -> Subscribers.Demand {
        state.withLock { $0.received += 1 }; values.continuation.yield(input); return .none
    }
    func receive(completion: Subscribers.Completion<any Error>) {
        switch completion { case .finished: completions.continuation.yield(true); case .failure: completions.continuation.yield(false) }
        values.continuation.finish(); completions.continuation.finish()
    }
    func request(_ demand: Subscribers.Demand) { state.withLock { $0.subscription?.value.request(demand) } }
    func cancel() { state.withLock { $0.subscription?.value.cancel(); $0.subscription = nil }; values.continuation.finish() }
    var received: Int { state.withLock { $0.received } }
}

@Suite(.timeLimit(.minutes(1))) struct GraphCombineObservationTests {
    @Test func demandStartsColdObservationAndCancellationDoesNotCloseTheGraph() async throws {
        let graph = try await GraphStore.inMemory(), descriptor = try observationQuery()
        let subscriber = DemandSubscriber<GraphQueryState<ObservedItem>>()
        graph.publisher(for: descriptor).subscribe(subscriber)
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType)) }
        #expect(subscriber.received == 0)
        subscriber.request(.max(1))
        var iterator = subscriber.values.stream.makeAsyncIterator()
        if case .value(let result) = await iterator.next() { #expect(result.items.map(\.id) == [id]) }
        else { Issue.record("Expected current state after first positive demand.") }
        for version in 1...20 {
            try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["v": .set(.integer(Int64(version)))])) }
        }
        #expect(subscriber.received == 1)
        subscriber.request(.unlimited)
        while let state = await iterator.next() {
            if case .value(let result) = state, result.items.first?.record.properties["v"] == .integer(20) { break }
        }
        subscriber.cancel()
        #expect(try await graph.count(descriptor).value == 1)
        try await graph.close()
    }

    @Test func separateSubscribersGetInitialStateAndHandleCloseCompletesThem() async throws {
        let graph = try await GraphStore.inMemory(), descriptor = try observationQuery()
        let publisher = graph.publisher(for: descriptor)
        let first = DemandSubscriber<GraphQueryState<ObservedItem>>(), second = DemandSubscriber<GraphQueryState<ObservedItem>>()
        publisher.subscribe(first); publisher.subscribe(second)
        first.request(.unlimited); second.request(.unlimited)
        var a = first.values.stream.makeAsyncIterator(), b = second.values.stream.makeAsyncIterator()
        let initialA = await a.next(), initialB = await b.next()
        #expect(initialA != nil && initialB != nil)
        first.cancel()
        try await graph.close()
        var completed = second.completions.stream.makeAsyncIterator()
        #expect(await completed.next() == true)
        second.cancel()
    }

    @Test func invalidDescriptorTerminatesPublisherWithFailure() async throws {
        let graph = try await GraphStore.inMemory()
        let subscriber = DemandSubscriber<GraphQueryState<ObservedItem>>()
        graph.publisher(for: try observationQuery().limit(0)).subscribe(subscriber)
        subscriber.request(.unlimited)
        var completion = subscriber.completions.stream.makeAsyncIterator()
        #expect(await completion.next() == false)
        #expect(subscriber.received == 0)
        subscriber.cancel(); try await graph.close()
    }
}
