import GraphEvoModel

extension GraphReadScope {
    private func executeQuery(_ request: GraphQueryRequest) throws -> GraphQueryOutput {
        try withContext { context, adapter in
            guard let execute = adapter.query else { throw GraphQueryError.unsupportedStorage }
            return try execute(context, graphID, request)
        }
    }
    public func traverse(_ traversal: GraphTraversal) throws -> GraphTraversalResult {
        let output = try executeQuery(traversal.request)
        return GraphTraversalResult(visits: output.visits, view: queryView, diagnostics: output.diagnostics)
    }
    /// Detached immutable records for the opt-in shared observation laboratory.
    package func observationOutput<Model: GraphModel>(_ query: GraphQuery<Model>) throws -> (GraphQueryOutput, GraphQueryLocalView) {
        (try executeQuery(query.request), queryView)
    }
    public func query<Model: GraphModel>(_ query: GraphQuery<Model>) throws -> GraphQueryResult<Model> {
        let output = try executeQuery(query.request)
        return try GraphQueryResult(items: output.records.map { try $0.decoded(as: Model.self) }, nextCursor: output.cursor, view: queryView, diagnostics: output.diagnostics)
    }
    /// Counts the full filtered set within the explicit budget, ignoring ordering/limit. Cursors are rejected.
    public func count<Model: GraphModel>(_ query: GraphQuery<Model>) throws -> GraphQueryCount {
        var request = query.request; request.operation = .count
        let output = try executeQuery(request)
        return GraphQueryCount(value: output.count, view: queryView, diagnostics: output.diagnostics)
    }
    public func project<Model: GraphModel>(_ query: GraphQuery<Model>, properties: Set<String>) throws -> GraphQueryProjectionResult {
        var request = query.request; request.operation = .projection(properties)
        let output = try executeQuery(request)
        return GraphQueryProjectionResult(rows: output.records.map { record in
            GraphQueryProjection(id: record.id, values: record.properties.filter { properties.contains($0.key) })
        }, nextCursor: output.cursor, view: queryView, diagnostics: output.diagnostics)
    }
    /// Aggregates the full filtered set, ignoring ordering/limit. Null/missing values do not contribute.
    public func aggregate<Model: GraphModel>(_ query: GraphQuery<Model>, _ aggregate: GraphQueryAggregate) throws -> GraphQueryAggregateResult {
        var request = query.request; request.operation = .aggregate(aggregate)
        let output = try executeQuery(request)
        return GraphQueryAggregateResult(value: output.aggregate, contributingCount: output.count, view: queryView, diagnostics: output.diagnostics)
    }
}

extension GraphStore {
    package func sharedObservationOutput<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> (GraphQueryOutput, GraphQueryLocalView) {
        try await read { try $0.observationOutput(query) }
    }
    public func traverse(_ traversal: GraphTraversal) async throws -> GraphTraversalResult { try await read { try $0.traverse(traversal) } }

    public func query<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphQueryResult<Model> { try await read { try $0.query(query) } }
    public func count<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphQueryCount { try await read { try $0.count(query) } }
    public func project<Model: GraphModel>(_ query: GraphQuery<Model>, properties: Set<String>) async throws -> GraphQueryProjectionResult {
        try await read { try $0.project(query, properties: properties) }
    }
    public func aggregate<Model: GraphModel>(_ query: GraphQuery<Model>, _ aggregate: GraphQueryAggregate) async throws -> GraphQueryAggregateResult {
        try await read { try $0.aggregate(query, aggregate) }
    }
}
