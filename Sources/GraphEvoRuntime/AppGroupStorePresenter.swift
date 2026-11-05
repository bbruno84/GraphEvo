import Foundation

/// One presenter per attached coordinator. Registration follows native attachment,
/// including quarantine, rather than any individual graph handle.
final class AppGroupStorePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    let generation = UUID()

    init(directory: URL) {
        presentedItemURL = directory
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func register() { NSFileCoordinator.addFilePresenter(self) }
    func unregister() { NSFileCoordinator.removeFilePresenter(self) }

    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(StoreRuntimeError.resourceReserved)
    }
}
