import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// A query's native routing and structural inputs, never a global integrity inventory.
/// Fresh SQLite scopes project headers without constructing application Node facades.
final class GraphTypedQuerySource {
    let context: NSManagedObjectContext
    let graphID: GraphID
    private(set) var nativeCandidateCount = 0
    private(set) var fetches = 0
    private(set) var records: [GraphRecord] = []
    private(set) var objectIDs: [GraphNodeID: NSManagedObjectID] = [:]
    private(set) var nodes: [GraphNodeID: Node] = [:]
    private(set) lazy var kindsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.endpoints.kind) })
    private let access = GraphNativeIdentityAccess(activationKey: GraphTypedStoreAdapter.prefix + "nativeIdentityLayout",
                                                   activationVersion: "alpha.1")
    private let work: GraphQueryWorkCounter
    private let request: GraphQueryRequest
    private let check: @Sendable () throws -> Void

    init(context: NSManagedObjectContext, graphID: GraphID, request: GraphQueryRequest,
         work: GraphQueryWorkCounter) throws {
        self.context = context; self.graphID = graphID; self.request = request; self.work = work
        check = StoreNativeContext.cancellationCheck(in: context)
        for kind in [GraphNodeKind.entity, .relationship, .action] {
            try check(); try work.consume()
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: Self.name(kind))
            fetch.includesPendingChanges = true
            let count = try context.count(for: fetch); fetches += 1
            guard count >= 0, count <= request.budget.maximumCandidates - nativeCandidateCount else {
                throw GraphQueryError.budgetExceeded(.candidates)
            }
            nativeCandidateCount += count
        }
        let topology = GraphQueryTopologyPlan(request)
        let native = !context.hasChanges && context.persistentStoreCoordinator?.persistentStores.allSatisfy { $0.type == NSSQLiteStoreType } == true
        if !native {
            // Managed fetches preserve pending inserts/edits/deletes and in-memory semantics.
            for node in try access.queryNodes(context, graphID: graphID) {
                try work.consume()
                guard node[dynamicMember: GraphTypedStoreAdapter.stageKey] == nil,
                      !node.type.hasPrefix(GraphTypedStoreAdapter.prefix),
                      topology.includes(nodeKind(node), type: node.type) else { continue }
                guard let text = node.node.value(forKey: GraphNativeIdentityColumns.nodeAttribute) as? String,
                      let uuid = UUID(uuidString: text) else { throw GraphStoreError.corruptIdentity }
                let id = GraphNodeID(graphID: graphID, rawValue: uuid)
                guard nodes.updateValue(node, forKey: id) == nil else { throw GraphStoreError.duplicateIdentity }
                objectIDs[id] = node.runtimeObjectID
            }
            let edgeIDs = Set(nodes.filter { !($0.value is Entity) }.keys)
            records = try access.queryHeaders(context, graphID: graphID, ids: edgeIDs)
            for (id, node) in nodes where node is Entity {
                records.append(try GraphRecord(id: id, type: node.type, tags: Set(node.tags),
                    groups: Set(node.groups), createdDate: node.createdDateIfPresent))
            }
            return
        }
        let kinds = [GraphNodeKind.entity, .relationship, .action].filter { topology.includes($0) }
        var projected: [GraphNodeID: (String, Date?, GraphNodeKind)] = [:]
        for kind in kinds {
            let graphScope = NSPredicate(format: "%K == %@ AND %K != nil AND NOT (type BEGINSWITH %@) AND NONE propertySet.name == %@",
                GraphNativeIdentityColumns.graphAttribute, graphID.rawValue.uuidString,
                GraphNativeIdentityColumns.nodeAttribute, GraphTypedStoreAdapter.prefix, GraphTypedStoreAdapter.stageKey)
            // Preserve physical NFC/NFD spellings; Swift's type equality is canonical.
            let names = try rows(Self.name(kind), properties: ["type"], predicate: graphScope, distinct: true)
                .compactMap { $0["type"] as? String }.filter { topology.includes(kind, type: $0) }
            let scope = NSCompoundPredicate(andPredicateWithSubpredicates: [graphScope, NSPredicate(format: "type IN %@", names)])
            let expression = NSExpressionDescription(); expression.name = "rowID"
            expression.expression = .expressionForEvaluatedObject(); expression.expressionResultType = .objectIDAttributeType
            for row in try rows(Self.name(kind), properties: [GraphNativeIdentityColumns.nodeAttribute, "type", "createdDate", expression], predicate: scope) {
                guard let objectID = row["rowID"] as? NSManagedObjectID,
                      let text = row[GraphNativeIdentityColumns.nodeAttribute] as? String, let uuid = UUID(uuidString: text),
                      let type = row["type"] as? String else { throw GraphStoreError.corruptIdentity }
                let id = GraphNodeID(graphID: graphID, rawValue: uuid)
                guard objectIDs.updateValue(objectID, forKey: id) == nil else { throw GraphStoreError.duplicateIdentity }
                projected[id] = (type, row["createdDate"] as? Date, kind)
            }
        }
        // Only relationship/action kinds and edge types actually named by the descriptor
        // require topology. Entity routing headers do not audit their unrelated edges.
        let edgeIDs = Set(projected.filter { $0.value.2 != .entity }.keys)
        records = try access.queryHeaders(context, graphID: graphID, ids: edgeIDs)
        let tags = try names(ModelIdentifier.entityTagName), groups = try names(ModelIdentifier.entityGroupName)
        for (id, value) in projected where value.2 == .entity {
            records.append(try GraphRecord(id: id, type: value.0, tags: tags[id] ?? [], groups: groups[id] ?? [], createdDate: value.1))
        }
    }

    private func nodeKind(_ node: Node) -> GraphNodeKind {
        if node is Entity { return .entity }; if node is Relationship { return .relationship }; return .action
    }
    static func name(_ kind: GraphNodeKind) -> String {
        switch kind { case .entity: return ModelIdentifier.entityName
        case .relationship: return ModelIdentifier.relationshipName
        case .action: return ModelIdentifier.actionName }
    }
    private func rows(_ name: String, properties: [Any], predicate: NSPredicate, distinct: Bool = false) throws -> [NSDictionary] {
        try check()
        let fetch = NSFetchRequest<NSDictionary>(entityName: name)
        fetch.resultType = .dictionaryResultType; fetch.propertiesToFetch = properties
        fetch.predicate = predicate; fetch.returnsDistinctResults = distinct; fetch.includesPendingChanges = false
        // One extra row makes allowance rejection explicit before partial output.
        fetch.fetchLimit = request.budget.maximumSteps - work.steps + 1
        let values = try context.fetch(fetch); fetches += 1
        for _ in values { try work.consume() }
        return values
    }
    private func names(_ entity: String) throws -> [GraphNodeID: Set<String>] {
        let reverse = Dictionary(uniqueKeysWithValues: objectIDs.map { ($0.value, $0.key) })
        let ids = Array(reverse.keys)
        var result: [GraphNodeID: Set<String>] = [:]
        for offset in stride(from: 0, to: ids.count, by: 128) {
            for row in try rows(entity, properties: ["name", "node"], predicate:
                NSPredicate(format: "node IN %@", Array(ids[offset..<min(offset + 128, ids.count)]))) {
                guard let owner = row["node"] as? NSManagedObjectID, let id = reverse[owner],
                      let name = row["name"] as? String else { throw GraphStoreError.corruptIdentity }
                result[id, default: []].insert(name)
            }
        }
        return result
    }
    func validateResults(_ output: GraphQueryOutput) throws {
        var selected = Set(output.records.map(\.id)).union(output.visits.map(\.id))
        if case .traversal(let traversal) = request.operation { selected.formUnion(traversal.origins) }
        guard !selected.isEmpty else { return }
        for _ in selected { try work.consume() }
        let validated = try access.queryHeaders(context, graphID: graphID, ids: selected)
        let expected = Dictionary(uniqueKeysWithValues: output.records.map { ($0.id, $0) })
        for record in validated {
            guard let original = expected[record.id] else {
                guard record.endpoints.kind == .entity else { throw GraphStoreError.corruptIdentity }
                continue
            }
            guard record.type == original.type,
                  record.endpoints == original.endpoints, record.tags == original.tags,
                  record.groups == original.groups, record.createdDate == original.createdDate else { throw GraphStoreError.corruptIdentity }
        }
    }
}

private struct GraphQueryTopologyPlan {
    private let definition: GraphQueryDefinition
    private var relations: [GraphQueryRelation] = []
    init(_ request: GraphQueryRequest) {
        definition = request.definition
        func collect(_ predicate: GraphQueryPredicate) -> [GraphQueryRelation] {
            switch predicate {
            case .related(let relation, let matching): return [relation] + collect(matching)
            case .and(let values), .or(let values): return values.flatMap(collect)
            case .not(let value): return collect(value)
            default: return []
            }
        }
        relations = collect(definition.predicate)
        if case .traversal(let traversal) = request.operation { relations.append(traversal.relation) }
    }
    func includes(_ kind: GraphNodeKind, type: String? = nil) -> Bool {
        if kind == definition.kind, type == nil || type == definition.type { return true }
        if kind == .entity, !relations.isEmpty { return true }
        return relations.contains { relation in
            let expected: GraphNodeKind, name: String?
            switch relation {
            case .outgoing(let value), .incoming(let value): expected = .relationship; name = value
            case .actionObjects(let value), .actionSubjects(let value): expected = .action; name = value
            }
            return kind == expected && (type == nil || name == nil || name == type)
        }
    }
}
