import CoreData
import Foundation
import GraphEvoModel
import GraphEvoRuntime

/// Context-confined native identity access with an explicit persisted protocol marker.
/// The resolver serves historical local fixtures and explicitly admitted fresh native topologies.
struct GraphNativeIdentityAccess: Sendable {
    private let activationKey: String
    private let activationVersion: String
    private let allowsMirroring: Bool
    private let graphAttribute = GraphNativeIdentityColumns.graphAttribute
    private let nodeAttribute = GraphNativeIdentityColumns.nodeAttribute
    private let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    init(activationKey: String, activationVersion: String, allowsMirroring: Bool = false) {
        self.activationKey = activationKey; self.activationVersion = activationVersion
        self.allowsMirroring = allowsMirroring
    }

    /// Activate only newly allocated empty graph controls, never an existing populated layout.
    func activateFreshGraph(_ context: NSManagedObjectContext, graphID: GraphID) throws {
        try requireModel(context)
        let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
        guard session.nodes.isEmpty, session.stagedNodeIDs.isEmpty,
              let root = session.root, let membership = session.membership,
              root.node.isInserted, membership.node.isInserted,
              root[dynamicMember: activationKey] == nil else { throw GraphStoreError.unsupportedLayout }
        try GraphNativeIdentityColumns.validate(root, graphID: graphID, nodeID: nil)
        try GraphNativeIdentityColumns.validate(membership, graphID: graphID, nodeID: nil)
        root[dynamicMember: activationKey] = activationVersion
        // The marker adds a detail after base control creation has assigned its owned rows.
        // Keep it in the root's store even when the shared store loaded first.
        if let store = root.runtimeObjectID.persistentStore {
            try root.runtimeAssignOwnedObjects(to: store, in: context)
        }
    }

    func checkGraph(_ context: NSManagedObjectContext, graphID: GraphID) throws {
        _ = try anchors(context, graphID: graphID)
    }

    private func requireModel(_ context: NSManagedObjectContext) throws {
        guard try GraphNativeIdentityColumns.validateModel(in: context) else {
            throw GraphStoreError.unsupportedLayout
        }
        if context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer {
            guard allowsMirroring,
                  let privateURL = context.userInfo[StoreNativeContext.privateURLKey] as? URL,
                  let stores = context.persistentStoreCoordinator?.persistentStores,
                  stores.contains(where: { $0.url == privateURL }) else { throw GraphStoreError.unsupportedLayout }
            if let sharedValue = context.userInfo[StoreNativeContext.sharedURLKey] {
                guard let sharedURL = sharedValue as? URL, sharedURL != privateURL, stores.count == 2,
                      stores.contains(where: { $0.url == sharedURL }) else { throw GraphStoreError.unsupportedLayout }
            } else {
                guard stores.count == 1 else { throw GraphStoreError.unsupportedLayout }
            }
        }
    }

    /// Validates complete source records before editing. Caller saves or rolls back the whole backfill.
    func backfill(_ context: NSManagedObjectContext, graphID: GraphID) throws {
        try requireModel(context)
        let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true, allowUnprojectedRows: true)
        var plan: [(Node, GraphNodeID)] = []
        for (id, node) in session.nodes {
            try session.validate(session.snapshot(node, id: id, includingAttachments: false))
            let oldGraph = node.node.value(forKey: graphAttribute), oldNode = node.node.value(forKey: nodeAttribute)
            guard (oldGraph == nil && oldNode == nil) ||
                    (oldGraph as? String == id.graphID.rawValue.uuidString && oldNode as? String == id.rawValue.uuidString) else {
                throw GraphStoreError.corruptIdentity
            }
            plan.append((node, id))
        }
        for node in try GraphTypedStoreAdapter.allNodes(session.graph) where
            node[dynamicMember: GraphTypedStoreAdapter.graphKey] as? String == graphID.rawValue.uuidString {
            guard node[dynamicMember: GraphTypedStoreAdapter.stageKey] == nil else { throw GraphStoreError.pendingNativeOperation }
        }
        guard let root = session.root, let membership = session.membership else { throw GraphStoreError.corruptIdentity }
        for control in [root as Node, membership] {
            let oldGraph = control.node.value(forKey: graphAttribute), oldNode = control.node.value(forKey: nodeAttribute)
            guard oldNode == nil, oldGraph == nil || oldGraph as? String == graphID.rawValue.uuidString else { throw GraphStoreError.corruptIdentity }
        }
        for (node, id) in plan { try node.setPrototypeIdentity(id) }
        for control in [root as Node, membership] {
            control.node.setValue(graphID.rawValue.uuidString, forKey: graphAttribute)
        }
        session.root?[dynamicMember: activationKey] = activationVersion
    }

    private func checkedRoot(_ root: Entity) throws -> GraphID {
        guard root.node.value(forKey: nodeAttribute) == nil,
              let text = root.node.value(forKey: graphAttribute) as? String, let uuid = UUID(uuidString: text),
              root[dynamicMember: GraphTypedStoreAdapter.graphKey] as? String == text,
              root[dynamicMember: GraphTypedStoreAdapter.layoutKey] as? String == GraphTypedStoreAdapter.databaseVersion,
              root[dynamicMember: activationKey] as? String == activationVersion else { throw GraphStoreError.unsupportedLayout }
        return GraphID(rawValue: uuid)
    }

    func catalog(_ context: NSManagedObjectContext) throws -> [GraphID] {
        try GraphValueDecodingDiagnostics.checking {
            try requireModel(context)
            let request = NSFetchRequest<ManagedEntity>(entityName: ModelIdentifier.entityName)
            request.predicate = NSPredicate(format: "type == %@", GraphTypedStoreAdapter.rootType)
            request.affectedStores = context.persistentStoreCoordinator?.persistentStores
            request.includesPendingChanges = true
            let roots = try context.fetch(request).map { Entity(managedNode: $0) }
            var ids = Set<GraphID>()
            for root in roots {
                guard ids.insert(try checkedRoot(root)).inserted else { throw GraphStoreError.duplicateIdentity }
            }
            if roots.isEmpty {
                for name in kinds {
                    let count = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                    guard try context.count(for: count) == 0 else { throw GraphStoreError.unsupportedLayout }
                }
            }
            return ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }
    }

    private func anchors(_ context: NSManagedObjectContext, graphID: GraphID) throws -> (Entity, Action) {
        try requireModel(context)
        let predicate = NSPredicate(format: "%K == %@ AND %K == nil", graphAttribute, graphID.rawValue.uuidString, nodeAttribute)
        let roots = NSFetchRequest<ManagedEntity>(entityName: ModelIdentifier.entityName)
        roots.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, NSPredicate(format: "type == %@", GraphTypedStoreAdapter.rootType)])
        roots.fetchLimit = 2; roots.includesPendingChanges = true
        roots.affectedStores = context.persistentStoreCoordinator?.persistentStores
        let rootMatches = try context.fetch(roots)
        guard rootMatches.count == 1, let value = rootMatches.first else { throw GraphStoreError.corruptIdentity }
        let root = Entity(managedNode: value)
        guard try checkedRoot(root) == graphID else { throw GraphStoreError.corruptIdentity }
        let members = NSFetchRequest<ManagedAction>(entityName: ModelIdentifier.actionName)
        members.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, NSPredicate(format: "type == %@", GraphTypedStoreAdapter.membersType)])
        members.fetchLimit = 2; members.includesPendingChanges = true
        members.affectedStores = context.persistentStoreCoordinator?.persistentStores
        let matches = try context.fetch(members)
        guard matches.count == 1, let member = matches.first else { throw GraphStoreError.corruptIdentity }
        let membership = Action(managedNode: member)
        guard membership[dynamicMember: GraphTypedStoreAdapter.graphKey] as? String == graphID.rawValue.uuidString,
              membership.subjects.count == 1, membership.subjects[0].sharesBackingObject(with: root),
              membership.runtimeObjectID.persistentStore === root.runtimeObjectID.persistentStore else { throw GraphStoreError.corruptIdentity }
        return (root, membership)
    }

    private func fetch(_ context: NSManagedObjectContext, graphID: GraphID, nodeID: UUID? = nil, nodeIDs: [UUID]? = nil) throws -> [Node] {
        var result: [Node] = []
        for name in kinds {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            if let nodeIDs {
                request.predicate = NSPredicate(format: "%K == %@ AND %K IN %@", graphAttribute, graphID.rawValue.uuidString, nodeAttribute, nodeIDs.map(\.uuidString))
                request.fetchLimit = nodeIDs.count * 2 + 1
            } else if let nodeID {
                request.predicate = NSPredicate(format: "%K == %@ AND %K == %@", graphAttribute, graphID.rawValue.uuidString, nodeAttribute, nodeID.uuidString)
                request.fetchLimit = 2
            } else { request.predicate = NSPredicate(format: "%K == %@ AND %K != nil", graphAttribute, graphID.rawValue.uuidString, nodeAttribute) }
            request.affectedStores = context.persistentStoreCoordinator?.persistentStores
            request.includesPendingChanges = true
            request.returnsObjectsAsFaults = false
            // Prefetch topology only; endpoint property bodies must remain untouched.
            if name == ModelIdentifier.entityName { request.relationshipKeyPathsForPrefetching = ["actionObjectSet"] }
            else if name == ModelIdentifier.actionName { request.relationshipKeyPathsForPrefetching = ["subjectSet", "objectSet"] }
            else { request.relationshipKeyPathsForPrefetching = ["subject", "object"] }
            for object in try context.fetch(request) {
                switch object {
                case let value as ManagedEntity: result.append(Entity(managedNode: value))
                case let value as ManagedRelationship: result.append(Relationship(managedNode: value))
                case let value as ManagedAction: result.append(Action(managedNode: value))
                default: throw GraphStoreError.corruptIdentity
                }
            }
        }
        return result
    }

    private func checkedNode(_ context: NSManagedObjectContext, id: GraphNodeID, root: Entity, membership: Action) throws -> Node? {
        let matches = try fetch(context, graphID: id.graphID, nodeID: id.rawValue)
        guard matches.count <= 1 else { throw GraphStoreError.duplicateIdentity }
        guard let node = matches.first else { return nil }
        try validateNode(node, id: id, root: root, membership: membership)
        return node
    }

    private func validateNode(_ node: Node, id: GraphNodeID, root: Entity, membership: Action,
                                     metadata: GraphRuntimeMetadata? = nil) throws {
        if node.runtimeTypeIfPresent == GraphAttachmentPayload.graphType {
            guard node is Entity, !(node.node is ManagedGraphFile) else { throw GraphAttachmentError.notAnAttachment }
        }

        func value(_ key: String) -> Any? {
            // Pending inverse/property edits use the facade's complete local view.
            if let metadata, !node.node.hasChanges { return metadata.value(for: node, key: key) }
            return node[dynamicMember: key]
        }
        guard !node.type.hasPrefix(GraphTypedStoreAdapter.prefix),
              node.runtimeObjectID.persistentStore === root.runtimeObjectID.persistentStore,
              value(GraphTypedStoreAdapter.graphKey) as? String == id.graphID.rawValue.uuidString,
              UUID(uuidString: value(GraphTypedStoreAdapter.idKey) as? String ?? "") == id.rawValue else { throw GraphStoreError.corruptIdentity }
        guard value(GraphTypedStoreAdapter.stageKey) == nil else { throw GraphStoreError.pendingNativeOperation }
        if let entity = node as? Entity {
            guard entity.actionsWhenObject.contains(where: { $0.sharesBackingObject(with: membership) }) else { throw GraphStoreError.corruptIdentity }
        } else if let action = node as? Action {
            guard action.subjects.contains(where: { $0.sharesBackingObject(with: root) }) else { throw GraphStoreError.corruptIdentity }
        } else if let edge = node as? Relationship {
            guard edge.subject != nil || edge.object != nil,
                  !(edge.subject?.sharesBackingObject(with: root) == true && edge.object != nil) else { throw GraphStoreError.corruptIdentity }
        }
    }

    /// Batch every endpoint identity across all node kinds; duplicate IDs must not hide behind a kind filter.
    private func references(_ context: NSManagedObjectContext, node: Node, id: GraphNodeID,
                                   root: Entity, membership: Action, projectMetadata: Bool = false) throws -> [GraphNodeID: Node] {
        let entities: [Entity]
        if let edge = node as? Relationship { entities = [edge.subject, edge.object].compactMap { $0 } }
        else if let action = node as? Action { entities = action.subjects + action.objects }
        else { return [:] }
        var ids = Set<UUID>()
        for entity in entities where !entity.sharesBackingObject(with: root) {
            guard entity.node.value(forKey: graphAttribute) as? String == id.graphID.rawValue.uuidString,
                  let text = entity.node.value(forKey: nodeAttribute) as? String, let uuid = UUID(uuidString: text) else { throw GraphStoreError.unresolvedReference }
            ids.insert(uuid)
        }
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        var result: [GraphNodeID: Node] = [:]
        let checkCancellation = StoreNativeContext.cancellationCheck(in: context)
        for offset in stride(from: 0, to: ordered.count, by: 128) {
            try checkCancellation()
            for candidate in try fetch(context, graphID: id.graphID, nodeIDs: Array(ordered[offset..<min(offset + 128, ordered.count)])) {
                guard let text = candidate.node.value(forKey: nodeAttribute) as? String, let uuid = UUID(uuidString: text) else { throw GraphStoreError.corruptIdentity }
                let key = GraphNodeID(graphID: id.graphID, rawValue: uuid)
                guard result.updateValue(candidate, forKey: key) == nil else { throw GraphStoreError.duplicateIdentity }
            }
        }
        let keys: Set<String> = [GraphTypedStoreAdapter.graphKey, GraphTypedStoreAdapter.idKey, GraphTypedStoreAdapter.stageKey]
        let metadata = try projectMetadata
            ? GraphRuntimeMetadata(nodes: Array(result.values), keys: keys, context: context, minimumPersistedOwners: 0)
            : GraphRuntimeMetadata(nodes: Array(result.values), keys: keys, context: context)
        for (key, candidate) in result { try validateNode(candidate, id: key, root: root, membership: membership, metadata: metadata) }
        return result
    }

    /// Query-local candidates, including pending edits. No whole-resource identity audit.
    func queryNodes(_ context: NSManagedObjectContext, graphID: GraphID) throws -> [Node] {
        try fetch(context, graphID: graphID)
    }

    /// Validate only selected identities, their owned metadata and direct endpoints.
    /// Missing native routing outside this selection remains an explicit audit concern.
    func queryHeaders(_ context: NSManagedObjectContext, graphID: GraphID, ids: Set<GraphNodeID>) throws -> [GraphRecord] {
        guard !ids.isEmpty else { return [] }
        let check = StoreNativeContext.cancellationCheck(in: context)
        try check()
        let (root, membership) = try anchors(context, graphID: graphID)
        let ordered = ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        var result: [GraphRecord] = [], found = Set<GraphNodeID>()
        for offset in stride(from: 0, to: ordered.count, by: 128) {
            try check()
            let selected = Array(ordered[offset..<min(offset + 128, ordered.count)])
            let nodes = try fetch(context, graphID: graphID, nodeIDs: selected.map(\.rawValue))
            let metadata = try GraphRuntimeMetadata(nodes: nodes,
                keys: [GraphTypedStoreAdapter.graphKey, GraphTypedStoreAdapter.idKey,
                       GraphTypedStoreAdapter.stageKey, GraphTypedStoreAdapter.formatsKey], context: context, minimumPersistedOwners: 0)
            for node in nodes {
                try check()
                guard let text = node.node.value(forKey: nodeAttribute) as? String, let uuid = UUID(uuidString: text) else {
                    throw GraphStoreError.corruptIdentity
                }
                let id = GraphNodeID(graphID: graphID, rawValue: uuid)
                guard ids.contains(id), found.insert(id).inserted else { throw GraphStoreError.duplicateIdentity }
                try GraphNativeIdentityColumns.validate(node, graphID: graphID, nodeID: uuid)
                try validateNode(node, id: id, root: root, membership: membership, metadata: metadata)
                guard let formats = metadata.value(for: node, key: GraphTypedStoreAdapter.formatsKey) as? [String],
                      formats.isEmpty else { throw GraphStoreError.corruptIdentity }
                let endpoints = try references(context, node: node, id: id, root: root, membership: membership, projectMetadata: true)
                result.append(try GraphRecordMapper.snapshot(node, id: id, excludingRoot: root,
                    propertyKeys: [], projectedProperties: [:]) { entity in
                    guard let text = entity.node.value(forKey: self.nodeAttribute) as? String,
                          let uuid = UUID(uuidString: text) else { throw GraphStoreError.unresolvedReference }
                    let reference = GraphNodeID(graphID: graphID, rawValue: uuid)
                    guard let target = endpoints[reference], target is Entity,
                          target.sharesBackingObject(with: entity) else { throw GraphStoreError.unresolvedReference }
                    return reference
                })
            }
        }
        guard found == ids else { throw GraphStoreError.corruptIdentity }
        return result
    }

    func fileMetadata(_ context: NSManagedObjectContext, id: GraphNodeID) throws -> GraphFile? {
        let (root, membership) = try anchors(context, graphID: id.graphID)
        guard let node = try checkedNode(context, id: id, root: root, membership: membership) else {
            _ = try validateIdentityInventory(context, graphID: id.graphID)
            return nil
        }
        guard let file = node.node as? ManagedGraphFile else { return nil }
        return try file.metadata(id: id)
    }

    func attachmentOwnerExists(_ context: NSManagedObjectContext, id: GraphNodeID) throws -> Bool {
        let (root, membership) = try anchors(context, graphID: id.graphID)
        if let node = try checkedNode(context, id: id, root: root, membership: membership) { return node.runtimeTypeIfPresent != GraphAttachmentPayload.graphType }
        _ = try validateIdentityInventory(context, graphID: id.graphID)
        return false
    }

    /// Hits validate targets/references. Misses additionally audit the complete local identity inventory.
    /// Application body integrity remains an explicit validateAll responsibility.
    func record(_ context: NSManagedObjectContext, id: GraphNodeID) throws -> GraphRecord? {
        try GraphValueDecodingDiagnostics.checking {
            let (root, membership) = try anchors(context, graphID: id.graphID)
            guard let node = try checkedNode(context, id: id, root: root, membership: membership) else {
                // An index miss is not absence: a missing/misrouted column can hide a logical row.
                _ = try validateIdentityInventory(context, graphID: id.graphID)
                return nil
            }
            if node.runtimeTypeIfPresent == GraphAttachmentPayload.graphType {
                var record = try GraphRecord(id: id, type: GraphAttachmentPayload.graphType, tags: Set(node.tags), groups: Set(node.groups), createdDate: node.createdDateIfPresent)
                record.storedAttachment = try GraphNativeAttachmentStorage.read(node, id: id)
                record.legacyAttachment = GraphNativeAttachmentStorage.isLegacy(node)
                return record
            }
            let endpoints = try references(context, node: node, id: id, root: root, membership: membership)
            let raw = try GraphRecordMapper.snapshot(node, id: id, excludingRoot: root, propertyKeys: GraphNativePropertyStorage.enabled(context) ? [] : Set(node.properties.keys).subtracting(node[dynamicMember: GraphTypedStoreAdapter.formatsKey] as? [String] ?? [])) { entity in
                guard let graph = entity.node.value(forKey: graphAttribute) as? String,
                      graph == id.graphID.rawValue.uuidString,
                      let text = entity.node.value(forKey: nodeAttribute) as? String, let uuid = UUID(uuidString: text) else {
                    throw GraphStoreError.unresolvedReference
                }
                let reference = GraphNodeID(graphID: id.graphID, rawValue: uuid)
                guard let target = endpoints[reference],
                      target is Entity, target.sharesBackingObject(with: entity) else { throw GraphStoreError.unresolvedReference }
                return reference
            }
            guard let keys = node[dynamicMember: GraphTypedStoreAdapter.formatsKey] as? [String],
                  Set(keys).count == keys.count, keys.allSatisfy({ !$0.hasPrefix(GraphTypedStoreAdapter.prefix) }) else { throw GraphStoreError.corruptIdentity }
            if GraphNativePropertyStorage.enabled(context) {
                guard keys.isEmpty else { throw GraphStoreError.corruptIdentity }
                return try GraphRecord(id: id, type: raw.type, endpoints: raw.endpoints,
                    properties: GraphNativePropertyStorage.properties(node, keys: nil), tags: raw.tags, groups: raw.groups, createdDate: raw.createdDate, file: raw.file,
                    attachments: GraphNativeAttachmentStorage.values(context, ownerID: id))
            }
            var values = raw.properties.filter { !$0.key.hasPrefix(GraphTypedStoreAdapter.prefix) }
            for key in keys {
                guard let bytes = node[dynamicMember: key] as? Data else { throw GraphStoreError.corruptIdentity }
                values[key] = try GraphValueCodec.decode(bytes)
            }
            return try GraphRecord(id: id, type: raw.type, endpoints: raw.endpoints, properties: values,
                tags: raw.tags, groups: raw.groups, createdDate: raw.createdDate, file: raw.file)
        }
    }

    /// Metadata-only local audit. No application body is decoded or native identity repaired.
    /// Missing reads must audit the same context/view before returning nil.
    func validateIdentityInventory(_ context: NSManagedObjectContext, graphID: GraphID) throws -> Int {
        try GraphValueDecodingDiagnostics.checking {
            try identityInventory(context, graphID: graphID).nodes.count
        }
    }

    private func identityInventory(_ context: NSManagedObjectContext, graphID: GraphID) throws -> GraphTypedStoreAdapter.Session {
        _ = try anchors(context, graphID: graphID)
        let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
        guard session.stagedNodeIDs.isEmpty else { throw GraphStoreError.pendingNativeOperation }
        let checkCancellation = StoreNativeContext.cancellationCheck(in: context)
        // An unrouted row can lack both logical and native graph IDs. It must not disappear
        // from every per-graph inventory and turn an incomplete import into false absence.
        for node in try GraphTypedStoreAdapter.allNodes(session.graph) {
            try checkCancellation()
            guard let graphText = node.node.value(forKey: graphAttribute) as? String,
                  UUID(uuidString: graphText) != nil else { throw GraphStoreError.corruptIdentity }
            if node.type == GraphTypedStoreAdapter.rootType || node.type == GraphTypedStoreAdapter.membersType {
                guard node.node.value(forKey: nodeAttribute) == nil else { throw GraphStoreError.corruptIdentity }
            } else {
                guard let text = node.node.value(forKey: nodeAttribute) as? String,
                      UUID(uuidString: text) != nil else { throw GraphStoreError.corruptIdentity }
            }
        }
        for (id, node) in session.nodes {
            try checkCancellation()
            guard node.node.value(forKey: graphAttribute) as? String == graphID.rawValue.uuidString,
                  node.node.value(forKey: nodeAttribute) as? String == id.rawValue.uuidString else { throw GraphStoreError.corruptIdentity }
        }
        let indexed = try fetch(context, graphID: graphID)
        try checkCancellation()
        guard Set(indexed.map(\.runtimeObjectID)) == Set(session.nodes.values.map(\.runtimeObjectID)) else { throw GraphStoreError.corruptIdentity }
        return session
    }

    /// Full graph checks add payload/endpoint/file-owner validation to the identity audit.
    /// Neither operation certifies import completion or another replica's state.
    func validateAll(_ context: NSManagedObjectContext, graphID: GraphID) throws -> Int {
        try GraphValueDecodingDiagnostics.checking {
            let session = try identityInventory(context, graphID: graphID)
            let checkCancellation = StoreNativeContext.cancellationCheck(in: context)
            for (id, node) in session.nodes {
                try checkCancellation()
                try session.validate(session.snapshot(node, id: id, includingAttachments: false))
            }
            return session.nodes.count
        }
    }

    /// Fixture insertion uses the existing full validator; create-path optimization is not this experiment.
    func insert(_ context: NSManagedObjectContext, _ record: GraphRecord) throws {
        _ = try anchors(context, graphID: record.id.graphID)
        try GraphTypedStoreAdapter.Session(context, record.id.graphID, database: true).insert(record)
    }

    /// Local property/tag/group patch only. Shared writes, attachments and structural edits are not prototyped.
    func patch(_ context: NSManagedObjectContext, _ patch: GraphRecordPatch) throws -> GraphRecord {
        guard patch.endpoints == nil, patch.properties.keys.allSatisfy({ !$0.hasPrefix(GraphTypedStoreAdapter.prefix) }),
              let current = try record(context, id: patch.id), current.type != GraphAttachmentPayload.graphType else { throw GraphStoreError.unsupportedLayout }
        let node = try fetch(context, graphID: patch.id.graphID, nodeID: patch.id.rawValue).first!
        let updated = try patch.applying(to: current)
        var encoded = Set(node[dynamicMember: GraphTypedStoreAdapter.formatsKey] as! [String])
        let values = try patch.properties.compactMapValues { change -> Data? in
            if case .set(let value) = change { return try GraphValueCodec.encode(value) }
            return nil
        }
        for (key, change) in patch.properties {
            switch change {
            case .set: node[dynamicMember: key] = values[key]; encoded.insert(key)
            case .remove: node[dynamicMember: key] = nil; encoded.remove(key)
            }
        }
        node.add(tags: Array(patch.addingTags)); node.remove(tags: Array(patch.removingTags))
        node.add(to: Array(patch.addingGroups)); node.remove(from: Array(patch.removingGroups))
        node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = encoded.sorted()
        return updated
    }
}
