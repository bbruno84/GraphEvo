import os

/// Transfers caller cancellation into a native synchronous Core Data closure.
/// The lock protects only one Boolean; no context or suspended work runs under it.
final class OperationCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() { state.withLock { $0 = true } }

    func check() throws {
        if state.withLock({ $0 }) { throw CancellationError() }
    }
}
