import CoreData
import Foundation
import os

/// Hints to reread local state, never a transaction log or an assertion of cloud completion.
package enum StoreInvalidationReason: Sendable { case initial, contextSave, storeChange, nativeOperation, accountChange, refresh }
package struct StoreInvalidation: Sendable {
    package let id = UUID()
    package let reason: StoreInvalidationReason
}
package struct StoreInvalidationFeed: Sendable {
    package let stream: StoreInvalidationSequence
    package let refresh: @Sendable () -> Void
}

/// Resolve the account guard at consumption, not from a potentially stale publication snapshot.
/// Ordinary notifications may already be outside the hub lock when accountChanged becomes true.
package struct StoreInvalidationSequence: AsyncSequence, Sendable {
    package typealias Element = StoreInvalidation
    private let raw: AsyncStream<StoreInvalidation>
    private let accountChanged: @Sendable () -> Bool
    package init(raw: AsyncStream<StoreInvalidation>, accountChanged: @escaping @Sendable () -> Bool) {
        self.raw = raw; self.accountChanged = accountChanged
    }
    package struct AsyncIterator: AsyncIteratorProtocol {
        private var raw: AsyncStream<StoreInvalidation>.Iterator
        private let accountChanged: @Sendable () -> Bool
        fileprivate init(raw: AsyncStream<StoreInvalidation>.Iterator, accountChanged: @escaping @Sendable () -> Bool) {
            self.raw = raw; self.accountChanged = accountChanged
        }
        package mutating func next() async -> StoreInvalidation? {
            guard let value = await raw.next() else { return nil }
            return accountChanged() ? StoreInvalidation(reason: .accountChange) : value
        }
    }
    package func makeAsyncIterator() -> AsyncIterator { AsyncIterator(raw: raw.makeAsyncIterator(), accountChanged: accountChanged) }
}

/// All mutable state is locked; continuation delivery/termination occurs after unlocking.
/// Notifications only enqueue value hints; no subscriber executes on the persistence queue.
package final class StoreInvalidationHub: Sendable {
    private struct Subscriber: Sendable {
        let owner: UUID
        let continuation: AsyncStream<StoreInvalidation>.Continuation
    }
    private struct State: Sendable {
        var closed = false
        var accountChanged = false
        var subscribers: [UUID: Subscriber] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    package func subscribe(owner: UUID) -> StoreInvalidationFeed {
        let id = UUID(), pair = AsyncStream<StoreInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        // Install the initial hint before registration so a newer invalidation cannot be overwritten by it.
        pair.continuation.yield(StoreInvalidation(reason: .initial))
        let flags = state.withLock { state in
            if !state.closed { state.subscribers[id] = Subscriber(owner: owner, continuation: pair.continuation) }
            return (state.closed, state.accountChanged)
        }
        if flags.1 { pair.continuation.yield(StoreInvalidation(reason: .accountChange)) }
        if flags.0 { pair.continuation.finish() }
        let stream = StoreInvalidationSequence(raw: pair.stream, accountChanged: { [weak self] in
            self?.state.withLock { $0.accountChanged } ?? false
        })
        return StoreInvalidationFeed(stream: stream, refresh: { [weak self] in self?.refresh(id) })
    }
    private func remove(_ id: UUID) { _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
    private func refresh(_ id: UUID) {
        let target = state.withLock { ($0.subscribers[id]?.continuation, $0.accountChanged) }
        target.0?.yield(StoreInvalidation(reason: target.1 ? .accountChange : .refresh))
    }
    package func publish(_ reason: StoreInvalidationReason) {
        let delivery = state.withLock { state in
            if case .accountChange = reason { state.accountChanged = true }
            return (state.subscribers.values.map(\.continuation), state.accountChanged)
        }
        for continuation in delivery.0 { continuation.yield(StoreInvalidation(reason: delivery.1 ? .accountChange : reason)) }
    }
    package func finish(owner: UUID? = nil) {
        let continuations = state.withLock { state in
            if owner == nil { state.closed = true }
            let selected = state.subscribers.filter { owner == nil || $0.value.owner == owner }
            for id in selected.keys { state.subscribers.removeValue(forKey: id) }
            return selected.values.map(\.continuation)
        }
        for continuation in continuations { continuation.finish() }
    }
    package var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}
