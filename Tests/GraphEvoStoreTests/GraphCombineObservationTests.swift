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

/// Retain the upstream independently so subscriber deinit can synchronously cancel it again.
private final class ReentrantSubscription: Sendable {
    private struct Captured: @unchecked Sendable { let value: any Subscription }
    private let state = OSAllocatedUnfairLock<Captured?>(initialState: nil)
    func set(_ subscription: any Subscription) {
        let captured = Captured(value: subscription)
        state.withLock { $0 = captured }
    }
    func cancel() {
        let captured = state.withLock { $0 }
        captured?.value.cancel()
    }
}
private final class DeinitCancellingSubscriber: Subscriber {
    typealias Input = GraphQueryState<ObservedItem>
    typealias Failure = any Error
    private let upstream: ReentrantSubscription
    private let didDeinit: @Sendable () -> Void
    init(upstream: ReentrantSubscription, didDeinit: @escaping @Sendable () -> Void) {
        self.upstream = upstream; self.didDeinit = didDeinit
    }
    func receive(subscription: any Subscription) { upstream.set(subscription) }
    func receive(_ input: Input) -> Subscribers.Demand { .none }
    func receive(completion: Subscribers.Completion<any Error>) {}
    deinit { upstream.cancel(); didDeinit() }
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

    @Test func cancellationReleasesSubscriberOutsideTheLockAllowingReentrantDeinit() async throws {
        let graph = try await GraphStore.inMemory(), upstream = ReentrantSubscription()
        let released = OSAllocatedUnfairLock(initialState: false)
        // Only the adapter retains this temporary subscriber after the handshake.
        graph.publisher(for: try observationQuery()).subscribe(DeinitCancellingSubscriber(upstream: upstream) {
            released.withLock { $0 = true }
        })
        upstream.cancel()
        #expect(released.withLock { $0 })
        try await graph.close()
    }

    @Test func laboratorySharesWorkWhileCombineRetainsIndependentDemandAndCancellation() async throws {
        let graph = try await GraphStore.inMemory(), lab = GraphSharedObservationLab(graph: graph)
        let descriptor = try observationQuery(), publisher = lab.publisher(for: descriptor)
        let a = DemandSubscriber<GraphQueryState<ObservedItem>>(), b = DemandSubscriber<GraphQueryState<ObservedItem>>()
        publisher.subscribe(a); publisher.subscribe(b)
        #expect(await lab.diagnostics.subscribers == 0)
        a.request(.max(1)); b.request(.max(1))
        var first = a.values.stream.makeAsyncIterator(), second = b.values.stream.makeAsyncIterator()
        #expect(await first.next() != nil); #expect(await second.next() != nil)
        #expect(await lab.diagnostics.activeGroups == 1)
        a.cancel()
        let id = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: id, type: ObservedItem.graphType)) }
        #expect(b.received == 1)
        b.request(.unlimited)
        while let state = await second.next() { if case .value(let result) = state, result.items.map(\.id) == [id] { break } }
        b.cancel(); try await graph.close()
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
