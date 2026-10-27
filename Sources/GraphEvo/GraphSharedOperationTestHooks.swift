#if DEBUG
import Foundation
import os

/// Internal fault injection at the actual native assignment/local finalization boundary.
/// Release builds contain no hook. Ordinary debug operation has no installed handler.
enum GraphSharedOperationTestHooks {
    typealias Handler = @Sendable (UUID, GraphID) async throws -> Void
    private static let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    static func setAfterAssignment(_ value: Handler?) { handler.withLock { $0 = value } }

    static func didAssign(_ id: UUID, graphID: GraphID) async throws {
        let callback = handler.withLock { $0 }
        try await callback?(id, graphID)
    }
}
#endif
