#if DEBUG
@testable import GraphEvo

/// Only this recovery control uses an internal seam; normal stages consume public APIs.
@MainActor enum A5RecoveryProbeControl {
    static func pauseAfterAssignment(graphID: GraphID, checkpoint: @escaping @MainActor @Sendable () async throws -> Void) {
        GraphSharedOperationTestHooks.setAfterAssignment { _, selected in
            guard selected == graphID else { return }
            try await checkpoint()
            // The coordinator terminates this app process after observing the checkpoint.
            while true { try await Task.sleep(for: .seconds(10)) }
        }
    }
}
#endif
