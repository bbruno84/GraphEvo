import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// One pinned query scope. No header, decoded value or managed object survives it.
final class GraphTypedQueryExecution {
    private struct Header { let row: NSManagedObjectID; let name: String; let kind: Int16?; let encoding: Int16? }
    private let session: GraphTypedStoreAdapter.Session?
    private let source: GraphTypedQuerySource?
    private let context: NSManagedObjectContext
    private let graphID: GraphID
    private let request: GraphQueryRequest
    private let work: GraphQueryWorkCounter
    private let check: @Sendable () throws -> Void
    private var headers: [GraphNodeID: [String: [Header]]] = [:]
    private var loaded: [GraphNodeID: Set<String>] = [:]
    private var cached: [GraphNodeID: [String: GraphValue]] = [:]
    private var chargedKeys: [GraphNodeID: Set<String>] = [:]
    private var remaining: Int
    private var fetches = 0
    private var materialized = 0
    private var nativePredicates = 0
    private var lastNativeKey: String?
    private var reasons: [GraphQueryDiagnostics.FallbackReason] = []
    private var nativeSort = false
    private var indexedKeys = Set<String>()
    private var indexedRecords = Set<GraphNodeID>()
    private let canUseNative: Bool

    init(session: GraphTypedStoreAdapter.Session, request: GraphQueryRequest) {
        self.session = session; source = nil; context = session.context; graphID = session.graphID; self.request = request
        check = StoreNativeContext.cancellationCheck(in: session.context)
        work = GraphQueryWorkCounter(maximum: request.budget.maximumSteps, checkCancellation: check)
        remaining = request.budget.maximumPropertyBytes
        canUseNative = !session.context.hasChanges && session.context.persistentStoreCoordinator?.persistentStores.allSatisfy { $0.type == NSSQLiteStoreType } == true
        if session.context.hasChanges { reasons.append(.pendingChanges) }
        else if !canUseNative { reasons.append(.inMemory) }
    }
    init(context: NSManagedObjectContext, graphID: GraphID, request: GraphQueryRequest) throws {
        session = nil; self.context = context; self.graphID = graphID; self.request = request
        check = StoreNativeContext.cancellationCheck(in: context)
        work = GraphQueryWorkCounter(maximum: request.budget.maximumSteps, checkCancellation: check)
        remaining = request.budget.maximumPropertyBytes
        canUseNative = !context.hasChanges && context.persistentStoreCoordinator?.persistentStores.allSatisfy { $0.type == NSSQLiteStoreType } == true
        if context.hasChanges { reasons.append(.pendingChanges) }
        else if !canUseNative { reasons.append(.inMemory) }
        source = try GraphTypedQuerySource(context: context, graphID: graphID, request: request, work: work)
    }
    private var nodes: [GraphNodeID: Node] { source?.nodes ?? session!.nodes }
    private var nativeCandidateCount: Int { source?.nativeCandidateCount ?? session!.nativeCandidateCount }
    private func kind(_ id: GraphNodeID) throws -> GraphNodeKind {
        if let source, let kind = source.kindsByID[id] { return kind }
        guard let session, let node = session.nodes[id] else { throw GraphStoreError.corruptIdentity }
        return session.kind(node)
    }
    private func charge(_ count: Int) throws { try GraphQueryStoredCost.charge(count, remaining: &remaining) }
    private func entityName(_ kind: GraphNodeKind) -> String {
        switch kind { case .entity, .file: return ModelIdentifier.entityPropertyName
        case .relationship: return ModelIdentifier.relationshipPropertyName
        case .action: return ModelIdentifier.actionPropertyName }
    }
    private func chunks(_ ids: Set<GraphNodeID>) -> [[GraphNodeID]] {
        let sorted = ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        return stride(from: 0, to: sorted.count, by: 128).map { Array(sorted[$0..<min($0 + 128, sorted.count)]) }
    }
    private func objectIDs(_ ids: [GraphNodeID]) throws -> [NSManagedObjectID] {
        try ids.map {
            if let source, let objectID = source.objectIDs[$0] { return objectID }
            guard let node = nodes[$0] else { throw GraphStoreError.corruptIdentity }; return node.runtimeObjectID
        }
    }
    // Dictionary projections deliberately omit object and all value slots.
    // Full property blobs are not fetched simply to discover keys/ownership.
    private func indexHeaders(key requestedKey: String? = nil, ids selectedIDs: Set<GraphNodeID>? = nil) throws {
        if !canUseNative {
            for (id, node) in nodes where selectedIDs?.contains(id) ?? true {
                for row in node.node.propertySet {
                    try work.consume()
                    let key: String
                    if let requestedKey {
                        guard let logical = try? GraphNativePropertyStorage.logicalKey(row), logical == requestedKey else { continue }
                        key = logical
                    } else { key = try GraphNativePropertyStorage.logicalKey(row) }
                    if key.hasPrefix(GraphTypedStoreAdapter.prefix) {
                        guard row.value(forKey: GraphNativePropertyStorage.kindKey) == nil else { throw GraphStoreError.corruptIdentity }
                        continue
                    }
                    if headers[id]?[key]?.contains(where: { $0.row == row.objectID }) != true {
                        headers[id, default: [:]][key, default: []].append(Header(row: row.objectID, name: row.name,
                            kind: (row.value(forKey: GraphNativePropertyStorage.kindKey) as? NSNumber)?.int16Value,
                            encoding: (row.value(forKey: GraphNativePropertyStorage.encodingKey) as? NSNumber)?.int16Value))
                    }
                }
            }
            return
        }
        let idsByObject = source?.objectIDs ?? nodes.mapValues(\.runtimeObjectID)
        let reverse = Dictionary(uniqueKeysWithValues: idsByObject.map { ($0.value, $0.key) })
        for kind in [GraphNodeKind.entity, .relationship, .action] {
            let ids = try Set(idsByObject.keys.filter {
                guard selectedIDs?.contains($0) ?? true else { return false }
                return try self.kind($0) == kind
            })
            for chunk in chunks(ids) {
                try check()
                let ownerScope = NSPredicate(format: "node IN %@", try objectIDs(chunk))
                var predicate = ownerScope
                if let requestedKey {
                    // Resolve physical key spellings without reading values. Distinct native
                    // names stay in an Array so canonical Swift equality cannot collapse them.
                    let names = NSFetchRequest<NSDictionary>(entityName: entityName(kind))
                    names.resultType = .dictionaryResultType; names.propertiesToFetch = ["name", GraphNativePropertyStorage.kindKey]
                    names.predicate = ownerScope; names.returnsDistinctResults = true; names.includesPendingChanges = false
                    names.fetchLimit = request.budget.maximumSteps - work.steps + 1
                    fetches += 1
                    var physical: [String] = []
                    for row in try context.fetch(names) {
                        try work.consume()
                        guard let name = row["name"] as? String else { continue }
                        if let logical = try? GraphNativePropertyStorage.logicalKey(name: name, typed: row[GraphNativePropertyStorage.kindKey] != nil),
                           logical == requestedKey { physical.append(name) }
                    }
                    predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownerScope, NSPredicate(format: "name IN %@", physical)])
                }
                let fetch = NSFetchRequest<NSDictionary>(entityName: entityName(kind))
                fetch.resultType = .dictionaryResultType
                let expression = NSExpressionDescription(); expression.name = "rowID"
                expression.expression = NSExpression.expressionForEvaluatedObject(); expression.expressionResultType = .objectIDAttributeType
                fetch.propertiesToFetch = ["name", "node", GraphNativePropertyStorage.kindKey, GraphNativePropertyStorage.encodingKey, expression]
                fetch.predicate = predicate
                fetch.includesPendingChanges = false
                fetch.fetchLimit = request.budget.maximumSteps - work.steps + 1
                fetches += 1
                for row in try context.fetch(fetch) {
                    try work.consume()
                    guard let owner = row["node"] as? NSManagedObjectID, let id = reverse[owner],
                          let rowID = row["rowID"] as? NSManagedObjectID, let name = row["name"] as? String else { throw GraphStoreError.corruptIdentity }
                    let kind = row[GraphNativePropertyStorage.kindKey] as? NSNumber
                    let key = try GraphNativePropertyStorage.logicalKey(name: name, typed: kind != nil)
                    if key.hasPrefix(GraphTypedStoreAdapter.prefix) {
                        guard kind == nil else { throw GraphStoreError.corruptIdentity }
                        continue
                    }
                    if headers[id]?[key]?.contains(where: { $0.row == rowID }) != true {
                        headers[id, default: [:]][key, default: []].append(Header(row: rowID, name: name,
                            kind: kind?.int16Value, encoding: (row[GraphNativePropertyStorage.encodingKey] as? NSNumber)?.int16Value))
                    }
                }
            }
        }
    }
    private func header(_ id: GraphNodeID, _ key: String) throws -> Header? {
        if source != nil, !indexedRecords.contains(id), indexedKeys.insert(key).inserted {
            try indexHeaders(key: key)
        }
        try work.consume()
        let rows = headers[id]?[key] ?? []
        guard rows.count <= 1 else { throw GraphStoreError.corruptIdentity }
        if let row = rows.first {
            guard let kind = row.kind, GraphNativePropertyStorage.Kind(rawValue: kind) != nil,
                  row.encoding == 0 || row.encoding == 1 else { throw GraphStoreError.corruptIdentity }
            if chargedKeys[id, default: []].insert(key).inserted { try charge(key.utf8.count) }
        }
        return rows.first
    }
    private func value(_ id: GraphNodeID, _ key: String) throws -> GraphValue? {
        if loaded[id]?.contains(key) == true { return cached[id]?[key] }
        let row = try header(id, key)
        let value = try row.map { try GraphNativePropertyStorage.read(context.existingObject(with: $0.row), charge: charge) }
        loaded[id, default: []].insert(key)
        if let value { cached[id, default: [:]][key] = value }
        return value
    }
    private func full(_ raw: GraphRecord) throws -> GraphRecord {
        materialized += 1
        let keys: Set<String>
        if case .projection(let selected) = request.operation { keys = selected }
        else {
            if source != nil, indexedRecords.insert(raw.id).inserted { try indexHeaders(ids: [raw.id]) }
            keys = Set(headers[raw.id]?.keys.map { $0 } ?? [])
        }
        var properties: [String: GraphValue] = [:]
        for key in keys.sorted() { if let value = try value(raw.id, key) { properties[key] = value } }
        return try GraphRecord(id: raw.id, type: raw.type, endpoints: raw.endpoints, properties: properties,
            tags: raw.tags, groups: raw.groups, createdDate: raw.createdDate)
    }
    private func note(_ reason: GraphQueryDiagnostics.FallbackReason) { if !reasons.contains(reason) { reasons.append(reason) } }
    private func atoms(_ predicate: GraphQueryPredicate) -> [GraphQueryPredicate] {
        if case .and(let values) = predicate { return values.flatMap(atoms) }
        return [predicate]
    }
    private func structural(_ predicate: GraphQueryPredicate, record: GraphRecord) -> Bool? {
        switch predicate {
        case .all: return true; case .none: return false
        case .id(let id): return id == record.id
        case .type(let type): return type == record.type
        case .tag(let tag): return record.tags.contains(tag)
        case .group(let group): return record.groups.contains(group)
        case .subject(let id):
            switch record.endpoints { case .relationship(let first, _): return first == id; case .action(let first, _): return first.contains(id); default: return false }
        case .object(let id):
            switch record.endpoints { case .relationship(_, let last): return last == id; case .action(_, let last): return last.contains(id); default: return false }
        default: return nil
        }
    }
    private func select(_ predicate: NSPredicate, key: String, ids: Set<GraphNodeID>, sort: [NSSortDescriptor] = []) throws -> [[GraphNodeID]] {
        var result: [[GraphNodeID]] = []
        let reverse = Dictionary(uniqueKeysWithValues: try ids.map { (try objectIDs([$0])[0], $0) })
        for chunk in chunks(ids) {
            let fetch = NSFetchRequest<NSDictionary>(entityName: entityName(request.definition.kind))
            fetch.resultType = .dictionaryResultType; fetch.propertiesToFetch = ["node"]
            // Swift Set<String> would collapse distinct physical NFC/NFD spellings.
            let names = try chunk.compactMap { try header($0, key)?.name }
            fetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "name IN %@ AND node IN %@", Array(names), try objectIDs(chunk)), predicate])
            fetch.includesPendingChanges = false; fetch.sortDescriptors = sort
            fetch.fetchLimit = request.budget.maximumSteps - work.steps + 1
            fetches += 1
            var group: [GraphNodeID] = []
            for row in try context.fetch(fetch) {
                try work.consume()
                guard let owner = row["node"] as? NSManagedObjectID, let id = reverse[owner] else { throw GraphStoreError.corruptIdentity }
                group.append(id)
            }
            guard Set(group).count == group.count else { throw GraphStoreError.corruptIdentity }
            result.append(group)
        }
        return result
    }
    // Translate only a safe source-order prefix. A later filter must not hide
    // errors from an unsupported comparison evaluated earlier by Graph.
    private func native(_ atom: GraphQueryPredicate, ids: Set<GraphNodeID>) throws -> Set<GraphNodeID>? {
        let key: String
        let op: GraphQueryComparison?, target: GraphValue?
        switch atom {
        case .exists(let name): key = name; op = nil; target = nil
        case .property(let name, let comparison, let value): key = name; op = comparison; target = value
        default: note(.unsupportedPredicate); return nil
        }
        lastNativeKey = key
        let rows = try ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.compactMap { id -> (GraphNodeID, Header)? in
            try header(id, key).map { (id, $0) }
        }
        guard let op, let target else {
            nativePredicates += 1
            return Set(try select(NSPredicate(value: true), key: key, ids: ids).flatMap { $0 })
        }
        let allowed: Set<GraphNativePropertyStorage.Kind> = [.null, .boolean, .integer, .unsigned, .floating, .string, .date, .uuid]
        guard allowed.contains(GraphNativePropertyStorage.kind(target)), !GraphNativePropertyStorage.requiresEnvelope(target), rows.allSatisfy({ $0.1.encoding == 0 && $0.1.kind.flatMap(GraphNativePropertyStorage.Kind.init(rawValue:)).map(allowed.contains) == true }) else { note(.serializedValue); return nil }
        let prepared = try GraphNativePropertyStorage.prepare(target)
        let ordered = ![GraphQueryComparison.equal, .notEqual].contains(op)
        if ordered && rows.contains(where: { $0.1.kind != prepared.kind.rawValue && $0.1.kind != GraphNativePropertyStorage.Kind.null.rawValue }) { note(.mixedTypes); return nil }
        for (id, _) in rows {
            guard let value = try value(id, key) else { throw GraphStoreError.corruptIdentity }
            if case .string(let text) = value, !text.utf8.allSatisfy({ $0 < 128 }) { note(.nonASCIIString); return nil }
        }
        if case .string(let text) = target, !text.utf8.allSatisfy({ $0 < 128 }) { note(.nonASCIIString); return nil }
        let kind = NSPredicate(format: "%K == %d AND %K == 0", GraphNativePropertyStorage.kindKey, Int(prepared.kind.rawValue), GraphNativePropertyStorage.encodingKey)
        let comparison: NSPredicate
        if prepared.kind == .null { comparison = kind }
        else {
            guard let field = prepared.field, let value = prepared.value else { throw GraphStoreError.corruptIdentity }
            let symbol: String
            switch op { case .equal, .notEqual: symbol = "=="; case .lessThan: symbol = "<"; case .lessThanOrEqual: symbol = "<="
            case .greaterThan: symbol = ">"; case .greaterThanOrEqual: symbol = ">="; case .contains: symbol = "CONTAINS"; case .beginsWith: symbol = "BEGINSWITH" }
            comparison = NSCompoundPredicate(andPredicateWithSubpredicates: [kind, NSPredicate(format: "%K " + symbol + " %@", argumentArray: [field, value])])
        }
        let matching = Set(try select(comparison, key: key, ids: ids).flatMap { $0 })
        nativePredicates += 1
        return op == .notEqual ? Set(rows.map { $0.0 }).subtracting(matching) : matching
    }
    private func sortOrder(_ ids: Set<GraphNodeID>) throws -> [GraphNodeID]? {
        guard request.definition.sorts.count == 1, case .property(let key) = request.definition.sorts[0].key else {
            if !request.definition.sorts.isEmpty { note(.unsupportedSort) }; return nil
        }
        var prepared: GraphNativePropertyStorage.Prepared?
        for id in ids.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let value = try value(id, key), value != .null else { note(.missingSortValue); return nil }
            guard !GraphNativePropertyStorage.requiresEnvelope(value), [.boolean, .integer, .unsigned, .floating, .string, .date].contains(GraphNativePropertyStorage.kind(value)) else { note(.unsupportedSort); return nil }
            let next = try GraphNativePropertyStorage.prepare(value)
            if let prepared, prepared.kind != next.kind { note(.mixedTypes); return nil }
            if case .string(let text) = value, !text.utf8.allSatisfy({ $0 < 128 }) { note(.nonASCIIString); return nil }
            prepared = next
        }
        guard let field = prepared?.field else { return [] }
        let ascending = request.definition.sorts[0].direction == .ascending
        let groups = try select(NSPredicate(value: true), key: key, ids: ids, sort: [NSSortDescriptor(key: field, ascending: ascending), NSSortDescriptor(key: "node." + GraphNativeIdentityColumns.nodeAttribute, ascending: true)])
        var positions = Array(repeating: 0, count: groups.count), ordered: [GraphNodeID] = []
        // Retain one head per sorted fetch, rather than scan every fetch for each row.
        // All comparisons and emitted rows share the query's work/cancellation budget.
        func precedes(_ left: Int, _ right: Int) throws -> Bool {
            try work.consume()
            let a = groups[left][positions[left]], b = groups[right][positions[right]]
            guard let first = try value(a, key), let second = try value(b, key) else { throw GraphStoreError.corruptIdentity }
            let comparison = try GraphQueryScalar.compare(first, second)
            return comparison == 0 ? a.rawValue.uuidString < b.rawValue.uuidString : (ascending ? comparison < 0 : comparison > 0)
        }
        var heap: [Int] = []
        for index in groups.indices where !groups[index].isEmpty {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard try precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent); child = parent
            }
        }
        while let winner = heap.first {
            try work.consume()
            ordered.append(groups[winner][positions[winner]]); positions[winner] += 1
            if positions[winner] == groups[winner].count {
                let last = heap.removeLast()
                if !heap.isEmpty { heap[0] = last }
            }
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, try precedes(heap[child + 1], heap[child]) { child += 1 }
                guard try precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(parent, child); parent = child
            }
        }
        guard ordered.count == ids.count else { throw GraphStoreError.corruptIdentity }
        nativeSort = true
        return ordered
    }
    private func count(_ ids: Set<GraphNodeID>, key: String) throws -> Int {
        var result = 0
        for chunk in chunks(ids) {
            try work.consume()
            // Swift Set<String> would collapse distinct physical NFC/NFD spellings.
            let names = try chunk.compactMap { try header($0, key)?.name }
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entityName(request.definition.kind))
            fetch.predicate = NSPredicate(format: "name IN %@ AND node IN %@", Array(names), try objectIDs(chunk))
            fetch.includesPendingChanges = false; fetches += 1
            let count = try context.count(for: fetch)
            guard count == chunk.count else { throw GraphStoreError.corruptIdentity }
            result += count
        }
        return result
    }
    private func diagnostics(_ strategy: GraphQueryDiagnostics.Strategy, nodes: Int) -> GraphQueryDiagnostics {
        GraphQueryDiagnostics(nativeCandidates: nativeCandidateCount, scopedNodes: nodes,
            propertyBytesCharged: request.budget.maximumPropertyBytes - remaining, evaluationSteps: work.steps,
            strategy: strategy, nativeFetchCount: fetches + (source?.fetches ?? 0), nativePredicateCount: nativePredicates,
            materializedRecords: materialized, nativeSortApplied: nativeSort, fallbackReasons: reasons)
    }
    func execute() throws -> GraphQueryOutput {
        var records: [GraphRecord] = []
        let inputs: [GraphRecord]
        if let source { inputs = source.records }
        else if let session {
            inputs = try session.nodes.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map { id in
                guard let node = session.nodes[id] else { throw GraphStoreError.corruptIdentity }
                return try session.snapshot(node, id: id, propertyKeys: [])
            }
        } else { throw GraphStoreError.corruptIdentity }
        for raw in inputs.sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) {
            try work.consume()
            try charge(raw.type.utf8.count)
            for name in raw.tags.union(raw.groups) { try charge(name.utf8.count + 1) }
            records.append(raw)
        }
        if source == nil { try indexHeaders() }
        if request.isTraversal { note(.unsupportedPredicate) }
        var eligible: Set<GraphNodeID>?, order: [GraphNodeID]?
        if canUseNative, !request.isTraversal {
            var current = Set(records.filter { $0.type == request.definition.type && $0.endpoints.kind == request.definition.kind }.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var complete = true
            for atom in atoms(request.definition.predicate) {
                if current.isEmpty { break }
                if structural(atom, record: byID[current.first!]!) != nil {
                    current = try Set(current.filter { try work.consume(); return structural(atom, record: byID[$0]!) == true })
                } else if let selected = try native(atom, ids: current) { current = selected }
                else { complete = false; break }
            }
            eligible = current
            if complete {
                if case .count = request.operation, nativePredicates > 0, let key = lastNativeKey {
                    let count = try count(current, key: key)
                    return GraphQueryOutput(records: [], cursor: nil, count: count, aggregate: nil,
                        diagnostics: diagnostics(.native, nodes: records.count))
                }
                switch request.operation {
                case .records, .projection: order = try sortOrder(current)
                default: break
                }
            }
        }
        let result = try GraphQueryEvaluation(request: request, graphID: graphID, records: records, checkCancellation: check,
            work: work, property: value, exists: { try self.header($0, $1) != nil }, hydrate: full, eligibleIDs: eligible, nativeOrder: order).execute(nativeCandidates: nativeCandidateCount, propertyBytesCharged: 0)
        try source?.validateResults(result)
        let diagnostics = diagnostics(nativePredicates > 0 || nativeSort ? .hybrid : .memory, nodes: records.count)
        return GraphQueryOutput(records: result.records, cursor: result.cursor, count: result.count, aggregate: result.aggregate, diagnostics: diagnostics, visits: result.visits)
    }
}

private extension GraphQueryRequest {
    var isTraversal: Bool { if case .traversal = operation { return true }; return false }
}
