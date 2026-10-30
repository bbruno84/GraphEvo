import Foundation

/// Conservative property dependencies; membership and endpoint inventory remain complete.
package struct GraphQueryPropertyPlan {
    private let definition: GraphQueryDefinition
    private let fullRecords: Bool
    private let guardedIDs: Set<GraphNodeID>?
    package let referencedKeys: Set<String>

    package init(_ request: GraphQueryRequest) {
        definition = request.definition
        var needed = Set<String>()
        var hasRelated = false
        func collect(_ predicate: GraphQueryPredicate) {
            switch predicate {
            case .exists(let key), .property(let key, _, _): needed.insert(key)
            case .and(let values), .or(let values): values.forEach(collect)
            case .not(let value): collect(value)
            case .related(_, let value): hasRelated = true; collect(value)
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
        if case .traversal = request.operation { guardedIDs = nil }
        else { guardedIDs = hasRelated ? nil : Self.identityGuard(definition.predicate) }
    }

    /// Nil means complete payloads. Excluded IDs retain structural inventory but no property bodies.
    package func properties(type: String, kind: GraphNodeKind, id: GraphNodeID? = nil) -> Set<String>? {
        if type == definition.type, kind == definition.kind, let id, let guardedIDs, !guardedIDs.contains(id) { return [] }
        if fullRecords && type == definition.type && kind == definition.kind { return nil }
        return referencedKeys
    }
    /// A bound is usable only when excluded records fail before any property access.
    /// Keep Boolean evaluation order: a later ID must not hide an earlier property error.
    private static func identityGuard(_ predicate: GraphQueryPredicate) -> Set<GraphNodeID>? {
        switch predicate {
        case .id(let id): return [id]
        case .none: return []
        case .and(let values):
            for value in values {
                if let ids = identityGuard(value) { return ids }
                guard propertyFree(value) else { return nil }
            }
            return nil
        case .or(let values):
            var result = Set<GraphNodeID>()
            for value in values {
                guard let ids = identityGuard(value) else { return nil }
                result.formUnion(ids)
            }
            return result
        default: return nil
        }
    }

    private static func propertyFree(_ predicate: GraphQueryPredicate) -> Bool {
        switch predicate {
        case .all, .none, .type, .id, .tag, .group, .subject, .object: return true
        case .and(let values), .or(let values): return values.allSatisfy(propertyFree)
        case .not(let value): return propertyFree(value)
        case .exists, .property, .related: return false
        }
    }
}
