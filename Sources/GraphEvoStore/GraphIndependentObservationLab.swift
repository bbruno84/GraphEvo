import Foundation
import GraphEvoModel

extension GraphStore {
    /// Retained A8 control for cost comparisons, never selected by public observe/publisher.
    package func observeIndependently<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphObservation<GraphQueryState<Model>> {
        guard query.cursor == nil else { throw GraphQueryError.invalidCursor }
        try GraphQueryValidation.request(query.request, graphID: id)
        let feed = try await observationFeed()
        let pair = AsyncStream<GraphQueryState<Model>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let control = GraphObservationControl()
        pair.continuation.onTermination = { [weak control] _ in control?.cancel() }
        let worker = Task { [self] in
            defer { pair.continuation.finish() }
            for await invalidation in feed.stream {
                guard !Task.isCancelled else { break }
                if case .accountChange = invalidation.reason {
                    pair.continuation.yield(.failure(GraphObservationError.accountChanged))
                    break
                }
                do {
                    let result = try await self.query(query)
                    guard !Task.isCancelled else { break }
                    pair.continuation.yield(.value(result))
                } catch is CancellationError { break }
                catch {
                    if case GraphStoreError.closed = error { break }
                    guard !Task.isCancelled else { break }
                    pair.continuation.yield(.failure(error))
                }
            }
        }
        control.install(worker, refresh: feed.refresh, finish: { pair.continuation.finish() })
        return GraphObservation(stream: pair.stream, control: control)
    }
}
