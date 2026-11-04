import Foundation
import os

package enum StoreAccountIsolation: Sendable, Equatable { case verificationRequired, signedOut, differentAccount, restricted }
package enum StoreAccountStatus: Sendable, Equatable {
    case localOnly, available, temporarilyUnavailable
    case isolated(StoreAccountIsolation)
    package var allowsData: Bool { if case .isolated = self { return false }; return true }
}

/// A permit never becomes valid again after an intervening identity boundary.
package struct StoreAccountPermit: Sendable {
    private let validate: @Sendable () throws -> Void
    init(validate: @escaping @Sendable () throws -> Void) { self.validate = validate }
    package func check() throws { try validate() }
}

package struct StoreAccountFeed: Sendable {
    package let stream: AsyncStream<Void>
    package let current: @Sendable () -> StoreAccountStatus
    package let cancel: @Sendable () -> Void
    package let refresh: @Sendable () -> Void
}

/// Retains no native objects. Isolation can reach admitted work even while native close drains.
package struct StoreAccountControl: Sendable {
    let access: StoreAccountAccess
    let invalidations: StoreInvalidationHub
    package func update(_ value: StoreAccountStatus, revision: UInt64) {
        if access.update(value, revision: revision) { invalidations.isolateAccount() }
    }
}

/// Access checks are synchronous on native queues. Notifications run after unlocking.
package final class StoreAccountAccess: Sendable {
    private struct State: Sendable {
        var value: StoreAccountStatus = .localOnly
        var epoch: UInt64 = 0
        var revision: UInt64 = 0
        var closed = false
        var subscribers: [UUID: (owner: UUID, continuation: AsyncStream<Void>.Continuation)] = [:]
        var isolationObservers: [UUID: @Sendable () -> Void] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    package var status: StoreAccountStatus { state.withLock { $0.value } }
    package func permit() throws -> StoreAccountPermit {
        let epoch = try state.withLock { state in
            guard !state.closed, state.value.allowsData else { throw StoreRuntimeError.accountIsolated }
            return state.epoch
        }
        return StoreAccountPermit { [self] in
            try state.withLock { state in
                guard !state.closed, state.value.allowsData, state.epoch == epoch else { throw StoreRuntimeError.accountIsolated }
            }
        }
    }
    /// The manager orders transitions; a delayed opener must not undo a newer isolation.
    package func update(_ value: StoreAccountStatus, revision: UInt64) -> Bool {
        let work = state.withLock { state -> ([AsyncStream<Void>.Continuation], Bool, [@Sendable () -> Void])? in
            guard !state.closed, revision >= state.revision else { return nil }
            state.revision = revision
            guard state.value != value else { return nil }
            let isolates = !value.allowsData
            if isolates { state.epoch += 1 }
            state.value = value
            return (state.subscribers.values.map(\.continuation), isolates, isolates ? Array(state.isolationObservers.values) : [])
        }
        guard let work else { return false }
        for continuation in work.0 { continuation.yield(()) }
        for observer in work.2 { observer() }
        return work.1
    }
    package func onIsolation(_ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.isolationObservers[id] = body }
        return { [weak self] in _ = self?.state.withLock { $0.isolationObservers.removeValue(forKey: id) } }
    }
    package func subscribe(owner: UUID) -> StoreAccountFeed {
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        // Ticks always resolve the latest state at consumption, including the initial tick.
        pair.continuation.yield(())
        let closed = state.withLock { state in
            if !state.closed { state.subscribers[id] = (owner, pair.continuation) }
            return state.closed
        }
        if closed { pair.continuation.finish() }
        return StoreAccountFeed(stream: pair.stream, current: { [self] in status },
            cancel: { [weak self] in self?.remove(id) }, refresh: { pair.continuation.yield(()) })
    }
    private func remove(_ id: UUID) {
        let continuation = state.withLock { $0.subscribers.removeValue(forKey: id)?.continuation }
        continuation?.finish()
    }
    package func finish(owner: UUID? = nil) {
        let continuations = state.withLock { state in
            if owner == nil { state.closed = true; state.epoch += 1 }
            let selected = state.subscribers.filter { owner == nil || $0.value.owner == owner }
            for id in selected.keys { state.subscribers.removeValue(forKey: id) }
            return selected.values.map(\.continuation)
        }
        for continuation in continuations { continuation.finish() }
    }
}
