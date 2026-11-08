#if GRAPHEVO_BUILD_LABS
import Foundation

private enum ProbeError: Error { case livePresenter, guardFailed }

private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    init(_ url: URL) {
        presentedItemURL = url
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }
    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(ProbeError.livePresenter)
    }
}

@main private struct NativePresenterProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativePresenterCost-" + UUID().uuidString)
        let child = root.appendingPathComponent("registrations", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        print(ProcessInfo.processInfo.operatingSystemVersionString)
        for (label, location) in [("same-item", root), ("descendant", child)] {
            let presenter = Presenter(location)
            NSFileCoordinator.addFilePresenter(presenter)
            var registered = true
            defer { if registered { NSFileCoordinator.removeFilePresenter(presenter) } }
            let began = ContinuousClock.now
            for _ in 0..<4 {
                var error: NSError?
                NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: root, options: [], error: &error) { _ in () }
                if let error { throw error }
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: root, options: [], error: &error) { _ in () }
                if let error { throw error }
            }
            print("\(label): four empty write/read pairs = \(began.duration(to: .now))")
            var error: NSError?, entered = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: root, options: .forDeleting, error: &error) { _ in entered = true }
            guard error != nil, !entered else { throw ProbeError.guardFailed }
            print("\(label): parent deletion refused")
            NSFileCoordinator.removeFilePresenter(presenter)
            registered = false
            error = nil
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: root, options: .forDeleting, error: &error) { _ in entered = true }
            guard error == nil, entered else { throw ProbeError.guardFailed }
            print("\(label): parent deletion admitted after unregistering")
        }
    }
}

#else
#error("Build this experimental probe with GRAPHEVO_BUILD_LABS=1 and -D GRAPHEVO_BUILD_LABS.")
#endif
