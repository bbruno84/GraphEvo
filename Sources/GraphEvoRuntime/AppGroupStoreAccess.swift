import Foundation
import os

/// A single finite Apple coordination request.
final class AppGroupStoreAccess: @unchecked Sendable {
    // Foundation permits cancel() from any thread. Submission and the accessor
    // remain confined to their designated operation queues.
    private final class Coordinator: @unchecked Sendable {
        let value: NSFileCoordinator
        init(_ value: NSFileCoordinator) { self.value = value }
    }

    private struct State: Sendable {
        var cancelled = false
        var coordinator: Coordinator?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let accessorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "GraphEvo.AppGroup.accessor"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let presenter: AppGroupStorePresenter
    private let associatePresenter: Bool
    private let cancellable: Bool
    private let options: NSFileCoordinator.WritingOptions
    private let onSubmit: (@Sendable () -> Void)?

    init(presenter: AppGroupStorePresenter, associatePresenter: Bool = true, cancellable: Bool = true,
         options: NSFileCoordinator.WritingOptions = [], onSubmit: (@Sendable () -> Void)? = nil) {
        self.presenter = presenter
        self.associatePresenter = associatePresenter
        self.cancellable = cancellable
        self.options = options
        self.onSubmit = onSubmit
    }

    func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard let directory = presenter.presentedItemURL else {
            throw StoreRuntimeError.invalidConfiguration("App Group coordination requires its owner's directory.")
        }
        let expected = directory.standardizedFileURL.path
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                presenter.presentedItemOperationQueue.addOperation { [self] in
                    let coordinator = Coordinator(NSFileCoordinator(filePresenter: associatePresenter ? presenter : nil))
                    let intent = NSFileAccessIntent.writingIntent(with: directory, options: options)
                    let submitted = state.withLock { current in
                        guard !current.cancelled else { return false }
                        current.coordinator = coordinator
                        coordinator.value.coordinate(with: [intent], queue: accessorQueue) { [self] error in
                            let result: Result<Value, any Error>
                            if let error {
                                result = .failure(state.withLock { $0.cancelled } ? CancellationError() : error)
                            } else {
                                result = Result {
                                    guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
                                    guard intent.url.standardizedFileURL.resolvingSymlinksInPath().path == expected else {
                                        throw StoreRuntimeError.storeReplaced(directory)
                                    }
                                    return try body()
                                }
                            }
                            // This operation runs after the synchronous accessor has returned.
                            accessorQueue.addOperation { [self] in
                                state.withLock { $0.coordinator = nil }
                                continuation.resume(with: result)
                            }
                        }
                        return true
                    }
                    if submitted { onSubmit?() }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            guard self.cancellable else { return }
            let coordinator = self.state.withLock { current in
                current.cancelled = true
                return current.coordinator
            }
            coordinator?.value.cancel()
        }
    }
}
