import Foundation

/// Bounded breadth-first traversal over application Entity endpoints, excluding the origins.
public struct GraphTraversal: Sendable {
    public let origins: [GraphNodeID]
    public let relation: GraphQueryRelation
    public let maximumDepth: Int
    public let budget: GraphQueryBudget
    public init(from origins: [GraphNodeID], via relation: GraphQueryRelation, maximumDepth: Int, budget: GraphQueryBudget) throws {
        guard !origins.isEmpty, (0...32).contains(maximumDepth) else { throw GraphQueryError.invalidTraversal }
        guard origins.count <= budget.maximumCandidates else { throw GraphQueryError.budgetExceeded(.candidates) }
        self.origins = origins; self.relation = relation; self.maximumDepth = maximumDepth; self.budget = budget
    }
    package var request: GraphQueryRequest {
        var request = GraphQueryRequest(definition: GraphQueryDefinition(type: "GraphEvo.Traversal", kind: .entity), budget: budget, limit: nil, cursor: nil)
        request.operation = .traversal(self)
        return request
    }
}
public struct GraphTraversalVisit: Sendable, Equatable {
    public let id: GraphNodeID
    public let depth: Int
    package init(id: GraphNodeID, depth: Int) { self.id = id; self.depth = depth }
}
public struct GraphTraversalResult: Sendable {
    public let visits: [GraphTraversalVisit]
    public let view: GraphQueryLocalView
    public let diagnostics: GraphQueryDiagnostics
    package init(visits: [GraphTraversalVisit], view: GraphQueryLocalView, diagnostics: GraphQueryDiagnostics) {
        self.visits = visits; self.view = view; self.diagnostics = diagnostics
    }
}
