import Dispatch
import Foundation
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct CoordinatedFilesTests {
    @Test func cancellationReachesAnActiveAccessorAndReleasesTheGrant() async throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = AsyncStream<Void>.makeStream()
        let proceed = DispatchSemaphore(value: 0)
        let operation = Task {
            defer { entered.continuation.finish() }
            try await CoordinatedFiles.run([.read(root)]) { checkCancellation in
                entered.continuation.yield(())
                guard proceed.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.fileReadUnknown)
                }
                try checkCancellation()
            }
        }
        var observer = entered.stream.makeAsyncIterator()
        try #require(await observer.next() != nil)
        operation.cancel()
        proceed.signal()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let marker = root.appendingPathComponent("Next")
        try await CoordinatedFiles.run([.write(root)]) { try Data([1]).write(to: marker) }
        #expect(try Data(contentsOf: marker) == Data([1]))
    }
}
