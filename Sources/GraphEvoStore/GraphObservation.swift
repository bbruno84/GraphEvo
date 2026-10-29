import Foundation
import GraphEvoModel
import GraphEvoRuntime
import os

public enum GraphObservationError: Error, Sendable {
    /// Stop displaying cached observed state and re-establish the application's account/store policy.
    case accountChanged
}

/// Current local query state. A failed refresh does not terminate future refresh attempts.
public enum GraphQueryState<Model: GraphModel>: Sendable {
    case value(GraphQueryResult<Model>)
    case failure(any Error)
}

/// A bounded live hint to rescan this graph. It contains no per-node events or replay position.
public struct GraphChangeSignal: Sendable {
    public enum Reason: Sendable { case initial, contextSave, storeChange, nativeOperation, accountChange, refresh }
    public let graphID: GraphID
    public let id: UUID
    public let reason: Reason
    public var requiresRescan: Bool { true }
    package init(graphID: GraphID, invalidation: StoreInvalidation) {
        self.graphID = graphID; id = invalidation.id
        switch invalidation.reason {
        case .initial: reason = .initial
        case .contextSave: reason = .contextSave
        case .storeChange: reason = .storeChange
        case .nativeOperation: reason = .nativeOperation
        case .accountChange: reason = .accountChange
        case .refresh: reason = .refresh
        }
    }
}

/// A single-consumer newest-state sequence. Retain the observation or its iterator while consuming it.
/// Cancel explicitly when breaking a loop but retaining the observation; dropping both also cancels.
public struct GraphObservation<Value: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Value
    private let stream: AsyncStream<Value>
    private let control: GraphObservationControl
    package init(stream: AsyncStream<Value>, control: GraphObservationControl) { self.stream = stream; self.control = control }
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<Value>.Iterator
        private let control: GraphObservationControl
        fileprivate init(iterator: AsyncStream<Value>.Iterator, control: GraphObservationControl) {
            self.iterator = iterator; self.control = control
        }
        public mutating func next() async -> Value? { await iterator.next() }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(iterator: stream.makeAsyncIterator(), control: control) }
    public func cancel() { control.cancel() }
    /// Requests a fresh local read; use after foregrounding or resolving an external condition.
    public func refresh() { control.refresh() }
}

/// The worker never retains this control. Its last owner cancels the worker, avoiding a task/owner cycle.
package final class GraphObservationControl: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var worker: Task<Void, Never>?
        var refresh: (@Sendable () -> Void)?
        var finish: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    package init() {}
    package func install(_ worker: Task<Void, Never>, refresh: @escaping @Sendable () -> Void,
                         finish: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { state in
            guard !state.cancelled else { return true }
            state.worker = worker; state.refresh = refresh; state.finish = finish
            return false
        }
        if cancelled { worker.cancel(); finish() }
    }
    package func refresh() { state.withLock { $0.refresh }?() }
    package func cancel() {
        let work = state.withLock { state in
            state.cancelled = true
            let work = (state.worker, state.finish)
            state.worker = nil; state.refresh = nil; state.finish = nil
            return work
        }
        work.0?.cancel(); work.1?()
    }
    deinit { cancel() }
}

extension GraphStore {
    /// Subscribes before the initial read so a save racing that read queues another refresh.
    /// Cursor-based observations are rejected: an observation describes the current first page.
    public func observe<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphObservation<GraphQueryState<Model>> {
        try await queryObservationCoordinator().observe(query)
    }

    /// Bounded live invalidation with explicit rescan, not durable processing or deletion reconstruction.
    public func changes() async throws -> GraphObservation<GraphChangeSignal> {
        let feed = try await observationFeed(), graphID = id
        let pair = AsyncStream<GraphChangeSignal>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        let worker = Task {
            defer { pair.continuation.finish() }
            for await invalidation in feed.stream {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(GraphChangeSignal(graphID: graphID, invalidation: invalidation))
            }
        }
        control.install(worker, refresh: feed.refresh, finish: { pair.continuation.finish() })
        return GraphObservation(stream: pair.stream, control: control)
    }
}
