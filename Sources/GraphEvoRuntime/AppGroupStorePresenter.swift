import Foundation

/// One presenter per attached coordinator. Registration follows native attachment,
/// including quarantine, rather than any individual graph handle. The presented
/// registration directory is a descendant of the shared coordination root.
final class AppGroupStorePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    let generation = UUID()
    let coordinationDirectory: URL
    let directoryIdentity: FileIdentity?

    init(directory: URL, directoryIdentity: FileIdentity? = nil) {
        self.directoryIdentity = directoryIdentity
        coordinationDirectory = directory
        // Present the stable registration directory, so ordinary root access needs no owner handoff.
        // Deleting the root still consults every descendant presenter.
        presentedItemURL = AppGroupOwnerClaims.presentationURL(anchor: directory)
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
