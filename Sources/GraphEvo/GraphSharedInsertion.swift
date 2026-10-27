import CloudKit
import CoreData
import Foundation
import GraphEvoRuntime
import GraphEvoModel

/// Durable intent survives callback uncertainty; it contains synthetic/application values, never invitations.
struct GraphSharedInsertionPlan: Codable, Sendable {
    let version: Int
    let operationID: UUID
    let graphID: GraphID
    let rows: [Row]
    let patch: Patch?

    struct Row: Codable, Sendable {
        let id: GraphNodeID
        let type: String
        let kind: String
        let subjects: [GraphNodeID]
        let objects: [GraphNodeID]
        let properties: [String: Data]
        let tags: Set<String>
        let groups: Set<String>
        let createdDate: Date?

        init(_ record: GraphRecord) throws {
            id = record.id; type = record.type
            switch record.endpoints {
            case .entity: kind = "entity"; subjects = []; objects = []
            case .relationship(let subject, let object): kind = "relationship"; subjects = subject.map { [$0] } ?? []; objects = object.map { [$0] } ?? []
            case .action(let first, let second): kind = "action"; subjects = Array(first); objects = Array(second)
            }
            properties = try record.properties.mapValues { try GraphValueCodec.encode($0) }
            tags = record.tags; groups = record.groups; createdDate = record.createdDate
        }

        func record() throws -> GraphRecord {
            let endpoints: GraphEndpoints
            switch kind {
            case "entity":
                guard subjects.isEmpty, objects.isEmpty else { throw GraphStoreError.corruptIdentity }
                endpoints = .entity
            case "relationship":
                guard subjects.count <= 1, objects.count <= 1 else { throw GraphStoreError.corruptIdentity }
                endpoints = .relationship(subject: subjects.first, object: objects.first)
            case "action": endpoints = .action(subjects: Set(subjects), objects: Set(objects))
            default: throw GraphStoreError.unsupportedLayout
            }
            return try GraphRecord(id: id, type: type, endpoints: endpoints,
                properties: properties.mapValues { try GraphValueCodec.decode($0) }, tags: tags, groups: groups, createdDate: createdDate)
        }
    }

    struct Patch: Codable, Sendable {
        let targetID: GraphNodeID
        let properties: [String: Data]
        let removingProperties: Set<String>
        let addingTags: Set<String>
        let removingTags: Set<String>
        let addingGroups: Set<String>
        let removingGroups: Set<String>
        let endpoints: Row?

        init(_ patch: GraphRecordPatch, current: GraphRecord) throws {
            targetID = patch.id
            properties = try patch.properties.compactMapValues { change in
                if case .set(let value) = change { return try GraphValueCodec.encode(value) }; return nil
            }
            removingProperties = Set(patch.properties.compactMap { key, change in
                if case .remove = change { return key }; return nil
            })
            addingTags = patch.addingTags; removingTags = patch.removingTags
            addingGroups = patch.addingGroups; removingGroups = patch.removingGroups
            endpoints = try patch.endpoints.map { try Row(GraphRecord(id: patch.id, type: current.type, endpoints: $0)) }
        }

        func value() throws -> GraphRecordPatch {
            guard Set(properties.keys).isDisjoint(with: removingProperties) else { throw GraphStoreError.corruptIdentity }
            var changes = try properties.mapValues { GraphPropertyChange.set(try GraphValueCodec.decode($0)) }
            for key in removingProperties { changes[key] = .remove }
            return try GraphRecordPatch(id: targetID, properties: changes, addingTags: addingTags, removingTags: removingTags,
                addingGroups: addingGroups, removingGroups: removingGroups, endpoints: try endpoints?.record().endpoints)
        }
    }

    init(graphID: GraphID, records: [GraphRecord]) throws {
        version = 1; operationID = UUID(); self.graphID = graphID
        rows = try records.map(Row.init)
        patch = nil
    }

    init(graphID: GraphID, patch: GraphRecordPatch, current: GraphRecord) throws {
        guard patch.id.graphID == graphID, current.id == patch.id else { throw GraphStoreError.foreignGraph }
        _ = try patch.applying(to: current)
        version = 2; operationID = UUID(); self.graphID = graphID
        self.patch = try Patch(patch, current: current)
        let empty: GraphEndpoints
        switch current.endpoints.kind {
        case .entity: empty = .entity
        case .relationship: empty = .relationship(subject: nil, object: nil)
        case .action: empty = .action(subjects: [], objects: [])
        }
        let values = try self.patch!.properties.mapValues { try GraphValueCodec.decode($0) }
        rows = try [Row(GraphRecord(id: GraphNodeID(graphID: graphID), type: current.type, endpoints: empty,
            properties: values, tags: patch.addingTags, groups: patch.addingGroups))]
    }

    func records() throws -> [GraphRecord] {
        guard ((version == 1 && patch == nil) || (version == 2 && patch != nil)), !rows.isEmpty, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.id.graphID == graphID }) else { throw GraphStoreError.corruptIdentity }
        if let patch {
            guard rows.count == 1, patch.targetID.graphID == graphID, rows[0].id != patch.targetID,
                  rows[0].tags == patch.addingTags, rows[0].groups == patch.addingGroups,
                  try rows[0].properties.mapValues({ try GraphValueCodec.decode($0) }) == patch.properties.mapValues({ try GraphValueCodec.decode($0) }),
                  rows[0].subjects.isEmpty, rows[0].objects.isEmpty else { throw GraphStoreError.corruptIdentity }
            _ = try patch.value()
        }
        return try rows.map { try $0.record() }
    }
}

struct GraphSharedCompletion: Sendable {
    let nodeIDs: [GraphNodeID]
    let record: GraphRecord?
}

/// A local operation ledger avoids making one shared root property a distributed lock.
/// It is stored beside the originating shared store and must travel with its backups.
enum GraphSharedInsertionJournal {
    static func folder(for storeURL: URL) -> URL { storeURL.appendingPathExtension("graphevo-operations") }

    static func url(graphID: GraphID, context: NSManagedObjectContext) throws -> URL {
        guard let sharedURL = context.userInfo[StoreNativeContext.sharedURLKey] as? URL else {
            throw GraphSharingError.sharedStoreRequired
        }
        return folder(for: sharedURL).appendingPathComponent(graphID.rawValue.uuidString).appendingPathComponent("insertion.json")
    }

    static func read(graphID: GraphID, context: NSManagedObjectContext) throws -> GraphSharedInsertionPlan? {
        let path = try url(graphID: graphID, context: context)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let plan = try JSONDecoder().decode(GraphSharedInsertionPlan.self, from: Data(contentsOf: path))
        guard plan.graphID == graphID else { throw GraphStoreError.foreignGraph }
        _ = try plan.records()
        return plan
    }

    static func reserve(_ plan: GraphSharedInsertionPlan, context: NSManagedObjectContext) throws {
        let path = try url(graphID: plan.graphID, context: context)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw GraphStoreError.pendingNativeOperation }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(plan)
        #if os(iOS)
        try bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: path, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @discardableResult static func clearIfOwned(operationID: UUID, graphID: GraphID, context: NSManagedObjectContext) throws -> Bool {
        guard try read(graphID: graphID, context: context)?.operationID == operationID else { return false }
        try clear(graphID: graphID, context: context)
        return true
    }

    static func clear(graphID: GraphID, context: NSManagedObjectContext) throws {
        let path = try url(graphID: graphID, context: context)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

extension GraphTypedStoreAdapter {
    static func stageInsertion(_ plan: GraphSharedInsertionPlan, context: NSManagedObjectContext) throws -> [Node] {
        let session = try Session(context, plan.graphID, database: true)
        let records = try plan.records()
        try session.requireWriteAccess()
        guard session.isShared, let root = session.root,
              let store = root.runtimeObjectID.persistentStore else { throw GraphSharingError.participantRequired }
        if let patch = plan.patch {
            guard let current = try session.record(patch.targetID) else { throw GraphStoreError.missingNode }
            let change = try patch.value()
            guard change.properties.keys.allSatisfy({ !$0.hasPrefix(prefix) }) else { throw GraphStoreError.reservedName }
            let updated = try change.applying(to: current)
            guard records[0].type == current.type, records[0].endpoints.kind == current.endpoints.kind else { throw GraphStoreError.corruptIdentity }
            try session.validate(updated)
            _ = try session.resolve(updated.endpoints)
        }
        let claimed = Set(try allNodes(session.graph).filter {
            $0[dynamicMember: graphKey] as? String == plan.graphID.rawValue.uuidString
        }.compactMap { node -> UUID? in
            guard let value = node[dynamicMember: idKey] as? String else { return nil }
            return UUID(uuidString: value)
        })
        let entityIDs = Set(records.filter { $0.endpoints.kind == .entity }.map(\.id))
        for record in records {
            try session.validate(record)
            guard !claimed.contains(record.id.rawValue) else { throw GraphStoreError.duplicateIdentity }
            for reference in references(record.endpoints) {
                guard reference.graphID == plan.graphID,
                      entityIDs.contains(reference) || session.nodes[reference] is Entity else { throw GraphStoreError.unresolvedReference }
            }
        }
        // Reserve local intent before the framework can partially persist new objects.
        try GraphSharedInsertionJournal.reserve(plan, context: context)
        var nodes: [Node] = []
        for (record, row) in zip(records, plan.rows) {
            let node: Node
            switch record.endpoints.kind {
            case .entity: node = Entity(record.type, graph: session.graph)
            case .relationship: node = Relationship(record.type, graph: session.graph)
            case .action: node = Action(record.type, graph: session.graph)
            }
            stamp(node, id: record.id)
            node[dynamicMember: stageKey] = plan.operationID.uuidString
            node[dynamicMember: formatsKey] = row.properties.keys.sorted()
            for (key, value) in row.properties { node[dynamicMember: key] = value }
            node.add(tags: Array(record.tags)); node.add(to: Array(record.groups))
            if let date = record.createdDate { node.setCreatedDate(date) }
            // Only new objects are linked together. No relation to an existing shared member yet.
            try node.runtimeAssignOwnedObjects(to: store, in: context)
            nodes.append(node)
        }
        return nodes
    }

    static func references(_ endpoints: GraphEndpoints) -> Set<GraphNodeID> {
        switch endpoints {
        case .entity: return []
        case .relationship(let a, let b): return Set([a, b].compactMap { $0 })
        case .action(let a, let b): return a.union(b)
        }
    }

    static func finishInsertion(_ plan: GraphSharedInsertionPlan, context: NSManagedObjectContext,
                                container: NSPersistentCloudKitContainer) throws -> GraphSharedCompletion {
        let session = try Session(context, plan.graphID, database: true)
        guard session.isShared, let root = session.root, let membership = session.membership,
              let pending = try GraphSharedInsertionJournal.read(graphID: plan.graphID, context: context) else { throw GraphStoreError.corruptIdentity }
        let pendingPatch = try pending.patch?.value(), expectedPatch = try plan.patch?.value()
        guard pending.operationID == plan.operationID, pending.graphID == plan.graphID, pendingPatch == expectedPatch,
              try pending.records() == plan.records() else { throw GraphStoreError.pendingNativeOperation }
        let share = try GraphSharingNative.share(root.runtimeObjectID, container: container)
        guard container.canUpdateRecord(forManagedObjectWith: root.runtimeObjectID),
              share.currentUserParticipant?.role == .privateUser,
              share.currentUserParticipant?.acceptanceStatus == .accepted,
              share.currentUserParticipant?.permission == .readWrite else { throw GraphStoreError.permissionDenied }
        let staged = try allNodes(session.graph).filter {
            $0[dynamicMember: graphKey] as? String == plan.graphID.rawValue.uuidString &&
            $0[dynamicMember: stageKey] as? String == plan.operationID.uuidString
        }
        let records = try plan.records()
        if staged.isEmpty, let patch = plan.patch {
            guard let current = try session.record(patch.targetID), try patch.value().applying(to: current) == current else {
                throw GraphStoreError.pendingNativeOperation
            }
            try GraphSharedInsertionJournal.clear(graphID: plan.graphID, context: context)
            return GraphSharedCompletion(nodeIDs: [patch.targetID], record: current)
        }
        if staged.isEmpty, records.allSatisfy({ session.nodes[$0.id] != nil }) {
            // Local finalization committed before journal cleanup or process interruption.
            for record in records {
                guard let node = session.nodes[record.id] else { throw GraphStoreError.corruptIdentity }
                let value = try session.snapshot(node, id: record.id)
                guard value.type == record.type, value.endpoints == record.endpoints,
                      value.properties == record.properties, value.tags == record.tags, value.groups == record.groups else {
                    throw GraphStoreError.corruptIdentity
                }
            }
            try GraphSharedInsertionJournal.clear(graphID: plan.graphID, context: context)
            return GraphSharedCompletion(nodeIDs: records.map(\.id), record: nil)
        }
        guard staged.count == records.count else { throw GraphStoreError.pendingNativeOperation }
        var found: [GraphNodeID: Node] = [:]
        for node in staged {
            guard let text = node[dynamicMember: idKey] as? String, let uuid = UUID(uuidString: text) else { throw GraphStoreError.corruptIdentity }
            let id = GraphNodeID(graphID: plan.graphID, rawValue: uuid)
            guard found.updateValue(node, forKey: id) == nil, records.contains(where: { $0.id == id && $0.type == node.type }) else {
                throw GraphStoreError.corruptIdentity
            }
            for objectID in node.runtimeOwnedObjectIDs {
                guard container.recordID(for: objectID)?.zoneID == share.recordID.zoneID else { throw GraphStoreError.pendingNativeOperation }
            }
            session.nodes[id] = node
        }
        for record in records {
            // Native assignment can overlap remote owner deletion; revalidate logical dependencies before linking.
            try session.validate(record)
            guard let node = found[record.id], session.kind(node) == record.endpoints.kind else { throw GraphStoreError.corruptIdentity }
            let stagedValue = try session.snapshot(node, id: record.id)
            guard stagedValue.properties == record.properties, stagedValue.tags == record.tags,
                  stagedValue.groups == record.groups,
                  record.createdDate == nil || stagedValue.createdDate == record.createdDate else { throw GraphStoreError.corruptIdentity }
        }
        var patched: GraphRecord?
        if let patch = plan.patch, let staging = found[records[0].id] {
            guard let target = session.nodes[patch.targetID], session.kind(target) == session.kind(staging) else { throw GraphStoreError.missingNode }
            let moved = try target.runtimeMoveDetails(from: staging, propertyNames: Set(records[0].properties.keys))
            target[dynamicMember: formatsKey] = try session.encodedKeys(target).union(moved).sorted()
            patched = try session.patch(patch.value(), completing: plan.operationID)
            staging.delete()
        } else {
            for record in records {
                guard let node = found[record.id] else { throw GraphStoreError.corruptIdentity }
                let (subjects, objects) = try session.resolve(record.endpoints)
                if let entity = node as? Entity { membership.add(objects: entity) }
                session.setEndpoints(node, subjects: subjects, objects: objects)
                node[dynamicMember: stageKey] = nil
            }
        }
        try context.save()
        // A cleanup failure must not turn a committed graph mutation into a failed insertion.
        // Status retains pending intent and recovery can retry cleanup without another share call.
        try? GraphSharedInsertionJournal.clear(graphID: plan.graphID, context: context)
        return GraphSharedCompletion(nodeIDs: patched.map { [$0.id] } ?? records.map(\.id), record: patched)
    }
}

enum GraphSharedNativeOperation {
    static func run(container: NSPersistentCloudKitContainer,
                    makePlan: @escaping @Sendable (NSManagedObjectContext) throws -> GraphSharedInsertionPlan) async throws -> GraphSharedCompletion {
        let plan = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GraphSharedInsertionPlan, any Error>) in
            container.performBackgroundTask { context in
                GraphSharingNative.prepare(context, container: container)
                var prepared: GraphSharedInsertionPlan?
                var invoked = false
                do {
                    let plan = try makePlan(context)
                    prepared = plan
                    let rootID = try GraphTypedStoreAdapter.mirroringRoot(context, id: plan.graphID).runtimeObjectID
                    let share = try GraphSharingNative.share(rootID, container: container)
                    let nodes = try GraphTypedStoreAdapter.stageInsertion(plan, context: context)
                    let objects = nodes.flatMap(\.runtimeOwnedObjects)
                    invoked = true
                    container.share(objects, to: share) { _, assigned, _, error in
                        context.perform {
                            defer { context.reset() }
                            do {
                                if let error { throw error }
                                guard assigned?.recordID == share.recordID else { throw GraphMirroringError.missingNativeResponse }
                                if context.hasChanges { try context.save() }
                                continuation.resume(returning: plan)
                            } catch { context.rollback(); continuation.resume(throwing: error) }
                        }
                    }
                } catch {
                    context.rollback()
                    if !invoked, let plan = prepared {
                        _ = try? GraphSharedInsertionJournal.clearIfOwned(operationID: plan.operationID, graphID: plan.graphID, context: context)
                    }
                    context.reset()
                    continuation.resume(throwing: error)
                }
            }
        }
        #if DEBUG
        try await GraphSharedOperationTestHooks.didAssign(plan.operationID, graphID: plan.graphID)
        #endif
        return try await container.performBackgroundTask { context in
            GraphSharingNative.prepare(context, container: container)
            defer { context.rollback(); context.reset() }
            return try GraphTypedStoreAdapter.finishInsertion(plan, context: context, container: container)
        }
    }
}

extension GraphStore {
    /// New participant members require a native assignment phase before linking to the live graph.
    /// After a partial native failure, inspect status and recover the recorded intent rather than replaying insertion.
    @discardableResult public func insertShared(_ records: [GraphRecord]) async throws -> [GraphNodeID] {
        let plan = try GraphSharedInsertionPlan(graphID: id, records: records)
        return try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            guard !records.isEmpty else { return [] }
            return try await GraphSharedNativeOperation.run(container: container) { _ in plan }.nodeIDs
        }
    }

    @discardableResult public func insertShared<Model: GraphModel>(_ model: Model) async throws -> GraphNodeID {
        let ids = try await insertShared([GraphRecord(model)])
        guard let id = ids.first else { throw GraphStoreError.corruptIdentity }
        return id
    }

    /// Adds new shared detail rows through native assignment, then applies only the requested delta.
    /// Returns a detached record; application model decoding is a separate explicit operation.
    public func patchShared(_ patch: GraphRecordPatch) async throws -> GraphRecord {
        let graphID = id
        guard patch.id.graphID == graphID else { throw GraphStoreError.foreignGraph }
        return try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            let completion = try await GraphSharedNativeOperation.run(container: container) { context in
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                try session.requireWriteAccess()
                guard session.isShared, let current = try session.record(patch.id) else { throw GraphSharingError.participantRequired }
                return try GraphSharedInsertionPlan(graphID: graphID, patch: patch, current: current)
            }
            guard let record = completion.record else { throw GraphStoreError.corruptIdentity }
            return record
        }
    }

    /// Finishes only an already assigned batch. Missing mapping remains pending; no native share call is replayed.
    @discardableResult public func recoverSharedOperation() async throws -> [GraphNodeID] {
        let graphID = id
        return try await nativeOperation { native in
            let container = try GraphSharingNative.cloud(native)
            return try await container.performBackgroundTask { context in
                GraphSharingNative.prepare(context, container: container)
                defer { context.rollback(); context.reset() }
                _ = try GraphTypedStoreAdapter.mirroringRoot(context, id: graphID)
                guard let plan = try GraphSharedInsertionJournal.read(graphID: graphID, context: context) else { return [] }
                return try GraphTypedStoreAdapter.finishInsertion(plan, context: context, container: container).nodeIDs
            }
        }
    }
}
