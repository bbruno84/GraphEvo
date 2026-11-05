import Foundation
import os

/// A finite Foundation grant. Every URL in a request is acquired in one batch,
/// and native file work finishes before the accessor returns.
package enum CoordinatedFiles {
    package enum Access: Sendable {
        case read(URL)
        case write(URL)
        case delete(URL)

        var url: URL {
            switch self {
            case .read(let url), .write(let url), .delete(let url): return url
            }
        }
    }

    package struct Denied: Error {
        package let underlying: any Error
    }

    package typealias CancellationCheck = @Sendable () throws -> Void

    package static func run<Value: Sendable>(
        _ accesses: [Access], presenter: (any NSFilePresenter & Sendable)? = nil,
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await run(accesses, presenter: presenter) { _ in try body() }
    }

    package static func run<Value: Sendable>(
        _ accesses: [Access], presenter: (any NSFilePresenter & Sendable)? = nil,
        _ body: @escaping @Sendable (CancellationCheck) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let request = Request()
        let checkCancellation: CancellationCheck = {
            guard !request.state.withLock({ $0.cancelled }) else { throw CancellationError() }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let expected = accesses.map { $0.url.standardizedFileURL.path }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let intents = accesses.map { access in
                    switch access {
                    case .read(let url): return NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
                    case .write(let url): return NSFileAccessIntent.writingIntent(with: url, options: [])
                    case .delete(let url): return NSFileAccessIntent.writingIntent(with: url, options: .forDeleting)
                    }
                }
                let submit: @Sendable () -> Void = {
                    let coordinator = Coordinator(NSFileCoordinator(filePresenter: presenter))
                    let submitted = request.state.withLock { state in
                        guard !state.cancelled else { return false }
                        state.coordinator = coordinator
                        coordinator.value.coordinate(with: intents, queue: queue) { error in
                            let result = Result {
                                try checkCancellation()
                                if let error { throw Denied(underlying: error) }
                                for (intent, path) in zip(intents, expected) {
                                    guard intent.url.standardizedFileURL.resolvingSymlinksInPath().path == path else {
                                        throw StoreRuntimeError.storeReplaced(intent.url)
                                    }
                                }
                                return try body(checkCancellation)
                            }
                            queue.addOperation {
                                request.state.withLock { $0.coordinator = nil }
                                continuation.resume(with: result)
                            }
                        }
                        return true
                    }
                    if !submitted { continuation.resume(throwing: CancellationError()) }
                }
                let submissionQueue = presenter?.presentedItemOperationQueue ?? OperationQueue()
                submissionQueue.addOperation(submit)
            }
        } onCancel: {
            let coordinator = request.state.withLock { state in
                state.cancelled = true
                return state.coordinator
            }
            coordinator?.value.cancel()
        }
    }

    private final class Coordinator: @unchecked Sendable {
        let value: NSFileCoordinator
        init(_ value: NSFileCoordinator) { self.value = value }
    }

    private struct State: Sendable {
        var cancelled = false
        var coordinator: Coordinator?
    }

    private final class Request: Sendable {
        let state = OSAllocatedUnfairLock(initialState: State())
    }
}
