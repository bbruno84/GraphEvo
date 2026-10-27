import CoreData
import GraphEvoModel
import GraphEvoStore

/// Local alpha layout using the unchanged candidate schema and reserved detail properties.
package enum GraphTypedStoreAdapter {
    static let prefix = "__graphevo_v2."
    static let rootType = prefix + "graph"
    static let membersType = prefix + "members"
    static let databaseVersion = "a4.1"
    static let graphKey = prefix + "graphID"
    static let idKey = prefix + "nodeID"
    static let legacyKey = prefix + "legacyID"
    static let formatsKey = prefix + "encodedKeys"
    static let layoutKey = prefix + "layout"
    static let layoutVersion = "a3.1"

    package static let current = makeAdapter(database: false)
    package static let database = GraphDatabaseAdapter(
        graph: makeAdapter(database: true),
        catalog: { try catalog($0) },
        create: { try createGraph($0, id: $1) },
        upgrade: { try upgrade($0, backupRoot: $1) }
    )

    private static func makeAdapter(database: Bool) -> GraphStoreAdapter {
        GraphStoreAdapter(
            initialize: { context, backup in
                guard !database else { throw GraphStoreError.unsupportedLayout }
                return try initialize(context, backupRoot: backup)
            },
            fetch: { context, graphID, id in try Session(context, graphID, database: database).record(id) },
            fetchAll: { context, graphID, type, kind in
                let session = try Session(context, graphID, database: database)
                return try session.nodes.compactMap { id, node -> GraphRecord? in
                    guard node.type == type, session.kind(node) == kind else { return nil }
                    return try session.snapshot(node, id: id)
                }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            },
            insert: { context, graphID, record in try Session(context, graphID, database: database).insert(record) },
            patch: { context, graphID, patch in try Session(context, graphID, database: database).patch(patch) },
            delete: { context, graphID, id in try Session(context, graphID, database: database).delete(id) }
        )
    }

    private static func catalog(_ context: NSManagedObjectContext) throws -> [GraphID] {
        try GraphValueDecodingDiagnostics.checking {
            let all = try allNodes(facade(context))
            if all.isEmpty { return [] }
            let roots = all.filter { $0.type == rootType }
            guard !roots.isEmpty else { throw GraphStoreError.legacyStoreRequiresAdoption }
            var ids = Set<GraphID>()
            for root in roots {
                guard root is Entity, root[dynamicMember: layoutKey] as? String == databaseVersion,
                      let text = root[dynamicMember: graphKey] as? String, let uuid = UUID(uuidString: text) else {
                    throw GraphStoreError.unsupportedLayout
                }
                guard ids.insert(GraphID(rawValue: uuid)).inserted else { throw GraphStoreError.duplicateIdentity }
            }
            return ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }
    }

    /// Validates the selected local graph before requesting its native share boundary.
    package static func mirroringRoot(_ context: NSManagedObjectContext, id: GraphID) throws -> Entity {
        let session = try Session(context, id, database: true)
        for (nodeID, node) in session.nodes { _ = try session.snapshot(node, id: nodeID) }
        guard let root = session.root else { throw GraphStoreError.corruptIdentity }
        return root
    }

    package static func nativeMembers(_ context: NSManagedObjectContext, id: GraphID) throws -> [NSManagedObjectID] {
        let session = try Session(context, id, database: true)
        guard let root = session.root, let membership = session.membership else { throw GraphStoreError.corruptIdentity }
        for (nodeID, node) in session.nodes { _ = try session.snapshot(node, id: nodeID) }
        return ([root, membership] + Array(session.nodes.values)).flatMap(\.runtimeOwnedObjectIDs)
    }

    private static func createGraph(_ context: NSManagedObjectContext, id: GraphID) throws {
        guard !(try catalog(context)).contains(id) else { throw GraphStoreError.duplicateIdentity }
        let graph = facade(context)
        let root = Entity(rootType, graph: graph)
        root[dynamicMember: graphKey] = id.rawValue.uuidString
        root[dynamicMember: layoutKey] = databaseVersion
        let membership = Action(membersType, graph: graph)
        membership[dynamicMember: graphKey] = id.rawValue.uuidString
        membership.add(subjects: root)
    }

    private static func upgrade(_ context: NSManagedObjectContext, backupRoot: URL) throws -> [GraphID] {
        let graph = facade(context), all = try allNodes(graph)
        if all.filter({ $0.type == rootType }).allSatisfy({ $0[dynamicMember: layoutKey] as? String == databaseVersion }),
           !all.isEmpty { return try catalog(context) }
        guard let root = all.first(where: { $0.type == rootType }) as? Entity,
              let text = root[dynamicMember: graphKey] as? String, let uuid = UUID(uuidString: text),
              let url = context.persistentStoreCoordinator?.persistentStores.first?.url else {
            throw GraphStoreError.legacyStoreRequiresAdoption
        }
        let id = GraphID(rawValue: uuid), session = try Session(context, GraphID(rawValue: uuid))
        _ = try MigrationBackupManager.backupStore(at: url, migrationID: "GraphEvo2-A3-to-A4", rootOverride: backupRoot)
        let membership = Action(membersType, graph: graph)
        membership[dynamicMember: graphKey] = text
        membership.add(subjects: root)
        for node in session.nodes.values {
            if let entity = node as? Entity { membership.add(objects: entity) }
            else if let action = node as? Action { action.add(subjects: root) }
            else if let relationship = node as? Relationship, relationship.subject == nil, relationship.object == nil {
                relationship.subject = root
            }
        }
        root[dynamicMember: layoutKey] = databaseVersion
        return [id]
    }

    private static func facade(_ context: NSManagedObjectContext) -> Graph {
        let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
        graph.isReadSnapshot = true
        return graph
    }

    private static func allNodes(_ graph: Graph) throws -> [Node] {
        let all = Predicate([NSPredicate(value: true)])
        let nodes: [Node] = Search<Entity>(graph: graph).where(all).sync()
            + Search<Relationship>(graph: graph).where(all).sync()
            + Search<Action>(graph: graph).where(all).sync()
        if let error = graph.snapshotReadError { throw error }
        return nodes
    }

    private static func initialize(_ context: NSManagedObjectContext, backupRoot: URL?) throws -> GraphV1AdoptionReport {
        try GraphValueDecodingDiagnostics.checking {
            let graph = facade(context)
            let nodes = try allNodes(graph)
            let roots = nodes.filter { $0.type == rootType }
            if !roots.isEmpty {
                guard roots.count == 1, roots[0] is Entity,
                      roots[0][dynamicMember: layoutKey] as? String == layoutVersion,
                      let value = roots[0][dynamicMember: graphKey] as? String, let uuid = UUID(uuidString: value) else {
                    throw GraphStoreError.unsupportedLayout
                }
                let id = GraphID(rawValue: uuid)
                let session = try Session(context, id)
                var mapping: [String: GraphNodeID] = [:]
                for (nodeID, node) in session.nodes {
                    if let legacy = node[dynamicMember: legacyKey] as? String {
                        guard mapping.updateValue(nodeID, forKey: legacy) == nil else { throw GraphStoreError.corruptIdentity }
                    }
                }
                return GraphV1AdoptionReport(graphID: id, nodeIDs: mapping, backupURL: nil)
            }
            guard nodes.isEmpty || backupRoot != nil else { throw GraphStoreError.legacyStoreRequiresAdoption }
            for node in nodes {
                guard !node.type.hasPrefix(prefix), !node.properties.keys.contains(where: { $0.hasPrefix(prefix) }) else {
                    throw GraphStoreError.reservedName
                }
            }
            let id = GraphID()
            var mapping: [String: GraphNodeID] = [:]
            var identities: [(Node, GraphNodeID, String)] = []
            for node in nodes {
                let oldID = node.id
                let nodeID = GraphNodeID(graphID: id)
                guard mapping.updateValue(nodeID, forKey: oldID) == nil else { throw GraphStoreError.corruptIdentity }
                identities.append((node, nodeID, oldID))
            }
            var backupURL: URL?
            if let backupRoot {
                guard let storeURL = context.persistentStoreCoordinator?.persistentStores.first?.url,
                      FileManager.default.fileExists(atPath: storeURL.path) else { throw GraphStoreError.legacyStoreRequiresAdoption }
                backupURL = try MigrationBackupManager.backupStore(at: storeURL,
                    migrationID: "GraphEvo2-LocalIdentity-A3", conflictPolicy: .duplicate, rootOverride: backupRoot).folderURL
            }
            for (node, nodeID, oldID) in identities {
                stamp(node, id: nodeID)
                node[dynamicMember: legacyKey] = oldID
                node[dynamicMember: formatsKey] = [String]()
            }
            let root = Entity(rootType, graph: graph)
            root[dynamicMember: graphKey] = id.rawValue.uuidString
            root[dynamicMember: layoutKey] = layoutVersion
            return GraphV1AdoptionReport(graphID: id, nodeIDs: mapping, backupURL: backupURL)
        }
    }

    private static func stamp(_ node: Node, id: GraphNodeID) {
        node[dynamicMember: idKey] = id.rawValue.uuidString
        node[dynamicMember: graphKey] = id.graphID.rawValue.uuidString
    }

    private final class Session {
        let graph: Graph
        let graphID: GraphID
        var nodes: [GraphNodeID: Node] = [:]
        let database: Bool
        var root: Entity?
        var membership: Action?

        init(_ context: NSManagedObjectContext, _ graphID: GraphID, database: Bool = false) throws {
            graph = facade(context)
            self.graphID = graphID
            self.database = database
            try GraphValueDecodingDiagnostics.checking {
                let all = try allNodes(graph)
                let roots = all.filter { $0.type == rootType && (!database || $0[dynamicMember: graphKey] as? String == graphID.rawValue.uuidString) }
                guard roots.count == 1, let selected = roots[0] as? Entity,
                      selected[dynamicMember: graphKey] as? String == graphID.rawValue.uuidString,
                      selected[dynamicMember: layoutKey] as? String == (database ? databaseVersion : layoutVersion) else { throw GraphStoreError.corruptIdentity }
                root = selected
                if database {
                    let candidates = all.filter { $0.type == membersType && $0[dynamicMember: graphKey] as? String == graphID.rawValue.uuidString }
                    guard candidates.count == 1, let action = candidates[0] as? Action else { throw GraphStoreError.corruptIdentity }
                    membership = action
                }
                for node in all where node.type != rootType && (!database || node.type != membersType) {
                    if database, node[dynamicMember: graphKey] as? String != graphID.rawValue.uuidString { continue }
                    guard !node.type.hasPrefix(prefix),
                          node[dynamicMember: graphKey] as? String == graphID.rawValue.uuidString,
                          let text = node[dynamicMember: idKey] as? String, let uuid = UUID(uuidString: text) else {
                        throw GraphStoreError.corruptIdentity
                    }
                    let id = GraphNodeID(graphID: graphID, rawValue: uuid)
                    _ = try encodedKeys(node)
                    guard nodes.updateValue(node, forKey: id) == nil else { throw GraphStoreError.duplicateIdentity }
                }
                if database { try validateMembership() }
            }
        }

        private func validateMembership() throws {
            guard let root, let membership, membership.subjects.count == 1,
                  membership.subjects[0].sharesBackingObject(with: root) else { throw GraphStoreError.corruptIdentity }
            let expected = Set(nodes.filter { $0.value is Entity }.map(\.key))
            guard Set(try membership.objects.map(referenceID)) == expected else { throw GraphStoreError.corruptIdentity }
            for node in nodes.values {
                if let action = node as? Action {
                    guard action.subjects.contains(where: { $0.sharesBackingObject(with: root) }) else { throw GraphStoreError.corruptIdentity }
                } else if let edge = node as? Relationship {
                    if edge.subject?.sharesBackingObject(with: root) == true {
                        guard edge.object == nil else { throw GraphStoreError.corruptIdentity }
                    } else if edge.subject == nil && edge.object == nil { throw GraphStoreError.corruptIdentity }
                }
            }
        }

        func kind(_ node: Node) -> GraphNodeKind {
            if node is Entity { return .entity }
            return node is Relationship ? .relationship : .action
        }

        func node(_ id: GraphNodeID) throws -> Node? {
            guard id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            return nodes[id]
        }

        func referenceID(_ entity: Entity) throws -> GraphNodeID {
            guard entity[dynamicMember: graphKey] as? String == graphID.rawValue.uuidString,
                  let value = entity[dynamicMember: idKey] as? String, let uuid = UUID(uuidString: value) else {
                throw GraphStoreError.unresolvedReference
            }
            let id = GraphNodeID(graphID: graphID, rawValue: uuid)
            guard nodes[id] is Entity else { throw GraphStoreError.unresolvedReference }
            return id
        }

        func snapshot(_ node: Node, id: GraphNodeID) throws -> GraphRecord {
            let raw = try GraphRecordMapper.snapshot(node, id: id, excludingRoot: database ? root : nil, referenceID: referenceID)
            var properties = raw.properties.filter { !$0.key.hasPrefix(prefix) }
            for key in try encodedKeys(node) {
                guard let value = properties[key], case .data(let data) = value else { throw GraphStoreError.corruptIdentity }
                properties[key] = try GraphValueCodec.decode(data)
            }
            return try GraphRecord(id: id, type: raw.type, endpoints: raw.endpoints, properties: properties,
                                   tags: raw.tags, groups: raw.groups, createdDate: raw.createdDate)
        }

        func record(_ id: GraphNodeID) throws -> GraphRecord? {
            try node(id).map { try snapshot($0, id: id) }
        }

        func encodedKeys(_ node: Node) throws -> Set<String> {
            guard let raw = node[dynamicMember: formatsKey], let keys = raw as? [String], Set(keys).count == keys.count,
                  keys.allSatisfy({ !$0.hasPrefix(prefix) }) else { throw GraphStoreError.corruptIdentity }
            return Set(keys)
        }

        func validate(_ record: GraphRecord) throws {
            guard record.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
            guard !record.type.hasPrefix(prefix), !record.properties.keys.contains(where: { $0.hasPrefix(prefix) }) else {
                throw GraphStoreError.reservedName
            }
        }

        func resolve(_ endpoints: GraphEndpoints) throws -> ([Entity], [Entity]) {
            func entity(_ id: GraphNodeID) throws -> Entity {
                guard let entity = try node(id) as? Entity else { throw GraphStoreError.unresolvedReference }
                return entity
            }
            switch endpoints {
            case .entity: return ([], [])
            case .relationship(let subject, let object):
                return (try subject.map { [try entity($0)] } ?? [], try object.map { [try entity($0)] } ?? [])
            case .action(let subjects, let objects):
                return (try subjects.map(entity), try objects.map(entity))
            }
        }

        func setEndpoints(_ node: Node, subjects: [Entity], objects: [Entity]) {
            if let relationship = node as? Relationship {
                relationship.subject = subjects.first ?? (database && objects.isEmpty ? root : nil)
                relationship.object = objects.first
            } else if let action = node as? Action {
                action.remove(subjects: action.subjects)
                action.remove(objects: action.objects)
                action.add(subjects: subjects + (database ? root.map { [$0] } ?? [] : []))
                action.add(objects: objects)
            }
        }

        func insert(_ record: GraphRecord) throws {
            try validate(record)
            guard nodes[record.id] == nil else { throw GraphStoreError.duplicateIdentity }
            let values = try record.properties.mapValues { try GraphValueCodec.encode($0) }
            let (subjects, objects) = try resolve(record.endpoints)
            let node: Node
            switch record.endpoints.kind {
            case .entity: node = Entity(record.type, graph: graph)
            case .relationship: node = Relationship(record.type, graph: graph)
            case .action: node = Action(record.type, graph: graph)
            }
            stamp(node, id: record.id)
            if database, let entity = node as? Entity { membership?.add(objects: entity) }
            node[dynamicMember: formatsKey] = values.keys.sorted()
            for (key, value) in values { node[dynamicMember: key] = value }
            node.add(tags: Array(record.tags))
            node.add(to: Array(record.groups))
            if let date = record.createdDate { node.setCreatedDate(date) }
            setEndpoints(node, subjects: subjects, objects: objects)
        }

        func patch(_ patch: GraphRecordPatch) throws -> GraphRecord {
            guard let node = try node(patch.id) else { throw GraphStoreError.missingNode }
            let current = try snapshot(node, id: patch.id)
            let updated = try patch.applying(to: current)
            try validate(updated)
            let (subjects, objects) = try resolve(updated.endpoints)
            var values: [String: Data] = [:]
            for (key, change) in patch.properties {
                if case .set(let value) = change { values[key] = try GraphValueCodec.encode(value) }
            }
            var encoded = try encodedKeys(node)
            for (key, change) in patch.properties {
                switch change {
                case .set: node[dynamicMember: key] = values[key]; encoded.insert(key)
                case .remove: node[dynamicMember: key] = nil; encoded.remove(key)
                }
            }
            node[dynamicMember: formatsKey] = encoded.sorted()
            node.add(tags: Array(patch.addingTags)); node.remove(tags: Array(patch.removingTags))
            node.add(to: Array(patch.addingGroups)); node.remove(from: Array(patch.removingGroups))
            if patch.endpoints != nil { setEndpoints(node, subjects: subjects, objects: objects) }
            return updated
        }

        func delete(_ id: GraphNodeID) throws {
            guard let node = try node(id) else { throw GraphStoreError.missingNode }
            if let entity = node as? Entity {
                // Preserve actions and their other endpoints, including valid empty actions.
                for action in entity.actions {
                    action.remove(subjects: [entity])
                    action.remove(objects: [entity])
                }
                for relationship in entity.relationships { relationship.delete() }
            }
            node.delete()
        }
    }
}
