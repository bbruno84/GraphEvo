import CoreData
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Native stage handlers use the framework's generic migration objects. Domain
/// facades are used again after the container restores its normal managed classes.
@available(iOS 17, macOS 14, *)
enum GraphV1StagedMigration {
    enum StageFailure: Error { case missingContainer, missingStageURL, missingLegacyKey, unknownLegacyKey, conflictingProjection }
    struct Document: Codable {
        let format: Int
        let intent: GraphV1ConversionIntent
        let nodeIDs: [String: GraphNodeID]
    }
    static let rowBatch = 128
    static let adapter = GraphNativeV1MigrationAdapter(inspect: GraphV1NativeInventory.inspect) { seed, intent, source in
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(format: 1, intent: intent, nodeIDs: source.nodeIDs))
        guard data.count <= 4 * 1024 * 1024 else { throw GraphV1ConversionError.limitExceeded }
        return StoreNativeMigration(sourceSchema: GraphRuntimeSchema.current, seedURL: seed, document: data,
            prepare: { container in try prepare(container, document: document(container, intent: intent)) },
            configure: { description, target in
                guard let url = description.url,
                      let storedData = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)[StoreNativeMigration.documentKey] as? Data else {
                    throw GraphV1ConversionError.conflictingDestination
                }
                _ = try decode(storedData, intent: intent)
                GraphValueTransformer.register()
                let old = Model.makeModel()
                let oldOwner = NSPersistentStoreCoordinator(managedObjectModel: old)
                let targetOwner = NSPersistentStoreCoordinator(managedObjectModel: target)
                let stage = NSCustomMigrationStage(
                    migratingFrom: NSManagedObjectModelReference(model: old, versionChecksum: old.versionChecksum),
                    to: NSManagedObjectModelReference(model: target, versionChecksum: target.versionChecksum))
                _ = (oldOwner, targetOwner)
                stage.label = "GraphEvo v1 identities and S04 values"
                stage.didMigrateHandler = { manager, _ in
                    guard let container = manager.container else { throw StageFailure.missingContainer }
                    try transform(container, document: stageDocument(container))
                }
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                description.setOption(NSStagedMigrationManager([stage]), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
            }, finish: { try complete($0, intent: intent) })
    }

    static func document(_ container: NSPersistentContainer, intent: GraphV1ConversionIntent) throws -> Document {
        guard let store = container.persistentStoreCoordinator.persistentStores.first,
              let data = container.persistentStoreCoordinator.metadata(for: store)[StoreNativeMigration.documentKey] as? Data else {
            throw GraphV1ConversionError.conflictingDestination
        }
        return try decode(data, intent: intent)
    }

    /// Resolve each active store's durable operation rather than retaining an
    /// invocation's identity map in a model route shared by native migration.
    static func stageDocument(_ container: NSPersistentContainer) throws -> Document {
        guard let url = container.persistentStoreDescriptions.first?.url else { throw StageFailure.missingStageURL }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        guard let data = metadata[StoreNativeMigration.documentKey] as? Data,
              let value = try? JSONDecoder().decode(Document.self, from: data),
              metadata[StoreNativeContext.workspaceKey] as? String == value.intent.operationID.uuidString,
              metadata[StoreNativeContext.historySyncGraphKey] as? String == value.intent.graphID.rawValue.uuidString else {
            throw GraphV1ConversionError.conflictingDestination
        }
        return try decode(data, intent: value.intent)
    }

    static func decode(_ data: Data, intent: GraphV1ConversionIntent) throws -> Document {
        guard data.count <= 4 * 1024 * 1024,
              let value = try? JSONDecoder().decode(Document.self, from: data), value.format == 1,
              value.intent == intent, value.nodeIDs.count <= 10_000,
              Set(value.nodeIDs.values).count == value.nodeIDs.count,
              value.nodeIDs.values.allSatisfy({ $0.graphID == intent.graphID }) else { throw GraphV1ConversionError.conflictingDestination }
        return value
    }

    static func context(_ container: NSPersistentContainer) -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.undoManager = nil; context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = GraphSyncCheckpointAdapter.localAuthor
        return context
    }

    static func property(_ name: String, on node: NSManagedObject) throws -> NSManagedObject? {
        let rows = (node.value(forKey: "propertySet") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let matches = rows.filter { $0.value(forKey: "name") as? String == name }
        guard matches.count <= 1 else { throw GraphV1ConversionError.unsupportedSource }
        return matches.first
    }

    static func set(_ value: Any, key: String, node: NSManagedObject, context: NSManagedObjectContext) throws {
        if let existing = try property(key, on: node) {
            let old = existing.value(forKey: "object")
            if let text = value as? String, let prior = old as? String, text == prior { return }
            if let keys = value as? [String], let prior = old as? [String], keys == prior { return }
            throw GraphV1ConversionError.conflictingDestination
        }
        guard let entity = node.entity.relationshipsByName["propertySet"]?.destinationEntity?.name else { throw GraphV1ConversionError.unsupportedSource }
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        row.setValue(key, forKey: "name"); row.setValue(value, forKey: "object"); row.setValue(node, forKey: "node")
    }

    /// IDs are metadata only. A fixed inventory avoids offset/index movement
    /// while checkpoints update the rows being migrated.
    static func batches(_ context: NSManagedObjectContext, entity: String,
                        afterBatch: (@Sendable () throws -> Void)? = nil,
                        body: ([NSManagedObject]) throws -> Void) throws {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
        request.resultType = .managedObjectIDResultType
        let ids = try context.fetch(request)
        for start in stride(from: 0, to: ids.count, by: rowBatch) {
            try autoreleasepool {
                try Task.checkCancellation()
                let rows = try ids[start..<min(ids.count, start + rowBatch)].map { try context.existingObject(with: $0) }
                try body(rows)
                try Task.checkCancellation()
                if context.hasChanges { try context.save() }
            }
            context.reset()
            try afterBatch?()
        }
    }

    static func prepare(_ container: NSPersistentContainer, document stored: Document) throws {
        let context = context(container)
        try context.performAndWait {
            // No old-cloud history is carried into the new synchronization lineage.
            _ = try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture))
            for entity in GraphV1NativeInventory.nodeEntities {
                try batches(context, entity: entity) { nodes in
                    for node in nodes {
                        let previous = try property(GraphTypedStoreAdapter.legacyKey, on: node)?.value(forKey: "object") as? String
                        guard let type = node.value(forKey: "type") as? String,
                              let kind = node.value(forKey: "nodeClass") as? NSNumber else { throw GraphV1ConversionError.unsupportedSource }
                        let legacy = previous ?? (kind.stringValue + type + node.objectID.uriRepresentation().lastPathComponent)
                        guard let id = stored.nodeIDs[legacy] else { throw GraphV1ConversionError.staleSource }
                        try set(legacy, key: GraphTypedStoreAdapter.legacyKey, node: node, context: context)
                        try set(id.rawValue.uuidString, key: GraphTypedStoreAdapter.idKey, node: node, context: context)
                        try set(id.graphID.rawValue.uuidString, key: GraphTypedStoreAdapter.graphKey, node: node, context: context)
                        try set([String](), key: GraphTypedStoreAdapter.formatsKey, node: node, context: context)
                    }
                }
            }
        }
    }

    static func transform(_ container: NSPersistentContainer, document stored: Document,
                          afterBatch: (@Sendable () throws -> Void)? = nil) throws {
        let context = context(container)
        try context.performAndWait {
            for entity in [ModelIdentifier.entityPropertyName, ModelIdentifier.relationshipPropertyName, ModelIdentifier.actionPropertyName] {
                try batches(context, entity: entity, afterBatch: afterBatch) { rows in
                    try GraphValueDecodingDiagnostics.checking {
                        for row in rows {
                            guard let key = row.value(forKey: "name") as? String else { throw GraphV1ConversionError.unsupportedSource }
                            if key.hasPrefix(GraphTypedStoreAdapter.prefix) || row.value(forKey: GraphNativePropertyStorage.kindKey) != nil { continue }
                            guard let value = row.value(forKey: "object") else { throw GraphV1ConversionError.unsupportedSource }
                            let converted = try GraphV1NativeConversion.convertedProperty(value, key: key)
                            if let attachment = converted.attachment {
                                guard let owner = row.value(forKey: "node") as? NSManagedObject,
                                      let legacy = try property(GraphTypedStoreAdapter.legacyKey, on: owner)?.value(forKey: "object") as? String,
                                      let ownerID = stored.nodeIDs[legacy] else { throw StageFailure.missingLegacyKey }
                                let native = NSEntityDescription.insertNewObject(forEntityName: ModelIdentifier.entityName, into: context)
                                native.setValue(GraphAttachmentPayload.graphType, forKey: "type"); native.setValue(NodeClass.entity.rawValue, forKey: "nodeClass")
                                native.setValue(Date(), forKey: "createdDate")
                                let id = GraphNodeID(graphID: ownerID.graphID)
                                try set(id.rawValue.uuidString, key: GraphTypedStoreAdapter.idKey, node: native, context: context)
                                try set(id.graphID.rawValue.uuidString, key: GraphTypedStoreAdapter.graphKey, node: native, context: context)
                                try set([String](), key: GraphTypedStoreAdapter.formatsKey, node: native, context: context)
                                native.setValue(id.rawValue.uuidString, forKey: GraphNativeIdentityColumns.nodeAttribute)
                                native.setValue(id.graphID.rawValue.uuidString, forKey: GraphNativeIdentityColumns.graphAttribute)
                                let payload = try GraphAttachmentPayload(id: id, ownerID: ownerID, fileName: "attachment", contentType: "application/octet-stream", data: attachment.data)
                                var metadata = payload.content.metadata
                                metadata.propertyKey = key; metadata.codec = attachment.codec; metadata.codecVersion = attachment.version; metadata.origin = "v1"
                                metadata.sourcePropertyVersion = (row.value(forKey: "appDataVersion") as? NSNumber)?.intValue
                                try GraphNativeAttachmentStorage.write(try GraphAttachmentPayload(metadata: metadata, data: attachment.data).content, to: native)
                                context.delete(row)
                                continue
                            }
                            guard let value = converted.property else { throw GraphV1ConversionError.unsupportedSource }
                            let prepared = try GraphNativePropertyStorage.prepare(value)
                            row.setValue(nil, forKey: "object")
                            for (slot, _) in GraphNativePropertyStorage.slots { row.setValue(nil, forKey: slot) }
                            row.setValue(prepared.kind.rawValue, forKey: GraphNativePropertyStorage.kindKey)
                            row.setValue(prepared.encoding, forKey: GraphNativePropertyStorage.encodingKey)
                            if let field = prepared.field { row.setValue(prepared.value, forKey: field) }
                            row.setValue(GraphNativePropertyStorage.physicalKey(key), forKey: "name")
                        }
                    }
                }
            }
            for entity in GraphV1NativeInventory.nodeEntities {
                try batches(context, entity: entity) { nodes in
                    for node in nodes {
                        if node.value(forKey: "type") as? String == GraphAttachmentPayload.graphType { continue }
                        let legacyRow = try property(GraphTypedStoreAdapter.legacyKey, on: node)
                        guard let legacy = legacyRow?.value(forKey: "object") as? String else { throw StageFailure.missingLegacyKey }
                        guard let id = stored.nodeIDs[legacy] else { throw StageFailure.unknownLegacyKey }
                        for (key, expected) in [(GraphNativeIdentityColumns.graphAttribute, id.graphID.rawValue.uuidString),
                                                (GraphNativeIdentityColumns.nodeAttribute, id.rawValue.uuidString)] {
                            if let existing = node.value(forKey: key) {
                                guard existing as? String == expected else { throw StageFailure.conflictingProjection }
                            } else { node.setValue(expected, forKey: key) }
                        }
                    }
                }
            }
        }
    }

    static func complete(_ container: NSPersistentContainer, intent: GraphV1ConversionIntent,
                         afterCatalogSave: (@Sendable () throws -> Void)? = nil) throws {
        let stored = try document(container, intent: intent)
        let inspection = context(container)
        let existing = try inspection.performAndWait { () -> (root: Bool, receipt: Bool) in
            let request = NSFetchRequest<NSManagedObject>(entityName: ModelIdentifier.entityName)
            request.predicate = NSPredicate(format: "type == %@", GraphTypedStoreAdapter.rootType); request.fetchLimit = 1
            if try inspection.fetch(request).isEmpty { return (false, false) }
            guard try GraphTypedStoreAdapter.database.catalog(inspection) == [intent.graphID] else { throw GraphV1ConversionError.conflictingDestination }
            let root = try GraphTypedStoreAdapter.controlRoot(inspection, id: intent.graphID)
            if root[dynamicMember: GraphV1NativeConversion.receiptKey] == nil { return (true, false) }
            guard let receipt = try GraphV1NativeConversion.adapter.receipt(inspection, intent.graphID),
                  receipt.intent == intent, receipt.nodeIDs == stored.nodeIDs else { throw GraphV1ConversionError.conflictingDestination }
            return (true, true)
        }
        if existing.receipt {
            try inspection.performAndWait {
                guard let store = container.persistentStoreCoordinator.persistentStores.first else { throw GraphV1ConversionError.invalidReceipt }
                let before = container.persistentStoreCoordinator.metadata(for: store)
                do {
                    let root = try GraphTypedStoreAdapter.controlRoot(inspection, id: intent.graphID)
                    root[dynamicMember: GraphTypedStoreAdapter.prefix + "nativeV1Seal"] = UUID().uuidString
                    try releaseWorkspace(container); try inspection.save()
                } catch {
                    inspection.rollback(); container.persistentStoreCoordinator.setMetadata(before, for: store); throw error
                }
            }
            return
        }
        // Core Data may have persisted its target model before a did handler
        // completed. Per-row typed slots resume it without reapplying data.
        if !existing.root { try transform(container, document: stored) }
        let context = context(container)
        try context.performAndWait {
            context.userInfo[StoreNativeContext.containerKey] = container
            guard let store = container.persistentStoreCoordinator.persistentStores.first else { throw GraphV1ConversionError.invalidReceipt }
            context.userInfo[StoreNativeContext.privateURLKey] = store.url
            let id = intent.graphID
            let originalMetadata = container.persistentStoreCoordinator.metadata(for: store)
            do {
                if !existing.root { try GraphTypedStoreAdapter.createMigratedGraph(context, id: id) }
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
                let graph = GraphTypedStoreAdapter.facade(context)
                let all = try GraphTypedStoreAdapter.allNodes(graph)
                guard let membership = all.first(where: { $0.type == GraphTypedStoreAdapter.membersType }) as? Action else { throw GraphV1ConversionError.invalidReceipt }
                let app = all.filter { $0.type != GraphTypedStoreAdapter.rootType && $0.type != GraphTypedStoreAdapter.membersType }
                membership.add(objects: app.compactMap { $0 as? Entity })
                for node in app {
                    if let action = node as? Action { action.add(subjects: root) }
                    if let edge = node as? Relationship, edge.subject == nil && edge.object == nil { edge.subject = root }
                }
                if !existing.root { try GraphNativeIdentityDatabaseAdapter.activateMigratedGraph(context, graphID: id) }
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                guard session.nodes.filter({ $0.value.type != GraphAttachmentPayload.graphType }).count == stored.nodeIDs.count else { throw GraphV1ConversionError.invalidReceipt }
                let reverse = Dictionary(uniqueKeysWithValues: stored.nodeIDs.map { ($0.value, $0.key) })
                var digest = SHA256()
                for legacy in stored.nodeIDs.keys.sorted() {
                    let nodeID = stored.nodeIDs[legacy]!
                    guard let node = try session.node(nodeID), node[dynamicMember: GraphTypedStoreAdapter.legacyKey] as? String == legacy,
                          let record = try session.record(nodeID) else { throw GraphV1ConversionError.invalidReceipt }
                    var versions = node.runtimePropertyVersions
                    for (attachmentID, attachmentNode) in session.nodes where attachmentNode.runtimeTypeIfPresent == GraphAttachmentPayload.graphType {
                        let metadata = try GraphNativeAttachmentStorage.metadata(attachmentNode, id: attachmentID)
                        if metadata.ownerID == nodeID, let key = metadata.propertyKey, let version = metadata.sourcePropertyVersion { versions[key] = version }
                    }
                    try GraphV1NativeInventory.append(record, legacy: legacy, reverse: reverse, versions: versions, digest: &digest)
                    for row in node.node.propertySet where !row.name.hasPrefix(GraphTypedStoreAdapter.prefix) { context.refresh(row, mergeChanges: false) }
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == intent.fingerprint else { throw GraphV1ConversionError.staleSource }
                try GraphCoordinatorFactory.validateGraph(context, id: id)
                guard let storeID = container.persistentStoreCoordinator.metadata(for: store)[NSStoreUUIDKey] as? String else { throw GraphV1ConversionError.invalidReceipt }
                let receipt = GraphV1ConversionReceipt(intent: intent, targetStoreID: storeID, nodeIDs: stored.nodeIDs)
                let data = try JSONEncoder().encode(receipt)
                guard data.count <= 4 * 1024 * 1024 else { throw GraphV1ConversionError.limitExceeded }
                root[dynamicMember: GraphMutationMetadata.policyKey] = GraphConflictPolicy.lastEditWins.rawValue
                // Publish the catalog while ordinary admission is still held.
                // Its target PH transaction supplies the new baseline token.
                try Task.checkCancellation(); if context.hasChanges { try context.save() }
                try afterCatalogSave?()
                try GraphSyncCheckpointAdapter.seedNativeConversion(context, graphID: id, ids: Set(session.nodes.keys))
                root[dynamicMember: GraphV1NativeConversion.receiptKey] = data
                root[dynamicMember: GraphTypedStoreAdapter.prefix + "nativeV1Seal"] = UUID().uuidString
                try releaseWorkspace(container)
                try Task.checkCancellation(); try context.save()
            } catch {
                context.rollback()
                container.persistentStoreCoordinator.setMetadata(originalMetadata, for: store)
                throw error
            }
        }
    }

    static func releaseWorkspace(_ container: NSPersistentContainer) throws {
        guard let store = container.persistentStoreCoordinator.persistentStores.first else { throw GraphV1ConversionError.invalidReceipt }
        var metadata = container.persistentStoreCoordinator.metadata(for: store)
        metadata.removeValue(forKey: StoreNativeContext.workspaceKey)
        metadata.removeValue(forKey: StoreNativeMigration.documentKey)
        container.persistentStoreCoordinator.setMetadata(metadata, for: store)
    }
}
