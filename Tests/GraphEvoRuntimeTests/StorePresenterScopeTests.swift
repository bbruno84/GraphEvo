import Foundation
import Testing
@testable import GraphEvoRuntime

private final class PresenterScopeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func mark() { lock.withLock { entered = true } }
    var value: Bool { lock.withLock { entered } }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct StorePresenterScopeTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PresenterScope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: AppGroupOwnerClaims.presentationURL(anchor: root),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func lifetimeRegistrationSurvivesMetadataReplacementAndFencesParentDeletion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presenter = AppGroupStorePresenter(directory: root, directoryIdentity: try SQLiteStoreCoordination.identity(root))
        let registration = try #require(presenter.presentedItemURL)
        #expect(registration == AppGroupOwnerClaims.presentationURL(anchor: root))
        #expect(presenter.coordinationDirectory == root)
        let identity = try SQLiteStoreCoordination.identity(registration)
        let claim = registration.appendingPathComponent(presenter.generation.uuidString)
        try Data([1]).write(to: claim)
        presenter.register()
        var registered = true
        defer { if registered { presenter.unregister() } }
        try await AppGroupStoreAccess(presenter: presenter).run { try Data([2]).write(to: claim, options: .atomic) }
        #expect(try SQLiteStoreCoordination.identity(registration) == identity)
        #expect(try await AppGroupStoreAccess(presenter: presenter, associatePresenter: false, reading: true).run {
            try Data(contentsOf: claim)
        } == Data([2]))
        await #expect(throws: AppGroupAccessDenied.self) {
            try await AppGroupStoreAccess(presenter: presenter, associatePresenter: false,
                options: .forDeleting, reportDenial: true).run { true }
        }
        presenter.unregister()
        registered = false
        // A retained ledger file is not an Apple ownership claim after native detachment.
        #expect(FileManager.default.fileExists(atPath: claim.path))
        #expect(try await AppGroupStoreAccess(presenter: presenter, associatePresenter: false,
            options: .forDeleting, reportDenial: true).run { true })
    }

    @Test(arguments: [false, true])
    func readerAndWriterStillExcludeEachOther(readerFirst: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presenter = AppGroupStorePresenter(directory: root)
        presenter.register()
        defer { presenter.unregister() }
        let entered = AsyncStream<Void>.makeStream(), submitted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0), follower = PresenterScopeFlag()
        defer { release.signal() }
        let first = Task {
            try await AppGroupStoreAccess(presenter: presenter, associatePresenter: !readerFirst, reading: readerFirst).run {
                entered.continuation.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw StoreRuntimeError.resourceReserved }
                return true
            }
        }
        var arrivals = entered.stream.makeAsyncIterator(); _ = await arrivals.next()
        let second = Task {
            try await AppGroupStoreAccess(presenter: presenter, associatePresenter: readerFirst, reading: !readerFirst,
                onSubmit: { submitted.continuation.yield(()) }).run { follower.mark(); return true }
        }
        var requests = submitted.stream.makeAsyncIterator(); _ = await requests.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!follower.value)
        release.signal()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(follower.value)
    }

    @Test func queuedReaderCancellationDoesNotNeedTheWriterToRelease() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presenter = AppGroupStorePresenter(directory: root)
        presenter.register()
        defer { presenter.unregister() }
        let entered = AsyncStream<Void>.makeStream(), submitted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0), readerEntered = PresenterScopeFlag()
        defer { release.signal() }
        let writer = Task {
            try await AppGroupStoreAccess(presenter: presenter).run {
                entered.continuation.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw StoreRuntimeError.resourceReserved }
            }
        }
        var arrivals = entered.stream.makeAsyncIterator(); _ = await arrivals.next()
        let reader = Task {
            try await AppGroupStoreAccess(presenter: presenter, associatePresenter: false, reading: true,
                onSubmit: { submitted.continuation.yield(()) }).run { readerEntered.mark() }
        }
        var requests = submitted.stream.makeAsyncIterator(); _ = await requests.next()
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(!readerEntered.value)
        release.signal()
        try await writer.value
    }
}
