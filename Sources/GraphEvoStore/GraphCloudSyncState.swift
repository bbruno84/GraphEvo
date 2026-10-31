import Foundation
import GraphEvoModel

/// Process-local graph synchronization admission, distinct from store access and engine shutdown.
package enum GraphCloudSyncState: Sendable, Equatable {
    case active, pauseRequested, paused
}

struct GraphCloudSyncPermit: Sendable {
    let graphID: GraphID
    let id: UUID
}

struct GraphCloudSyncControl: Sendable {
    var state: GraphCloudSyncState = .active
    var operations = Set<UUID>()
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var observers: [UUID: AsyncStream<GraphCloudSyncState>.Continuation] = [:]
}
