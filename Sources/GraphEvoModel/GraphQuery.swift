import Foundation

/// Explicit work allowance; this alpha inventories native node rows across the open resource group.
public struct GraphQueryBudget: Sendable, Equatable {
    public let maximumCandidates: Int
    public let maximumPropertyBytes: Int
    public let maximumSteps: Int
    public init(maximumCandidates: Int, maximumPropertyBytes: Int = 32 * 1024 * 1024, maximumSteps: Int = 100_000) throws {
        guard maximumCandidates > 0, maximumCandidates < Int.max,
              maximumPropertyBytes >= 0, maximumSteps > 0 else { throw GraphQueryError.invalidBudget }
        self.maximumCandidates = maximumCandidates; self.maximumPropertyBytes = maximumPropertyBytes; self.maximumSteps = maximumSteps
    }
}
public enum GraphQueryBudgetDimension: Sendable, Equatable { case candidates, propertyBytes, steps }
public enum GraphQueryError: Error, Equatable {
    case invalidBudget, invalidLimit, invalidPropertyName, invalidModelType, invalidTraversal, invalidOrigin, unsupportedValue, unsupportedComparison
    case incomparableValues, foreignGraph, invalidCursor, expressionTooComplex, arithmeticOverflow, unsupportedStorage
    case budgetExceeded(GraphQueryBudgetDimension)
}
public enum GraphQueryComparison: Sendable, Equatable {
    case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual, beginsWith, contains
}
public enum GraphQueryRelation: Sendable, Equatable {
    case outgoing(String?), incoming(String?), actionObjects(String?), actionSubjects(String?)
}
public indirect enum GraphQueryPredicate: Sendable, Equatable {
    case all, none
    case id(GraphNodeID), type(String), tag(String), group(String), exists(String)
    case property(String, GraphQueryComparison, GraphValue)
    case subject(GraphNodeID), object(GraphNodeID)
    case and([GraphQueryPredicate]), or([GraphQueryPredicate]), not(GraphQueryPredicate)
    case related(GraphQueryRelation, matching: GraphQueryPredicate)
}
public func &&(lhs: GraphQueryPredicate, rhs: GraphQueryPredicate) -> GraphQueryPredicate { .and([lhs, rhs]) }
public func ||(lhs: GraphQueryPredicate, rhs: GraphQueryPredicate) -> GraphQueryPredicate { .or([lhs, rhs]) }
public prefix func !(value: GraphQueryPredicate) -> GraphQueryPredicate { .not(value) }

public enum GraphQuerySortKey: Sendable, Equatable { case identity, createdDate, property(String) }
public enum GraphQuerySortDirection: Sendable, Equatable { case ascending, descending }
public enum GraphQueryMissingValues: Sendable, Equatable { case first, last }
public struct GraphQuerySort: Sendable, Equatable {
    public let key: GraphQuerySortKey
    public let direction: GraphQuerySortDirection
    public let missing: GraphQueryMissingValues
    public init(_ key: GraphQuerySortKey, direction: GraphQuerySortDirection = .ascending, missing: GraphQueryMissingValues = .last) {
        self.key = key; self.direction = direction; self.missing = missing
    }
}
public enum GraphQueryAggregate: Sendable { case sum(String), minimum(String), maximum(String) }

package struct GraphQueryDefinition: Sendable, Equatable {
    package let type: String
    package let kind: GraphNodeKind
    package var predicate: GraphQueryPredicate = .all
    package var sorts: [GraphQuerySort] = []
}
/// Opaque descriptor-bound moving-current-state cursor. Not a portable or frozen snapshot token.
public struct GraphQueryCursor: Sendable {
    package let graphID: GraphID
    package let definition: GraphQueryDefinition
    package let values: [GraphValue?]
    package let lastID: GraphNodeID
    package init(graphID: GraphID, definition: GraphQueryDefinition, values: [GraphValue?], lastID: GraphNodeID) {
        self.graphID = graphID; self.definition = definition; self.values = values; self.lastID = lastID
    }
}
public struct GraphQuery<Model: GraphModel>: Sendable {
    package var definition: GraphQueryDefinition
    public let budget: GraphQueryBudget
    package var rowLimit: Int?
    package var cursor: GraphQueryCursor?
    public init(_ model: Model.Type = Model.self, budget: GraphQueryBudget) {
        definition = GraphQueryDefinition(type: Model.graphType, kind: Model.graphKind); self.budget = budget
    }
    /// Successive filters combine with AND; OR requires an explicit expression.
    public func `where`(_ predicate: GraphQueryPredicate) -> Self {
        var copy = self
        switch definition.predicate {
        case .all: copy.definition.predicate = predicate
        case .and(let previous): copy.definition.predicate = .and(previous + [predicate])
        default: copy.definition.predicate = .and([definition.predicate, predicate])
        }
        return copy
    }
    public func sorted(by sorts: [GraphQuerySort]) -> Self { var copy = self; copy.definition.sorts = sorts; return copy }
    public func limit(_ count: Int) -> Self { var copy = self; copy.rowLimit = count; return copy }
    public func after(_ cursor: GraphQueryCursor) -> Self { var copy = self; copy.cursor = cursor; return copy }
    public func explain() throws -> GraphQueryPlan {
        try GraphQueryValidation.validate(definition, limit: rowLimit)
        return GraphQueryPlan(budget: budget)
    }
    package var request: GraphQueryRequest { GraphQueryRequest(definition: definition, budget: budget, limit: rowLimit, cursor: cursor) }
}
public struct GraphQueryPlan: Sendable {
    /// The current schema requires explicit bounded inventory and in-memory evaluation, including projections/counts.
    public enum Strategy: Sendable, Equatable { case boundedInventoryAndMemory }
    public let strategy: Strategy = .boundedInventoryAndMemory
    public let budget: GraphQueryBudget
    package init(budget: GraphQueryBudget) { self.budget = budget }
}
/// Execution identity, not a native generation, cloud completeness marker or multi-page snapshot.
public struct GraphQueryLocalView: Sendable, Equatable {
    public let graphID: GraphID
    public let scopeID: UUID
    public let includesPendingChanges: Bool
    package init(graphID: GraphID, scopeID: UUID, includesPendingChanges: Bool) {
        self.graphID = graphID; self.scopeID = scopeID; self.includesPendingChanges = includesPendingChanges
    }
}
public struct GraphQueryDiagnostics: Sendable {
    public let nativeCandidates: Int
    public let scopedNodes: Int
    public let propertyBytesCharged: Int
    public let evaluationSteps: Int
    package init(nativeCandidates: Int, scopedNodes: Int, propertyBytesCharged: Int, evaluationSteps: Int) {
        self.nativeCandidates = nativeCandidates; self.scopedNodes = scopedNodes
        self.propertyBytesCharged = propertyBytesCharged; self.evaluationSteps = evaluationSteps
    }
}
public struct GraphQueryResult<Model: GraphModel>: Sendable {
    public let items: [Model]
    public let nextCursor: GraphQueryCursor?
    public let view: GraphQueryLocalView
    public let diagnostics: GraphQueryDiagnostics
    package init(items: [Model], nextCursor: GraphQueryCursor?, view: GraphQueryLocalView, diagnostics: GraphQueryDiagnostics) {
        self.items = items; self.nextCursor = nextCursor; self.view = view; self.diagnostics = diagnostics
    }
}
public struct GraphQueryProjection: Sendable {
    public let id: GraphNodeID
    public let values: [String: GraphValue]
    package init(id: GraphNodeID, values: [String: GraphValue]) { self.id = id; self.values = values }
}
public struct GraphQueryProjectionResult: Sendable {
    public let rows: [GraphQueryProjection]
    public let nextCursor: GraphQueryCursor?
    public let view: GraphQueryLocalView
    public let diagnostics: GraphQueryDiagnostics
    package init(rows: [GraphQueryProjection], nextCursor: GraphQueryCursor?, view: GraphQueryLocalView, diagnostics: GraphQueryDiagnostics) {
        self.rows = rows; self.nextCursor = nextCursor; self.view = view; self.diagnostics = diagnostics
    }
}
public struct GraphQueryCount: Sendable {
    public let value: Int
    public let view: GraphQueryLocalView
    public let diagnostics: GraphQueryDiagnostics
    package init(value: Int, view: GraphQueryLocalView, diagnostics: GraphQueryDiagnostics) {
        self.value = value; self.view = view; self.diagnostics = diagnostics
    }
}
public struct GraphQueryAggregateResult: Sendable {
    public let value: GraphValue?
    public let contributingCount: Int
    public let view: GraphQueryLocalView
    public let diagnostics: GraphQueryDiagnostics
    package init(value: GraphValue?, contributingCount: Int, view: GraphQueryLocalView, diagnostics: GraphQueryDiagnostics) {
        self.value = value; self.contributingCount = contributingCount; self.view = view; self.diagnostics = diagnostics
    }
}
package enum GraphQueryOperation: Sendable { case records, count, projection(Set<String>), aggregate(GraphQueryAggregate), traversal(GraphTraversal) }
package struct GraphQueryRequest: Sendable {
    package let definition: GraphQueryDefinition
    package let budget: GraphQueryBudget
    package let limit: Int?
    package let cursor: GraphQueryCursor?
    package var operation: GraphQueryOperation = .records
}
package struct GraphQueryOutput: Sendable {
    package let records: [GraphRecord]
    package let cursor: GraphQueryCursor?
    package let count: Int
    package let aggregate: GraphValue?
    package let diagnostics: GraphQueryDiagnostics
    package var visits: [GraphTraversalVisit] = []
}

extension GraphQueryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBudget: return "The query budget is invalid."
        case .invalidLimit: return "A query page limit must be positive."
        case .invalidPropertyName: return "A query property name is empty or reserved."
        case .invalidModelType: return "The query model type is empty or reserved."
        case .invalidTraversal: return "Traversal requires origins and a depth from zero through 32."
        case .invalidOrigin: return "A traversal origin is not an available application Entity."
        case .unsupportedValue: return "This query value type or non-finite value is unsupported."
        case .unsupportedComparison: return "The requested comparison or aggregation is unsupported."
        case .incomparableValues: return "Ordered query values must have the same supported scalar type."
        case .foreignGraph: return "A query reference belongs to another logical graph."
        case .invalidCursor: return "The cursor does not match this graph, descriptor or operation."
        case .expressionTooComplex: return "The query exceeds its expression, relation or field complexity limit."
        case .arithmeticOverflow: return "The query aggregation overflowed its numeric representation."
        case .unsupportedStorage: return "This store adapter does not support bounded query execution."
        case .budgetExceeded: return "The query exceeded its explicit work allowance; no partial result is returned."
        }
    }
}
