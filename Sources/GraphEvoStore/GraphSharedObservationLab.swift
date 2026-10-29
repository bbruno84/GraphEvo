import GraphEvoModel
import GraphEvoRuntime

/// Explicit independent coordinator retained for reproducible C04a laboratory tests.
/// Public observations use a different coordinator owned by their GraphStore handle.
package final class GraphSharedObservationLab: Sendable {
    private let graph: GraphStore
    private let coordinator: GraphObservationCoordinator

    package init(graph: GraphStore, source: (@Sendable () async throws -> StoreInvalidationFeed)? = nil,
                 beforeRead: @escaping @Sendable () async -> Void = {}) {
        self.graph = graph
        coordinator = GraphObservationCoordinator(graph: graph, source: source, beforeRead: beforeRead)
    }
    package var diagnostics: GraphSharedObservationSnapshot {
        get async { await coordinator.diagnostics }
    }
    package func observe<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphObservation<GraphQueryState<Model>> {
        try await coordinator.observe(query)
    }
    package nonisolated func publisher<Model: GraphModel>(for query: GraphQuery<Model>) -> GraphObservationPublisher<GraphQueryState<Model>> {
        GraphObservationPublisher { try await self.observe(query) }
    }
}
