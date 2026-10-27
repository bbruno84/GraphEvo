import Foundation

package enum GraphQueryValidation {
    package static func key(_ key: String) throws {
        guard !key.isEmpty, !key.hasPrefix("__graphevo_v2.") else { throw GraphQueryError.invalidPropertyName }
    }
    package static func validate(_ definition: GraphQueryDefinition, limit: Int?, graphID: GraphID? = nil) throws {
        guard limit == nil || limit! > 0 else { throw GraphQueryError.invalidLimit }
        guard !definition.type.isEmpty, !definition.type.hasPrefix("__graphevo_v2.") else { throw GraphQueryError.invalidModelType }
        guard definition.sorts.count <= 8 else { throw GraphQueryError.expressionTooComplex }
        var nodes = 0
        func expression(_ predicate: GraphQueryPredicate, depth: Int, hops: Int, kind: GraphNodeKind) throws {
            nodes += 1
            guard nodes <= 256, depth <= 32, hops <= 4 else { throw GraphQueryError.expressionTooComplex }
            switch predicate {
            case .all, .none, .type, .tag, .group: break
            case .id(let id): if let graphID, id.graphID != graphID { throw GraphQueryError.foreignGraph }
            case .subject(let id), .object(let id):
                guard kind != .entity else { throw GraphQueryError.unsupportedComparison }
                if let graphID, id.graphID != graphID { throw GraphQueryError.foreignGraph }
            case .exists(let name): try key(name)
            case .property(let name, let op, let value):
                try key(name); try GraphQueryScalar.validate(value)
                switch op {
                case .equal, .notEqual: break
                case .beginsWith, .contains: guard case .string = value else { throw GraphQueryError.unsupportedComparison }
                default: try GraphQueryScalar.ordered(value)
                }
            case .and(let values), .or(let values): for value in values { try expression(value, depth: depth + 1, hops: hops, kind: kind) }
            case .not(let value): try expression(value, depth: depth + 1, hops: hops, kind: kind)
            case .related(_, let matching):
                guard kind == .entity else { throw GraphQueryError.unsupportedComparison }
                try expression(matching, depth: depth + 1, hops: hops + 1, kind: .entity)
            }
        }
        try expression(definition.predicate, depth: 0, hops: 0, kind: definition.kind)
        for sort in definition.sorts { if case .property(let name) = sort.key { try key(name) } }
    }
    package static func request(_ request: GraphQueryRequest, graphID: GraphID) throws {
        try validate(request.definition, limit: request.limit, graphID: graphID)
        if let cursor = request.cursor {
            guard request.limit != nil, cursor.graphID == graphID, cursor.lastID.graphID == graphID,
                  cursor.definition == request.definition, cursor.values.count == request.definition.sorts.count else { throw GraphQueryError.invalidCursor }
        }
        switch request.operation {
        case .records: break
        case .traversal(let traversal):
            guard traversal.origins.allSatisfy({ $0.graphID == graphID }) else { throw GraphQueryError.foreignGraph }
        case .projection(let keys):
            guard keys.count <= 128 else { throw GraphQueryError.expressionTooComplex }
            for name in keys { try key(name) }
        case .count: guard request.cursor == nil else { throw GraphQueryError.invalidCursor }
        case .aggregate(let aggregate):
            guard request.cursor == nil else { throw GraphQueryError.invalidCursor }
            switch aggregate { case .sum(let key), .minimum(let key), .maximum(let key): try self.key(key) }
        }
    }
}

package enum GraphQueryScalar {
    package static func validate(_ value: GraphValue) throws {
        switch value {
        case .null, .boolean, .integer, .unsignedInteger, .string, .uuid, .url: break
        case .floatingPoint(let n): guard n.isFinite else { throw GraphQueryError.unsupportedValue }
        case .decimal(let n): guard !n.isNaN else { throw GraphQueryError.unsupportedValue }
        case .date(let date): guard date.timeIntervalSinceReferenceDate.isFinite else { throw GraphQueryError.unsupportedValue }
        default: throw GraphQueryError.unsupportedValue
        }
    }
    package static func ordered(_ value: GraphValue) throws {
        try validate(value)
        switch value { case .null, .uuid, .url: throw GraphQueryError.unsupportedComparison; default: break }
    }
    package static func compare(_ left: GraphValue, _ right: GraphValue) throws -> Int {
        try ordered(left); try ordered(right)
        func order<T: Comparable>(_ a: T, _ b: T) -> Int { a == b ? 0 : a < b ? -1 : 1 }
        switch (left, right) {
        case (.boolean(let a), .boolean(let b)): return a == b ? 0 : a ? 1 : -1
        case (.integer(let a), .integer(let b)): return order(a, b)
        case (.unsignedInteger(let a), .unsignedInteger(let b)): return order(a, b)
        case (.floatingPoint(let a), .floatingPoint(let b)): return order(a, b)
        case (.decimal(let a), .decimal(let b)): return order(a, b)
        case (.string(let a), .string(let b)): return order(a, b)
        case (.date(let a), .date(let b)): return order(a, b)
        default: throw GraphQueryError.incomparableValues
        }
    }
    static func test(_ value: GraphValue?, _ op: GraphQueryComparison, _ target: GraphValue) throws -> Bool {
        guard let value else { return false }
        try validate(value)
        switch op {
        case .equal: return value == target
        case .notEqual: return value != target
        case .contains, .beginsWith:
            if value == .null { return false }
            guard case .string(let text) = value, case .string(let fragment) = target else { throw GraphQueryError.incomparableValues }
            return op == .contains ? text.contains(fragment) : text.hasPrefix(fragment)
        default:
            if value == .null { return false }
            let result = try compare(value, target)
            switch op {
            case .lessThan: return result < 0
            case .lessThanOrEqual: return result <= 0
            case .greaterThan: return result > 0
            default: return result >= 0
            }
        }
    }
}

/// Pure bounded evaluation over a detached, graph-scoped snapshot. No storage fallback exists here.
package final class GraphQueryEvaluation {
    private let request: GraphQueryRequest
    private let graphID: GraphID
    private let records: [GraphRecord]
    private let byID: [GraphNodeID: GraphRecord]
    private var steps = 0
    private let checkCancellation: @Sendable () throws -> Void
    package init(request: GraphQueryRequest, graphID: GraphID, records: [GraphRecord], checkCancellation: @escaping @Sendable () throws -> Void = {}) throws {
        try GraphQueryValidation.request(request, graphID: graphID)
        guard records.allSatisfy({ $0.id.graphID == graphID }), Set(records.map(\.id)).count == records.count else { throw GraphQueryError.foreignGraph }
        self.request = request; self.graphID = graphID; self.records = records; self.checkCancellation = checkCancellation
        byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }
    private func step() throws {
        if steps % 64 == 0 { try checkCancellation() }
        guard steps < request.budget.maximumSteps else { throw GraphQueryError.budgetExceeded(.steps) }
        steps += 1
    }
    private func neighbors(_ source: GraphNodeID, relation: GraphQueryRelation) throws -> [GraphRecord] {
        var ids = Set<GraphNodeID>()
        for edge in records {
            try step()
            switch (relation, edge.endpoints) {
            case (.outgoing(let type), .relationship(let first, let second)) where first == source && (type == nil || type == edge.type):
                if let second { ids.insert(second) }
            case (.incoming(let type), .relationship(let first, let second)) where second == source && (type == nil || type == edge.type):
                if let first { ids.insert(first) }
            case (.actionObjects(let type), .action(let subjects, let objects)) where subjects.contains(source) && (type == nil || type == edge.type):
                for id in objects { try step(); ids.insert(id) }
            case (.actionSubjects(let type), .action(let subjects, let objects)) where objects.contains(source) && (type == nil || type == edge.type):
                for id in subjects { try step(); ids.insert(id) }
            default: break
            }
        }
        return try ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map {
            try step()
            guard let record = byID[$0], record.endpoints.kind == .entity else { throw GraphModelError.crossGraphReference }
            return record
        }
    }
    private func matches(_ predicate: GraphQueryPredicate, _ record: GraphRecord) throws -> Bool {
        try step()
        switch predicate {
        case .all: return true
        case .none: return false
        case .type(let type): return record.type == type
        case .id(let id): return record.id == id
        case .tag(let tag): return record.tags.contains(tag)
        case .group(let group): return record.groups.contains(group)
        case .exists(let name): return record.properties[name] != nil
        case .property(let name, let op, let value): return try GraphQueryScalar.test(record.properties[name], op, value)
        case .subject(let id):
            switch record.endpoints { case .relationship(let subject, _): return subject == id; case .action(let subjects, _): return subjects.contains(id); default: return false }
        case .object(let id):
            switch record.endpoints { case .relationship(_, let object): return object == id; case .action(_, let objects): return objects.contains(id); default: return false }
        case .and(let predicates):
            for predicate in predicates { if try !matches(predicate, record) { return false } }; return true
        case .or(let predicates):
            for predicate in predicates { if try matches(predicate, record) { return true } }; return false
        case .not(let predicate): return try !matches(predicate, record)
        case .related(let relation, let matching):
            for next in try neighbors(record.id, relation: relation) { if try matches(matching, next) { return true } }; return false
        }
    }
    private func values(_ record: GraphRecord) -> [GraphValue?] {
        request.definition.sorts.map { sort in
            switch sort.key {
            case .identity: return .string(record.id.rawValue.uuidString)
            case .createdDate: return record.createdDate.map(GraphValue.date)
            case .property(let name): return record.properties[name]
            }
        }
    }
    private func isMissing(_ value: GraphValue?) -> Bool { value == nil || value == .null }
    private func compare(_ left: [GraphValue?], _ leftID: GraphNodeID, _ right: [GraphValue?], _ rightID: GraphNodeID) throws -> Int {
        try step()
        for (index, sort) in request.definition.sorts.enumerated() {
            let a = left[index], b = right[index]
            let firstMissing = isMissing(a), secondMissing = isMissing(b)
            if firstMissing || secondMissing {
                if firstMissing == secondMissing { continue }
                return firstMissing == (sort.missing == .first) ? -1 : 1
            }
            let result = try GraphQueryScalar.compare(a!, b!)
            if result != 0 { return sort.direction == .ascending ? result : -result }
        }
        return leftID.rawValue.uuidString == rightID.rawValue.uuidString ? 0 : leftID.rawValue.uuidString < rightID.rawValue.uuidString ? -1 : 1
    }
    private func aggregate(_ aggregate: GraphQueryAggregate, matches: [GraphRecord]) throws -> (GraphValue?, Int) {
        let key: String
        switch aggregate { case .sum(let name), .minimum(let name), .maximum(let name): key = name }
        var value: GraphValue?, count = 0
        for record in matches {
            try step()
            guard let next = record.properties[key], next != .null else { continue }
            try GraphQueryScalar.ordered(next)
            count += 1
            switch aggregate {
            case .sum:
                switch (value, next) {
                case (nil, .integer), (nil, .unsignedInteger), (nil, .floatingPoint): value = next
                case (.integer(let a)?, .integer(let b)):
                    let (sum, overflow) = a.addingReportingOverflow(b); guard !overflow else { throw GraphQueryError.arithmeticOverflow }; value = .integer(sum)
                case (.unsignedInteger(let a)?, .unsignedInteger(let b)):
                    let (sum, overflow) = a.addingReportingOverflow(b); guard !overflow else { throw GraphQueryError.arithmeticOverflow }; value = .unsignedInteger(sum)
                case (.floatingPoint(let a)?, .floatingPoint(let b)):
                    let sum = a + b; guard sum.isFinite else { throw GraphQueryError.arithmeticOverflow }; value = .floatingPoint(sum)
                default: throw GraphQueryError.unsupportedComparison
                }
            case .minimum:
                if let previous = value { if try GraphQueryScalar.compare(next, previous) < 0 { value = next } } else { value = next }
            case .maximum:
                if let previous = value { if try GraphQueryScalar.compare(next, previous) > 0 { value = next } } else { value = next }
            }
        }
        return (value, count)
    }
    package func execute(nativeCandidates: Int, propertyBytesCharged: Int) throws -> GraphQueryOutput {
        try checkCancellation()
        if case .traversal(let traversal) = request.operation {
            var frontier = Set(traversal.origins), visited = frontier
            for id in frontier {
                try step()
                guard byID[id]?.endpoints.kind == .entity else { throw GraphQueryError.invalidOrigin }
            }
            var visits: [GraphTraversalVisit] = []
            if traversal.maximumDepth > 0 {
                for depth in 1...traversal.maximumDepth {
                    var layer = Set<GraphNodeID>()
                    for id in frontier.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                        for next in try neighbors(id, relation: traversal.relation) where !visited.contains(next.id) { layer.insert(next.id) }
                    }
                    for id in layer.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                        visited.insert(id); visits.append(GraphTraversalVisit(id: id, depth: depth))
                    }
                    if layer.isEmpty { break }
                    frontier = layer
                }
            }
            return GraphQueryOutput(records: [], cursor: nil, count: visits.count, aggregate: nil,
                diagnostics: GraphQueryDiagnostics(nativeCandidates: nativeCandidates, scopedNodes: records.count,
                    propertyBytesCharged: propertyBytesCharged, evaluationSteps: steps), visits: visits)
        }
        let matching = try records.filter { record in
            try step()
            guard record.type == request.definition.type, record.endpoints.kind == request.definition.kind else { return false }
            return try matches(request.definition.predicate, record)
        }
        func output(_ rows: [GraphRecord] = [], cursor: GraphQueryCursor? = nil, count: Int, value: GraphValue? = nil) -> GraphQueryOutput {
            GraphQueryOutput(records: rows, cursor: cursor, count: count, aggregate: value,
                diagnostics: GraphQueryDiagnostics(nativeCandidates: nativeCandidates, scopedNodes: records.count,
                    propertyBytesCharged: propertyBytesCharged, evaluationSteps: steps))
        }
        switch request.operation {
        case .count: return output(count: matching.count)
        case .aggregate(let aggregate):
            let (value, count) = try self.aggregate(aggregate, matches: matching)
            return output(count: count, value: value)
        default: break
        }
        // Validate ordering even when only one row matches; do not hide unsupported values behind a limit.
        for index in request.definition.sorts.indices {
            var previous: GraphValue?
            for record in matching {
                try step()
                if let value = values(record)[index], !isMissing(value) {
                    try GraphQueryScalar.ordered(value)
                    if let previous { _ = try GraphQueryScalar.compare(previous, value) }
                    previous = value
                }
            }
        }
        var sorted = try matching.sorted { try compare(values($0), $0.id, values($1), $1.id) < 0 }
        if let cursor = request.cursor {
            sorted = try sorted.filter { try compare(values($0), $0.id, cursor.values, cursor.lastID) > 0 }
        }
        let limit = min(request.limit ?? sorted.count, sorted.count)
        let selected = Array(sorted.prefix(limit))
        let cursor: GraphQueryCursor?
        if limit < sorted.count, let last = selected.last {
            cursor = GraphQueryCursor(graphID: graphID, definition: request.definition, values: values(last), lastID: last.id)
        } else { cursor = nil }
        return output(selected, cursor: cursor, count: matching.count)
    }
}
