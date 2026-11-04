import Foundation
import GraphEvoModel

/// Independently closeable consumer interest in context-owned cloud transport.
@available(iOS 17, macOS 14, *)
public actor GraphCloudConnection {
    var owningContext: GraphContext { context }
    private let context: GraphContext
    private let namespace: String
    private let token: UUID
    private let hub: GraphCloudConnectionHub
    private var closing: Task<Void, any Error>?
    init(context: GraphContext, namespace: String, token: UUID, hub: GraphCloudConnectionHub) {
        self.context = context; self.namespace = namespace; self.token = token; self.hub = hub
    }
    deinit {
        hub.finish(owner: token)
        let context = context, namespace = namespace, token = token
        if closing == nil { Task { try? await context.releaseConnection(namespace, token: token) } }
    }
    /// Current account/session state, independent of graph import or remote completion.
    public var state: GraphCloudConnectionState {
        get async throws { try await check(); return hub.current }
    }
    /// Observes initial/newest state until cancellation or this lease closes.
    public func observeState() async throws -> GraphObservation<GraphCloudConnectionState> {
        try await check(); return hub.observe(owner: token)
    }
    /// Schedules a new startup/account check without replaying application work.
    public func retry() async throws { try await check(); try await context.retry(namespace, token: token) }
    /// Explicitly binds a graph from this context to a private zone.
    public func bindPrivateGraph(_ graph: GraphStore, zoneName: String) async throws {
        try await check()
        do { try await context.bind(graph, zoneName: zoneName, key: namespace, token: token) }
        catch { throw GraphCloudConnectionError.translate(error) }
    }
    /// Requests a synchronization turn; return is not a completion barrier.
    public func requestSynchronization() async throws {
        let config = try await ready()
        try await operation { try await context.manager.requestCloudSynchronization(configuration: config) }
    }
    /// Forwards a notification already matched by the host to this container.
    public func notifyRemoteChanges(in scope: GraphCloudScope) async throws {
        let config = try await ready()
        try await operation { try await context.manager.notifyRemoteCloudChanges(in: scope, configuration: config) }
    }
    /// Drains this graph's admitted synchronization work without stopping unrelated graphs.
    public func pauseSynchronization(for graphID: GraphID) async throws {
        let config = try await ready()
        try await operation {
            guard try await context.manager.cloud(config).routes(in: .private).contains(where: { $0.graphID == graphID }) else { throw GraphStoreError.foreignGraph }
            try await context.manager.pauseCloudSynchronization(for: graphID)
        }
    }
    /// Resumes synchronization without changing account, permission or migration restrictions.
    public func resumeSynchronization(for graphID: GraphID) async throws {
        let config = try await ready()
        try await operation {
            guard try await context.manager.cloud(config).routes(in: .private).contains(where: { $0.graphID == graphID }) else { throw GraphStoreError.foreignGraph }
            try await context.manager.resumeCloudSynchronization(for: graphID)
        }
    }
    /// Releases this lease; final release awaits native stop without erasing data.
    public func close() async throws {
        if let closing { return try await closing.value }
        hub.finish(owner: token)
        let context = context, namespace = namespace, token = token
        let task = Task {
            do { try await context.releaseConnection(namespace, token: token) }
            catch { throw GraphCloudConnectionError.translate(error) }
        }
        closing = task
        try await task.value
    }
    private func check() async throws {
        guard closing == nil else { throw GraphCloudConnectionError.closed }
        _ = try await context.configuration(namespace, token: token)
        guard closing == nil else { throw GraphCloudConnectionError.closed }
    }
    func ready() async throws -> GraphCloudConfiguration {
        try await check(); return try await context.requireReady(namespace, token: token)
    }
    func operation<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw GraphCloudConnectionError.translate(error) }
    }
}
