import Foundation

/// Conservative property dependencies; membership and endpoint inventory remain complete.
package struct GraphQueryPropertyPlan {
    private let definition: GraphQueryDefinition
    private let fullRecords: Bool
    package let referencedKeys: Set<String>

    package init(_ request: GraphQueryRequest) {
        definition = request.definition
        var needed = Set<String>()
        func collect(_ predicate: GraphQueryPredicate) {
            switch predicate {
            case .exists(let key), .property(let key, _, _): needed.insert(key)
            case .and(let values), .or(let values): values.forEach(collect)
            case .not(let value), .related(_, let value): collect(value)
            default: break
            }
        }
        collect(request.definition.predicate)
        for sort in request.definition.sorts {
            if case .property(let key) = sort.key { needed.insert(key) }
        }
        switch request.operation {
        case .records: fullRecords = true
        case .projection(let projected): fullRecords = false; needed.formUnion(projected)
        case .aggregate(let aggregate):
            fullRecords = false
            switch aggregate { case .sum(let key), .minimum(let key), .maximum(let key): needed.insert(key) }
        case .count, .traversal: fullRecords = false
        }
        referencedKeys = needed
    }

    /// Nil means complete payloads for returned models. Other nodes retain every referenced key.
    package func properties(type: String, kind: GraphNodeKind) -> Set<String>? {
        if fullRecords && type == definition.type && kind == definition.kind { return nil }
        return referencedKeys
    }
}
