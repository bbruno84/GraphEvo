import Foundation
import GraphEvoModel

/// Durable progress of an accepted native invitation, separate from replica contents.
public struct GraphCloudJoinState: Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case acceptancePending, discoveringGraph, ready, openingReplica, joined, discarding, discarded
    }
    public let id: UUID
    public let graphID: GraphID?
    public let phase: Phase
    public let failure: GraphCloudConnectionFailure?
}

struct GraphCloudJoinIntent: Codable, Sendable {
    let id: UUID
    let invitation: GraphCloudNativeInvitation
    var graphID: GraphID?
    var phase: GraphCloudJoinState.Phase = .acceptancePending
    var failure = false
    var status: GraphCloudJoinState {
        .init(id: id, graphID: graphID, phase: phase, failure: failure ? .init(category: .recoveryRequired) : nil)
    }
    func validate() throws {
        guard invitation.url.scheme == "https", invitation.url.host?.isEmpty == false,
              invitation.url.absoluteString.utf8.count <= 4096,
              invitation.zone.scope == .shared, invitation.owner == invitation.zone.owner,
              !invitation.owner.isEmpty, !invitation.zone.name.isEmpty,
              invitation.owner.utf8.count <= 4096, invitation.zone.name.utf8.count <= 4096,
              graphID != nil || [.acceptancePending, .discoveringGraph, .discarding, .discarded].contains(phase) else {
            throw GraphCloudDiscoveryError.invalidJoin
        }
    }
}

/// A lease over durable joining progress. Dropping it never undoes native acceptance.
@available(iOS 17, macOS 14, *)
public actor GraphCloudJoin {
    public nonisolated let id: UUID
    let connection: GraphCloudConnection
    nonisolated let contextIdentity: UUID
    nonisolated let namespace: String
    init(id: UUID, connection: GraphCloudConnection, contextIdentity: UUID, namespace: String) {
        self.id = id; self.connection = connection; self.contextIdentity = contextIdentity; self.namespace = namespace
    }
    /// Current durable phase; ready means identity discovery, not imported application data.
    public var state: GraphCloudJoinState { get async throws { try await connection.joinState(id) } }
    /// Observes initial/newest values until cancelled or the originating connection closes.
    public func observeState() async throws -> GraphObservation<GraphCloudJoinState> { try await connection.observeJoin(id) }
    /// Resumes the existing native intent without replaying application code.
    public func retry() async throws { try await connection.retryJoin(id) }
}
