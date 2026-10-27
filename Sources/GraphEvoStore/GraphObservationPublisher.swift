import Combine
import Dispatch
import GraphEvoModel
import os

/// Cold Combine adapter over the same observation contract. One worker/mailbox per subscriber.
public struct GraphObservationPublisher<Value: Sendable>: Publisher {
    public typealias Output = Value
    public typealias Failure = any Error
    private let factory: @Sendable () async throws -> GraphObservation<Value>
    package init(_ factory: @escaping @Sendable () async throws -> GraphObservation<Value>) { self.factory = factory }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Value, S.Failure == Failure {
        let subscription = GraphObservationSubscription(subscriber, factory: factory)
        subscriber.receive(subscription: subscription)
        subscription.activate()
    }
}

/// Downstream is immutable and only called from its subscription's serial delivery queue.
/// Type erasure confines Combine's non-Sendable subscriber to this audited adapter.
private final class GraphObservationDownstream<Value: Sendable>: @unchecked Sendable {
    private let value: (Value) -> Subscribers.Demand
    private let completion: (Subscribers.Completion<any Error>) -> Void
    init<S: Subscriber>(_ subscriber: S) where S.Input == Value, S.Failure == any Error {
        value = { subscriber.receive($0) }; completion = { subscriber.receive(completion: $0) }
    }
    func receive(_ input: Value) -> Subscribers.Demand { value(input) }
    func receive(completion result: Subscribers.Completion<any Error>) { completion(result) }
}

/// All mutable state is locked; downstream callbacks are serialized outside the lock.
/// The subscription handshake finishes before activation. No lock is held across await.
private final class GraphObservationSubscription<Value: Sendable>: Subscription, Sendable {
    private struct State: Sendable {
        var downstream: GraphObservationDownstream<Value>?
        var demand: Subscribers.Demand = .none
        var pending: Value?
        var completion: Subscribers.Completion<any Error>?
        var scheduled = false
        var ready = false
        var started = false
        var worker: Task<Void, Never>?
    }
    private enum Delivery: Sendable {
        case value(GraphObservationDownstream<Value>, Value)
        case completion(GraphObservationDownstream<Value>, Subscribers.Completion<any Error>, retiring: Value?)
        case none
    }
    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "GraphEvo.observation.combine")
    private let factory: @Sendable () async throws -> GraphObservation<Value>
    init<S: Subscriber>(_ downstream: S, factory: @escaping @Sendable () async throws -> GraphObservation<Value>)
    where S.Input == Value, S.Failure == any Error {
        state = OSAllocatedUnfairLock(initialState: State(downstream: GraphObservationDownstream(downstream)))
        self.factory = factory
    }
    func activate() {
        state.withLock { $0.ready = true }
        startIfNeeded(); schedule()
    }
    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        state.withLock { if $0.downstream != nil { $0.demand += demand } }
        startIfNeeded(); schedule()
    }
    private func startIfNeeded() {
        let start = state.withLock { state in
            guard state.ready, state.downstream != nil, state.demand > .none, !state.started else { return false }
            state.started = true; return true
        }
        guard start else { return }
        let factory = factory
        let worker = Task { [weak self] in
            do {
                let observation = try await factory()
                defer { observation.cancel() }
                for await value in observation {
                    guard !Task.isCancelled else { return }
                    self?.offer(value)
                }
                if !Task.isCancelled { self?.complete(.finished) }
            } catch {
                if !Task.isCancelled { self?.complete(.failure(error)) }
            }
        }
        let cancelled = state.withLock { state in
            guard state.downstream != nil else { return true }
            state.worker = worker; return false
        }
        if cancelled { worker.cancel() }
    }
    private func offer(_ value: Value) {
        let previous = state.withLock { state -> Value? in
            guard state.downstream != nil else { return nil }
            let previous = state.pending
            state.pending = value
            return previous
        }
        // Releasing arbitrary downstream values can run application deinitializers.
        withExtendedLifetime(previous) {}
        schedule()
    }
    private func complete(_ completion: Subscribers.Completion<any Error>) {
        let previous = state.withLock { state -> Subscribers.Completion<any Error>? in
            guard state.downstream != nil else { return nil }
            let previous = state.completion
            state.completion = completion
            return previous
        }
        withExtendedLifetime(previous) {}
        schedule()
    }
    private func schedule() {
        let schedule = state.withLock { state in
            guard state.ready, state.downstream != nil, !state.scheduled,
                  (state.pending != nil && state.demand > .none) || state.completion != nil else { return false }
            state.scheduled = true; return true
        }
        if schedule { queue.async { [self] in drain() } }
    }
    private func drain() {
        while true {
            let delivery: Delivery = state.withLock { state in
                guard let downstream = state.downstream else { state.scheduled = false; return .none }
                if let value = state.pending, state.demand > .none {
                    state.pending = nil; state.demand -= .max(1)
                    return .value(downstream, value)
                }
                if let completion = state.completion {
                    let retired = state.pending
                    state.downstream = nil; state.pending = nil; state.completion = nil; state.worker = nil
                    state.scheduled = false
                    return .completion(downstream, completion, retiring: retired)
                }
                state.scheduled = false; return .none
            }
            switch delivery {
            case .value(let downstream, let value):
                let extra = downstream.receive(value)
                if extra > .none { request(extra) }
            case .completion(let downstream, let completion, let retired):
                withExtendedLifetime(retired) { downstream.receive(completion: completion) }
                return
            case .none: return
            }
        }
    }
    func cancel() {
        let retired = state.withLock { state in
            let retired = state
            state.worker = nil; state.downstream = nil; state.pending = nil; state.completion = nil
            return retired
        }
        retired.worker?.cancel()
        // Subscribers and queued values may reenter cancel/request from deinit.
        withExtendedLifetime(retired) {}
    }
    deinit { cancel() }
}

extension GraphStore {
    /// Delivery uses a private serial queue. UI consumers choose receive(on:) explicitly.
    public nonisolated func publisher<Model: GraphModel>(for query: GraphQuery<Model>) -> GraphObservationPublisher<GraphQueryState<Model>> {
        GraphObservationPublisher { try await self.observe(query) }
    }
    public nonisolated func changePublisher() -> GraphObservationPublisher<GraphChangeSignal> {
        GraphObservationPublisher { try await self.changes() }
    }
}
