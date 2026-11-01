import CoreData
import CoreFoundation
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Explicit local v1 import. Native schema, identifiers and transport belong to the new store only.
enum GraphV1NativeConversion {
    static let legacyArchiveCodec = "GraphEvo.v1.secure-archive"
    static let receiptKey = GraphTypedStoreAdapter.prefix + "v1Conversion"
    private struct Canonical: Encodable {
        let legacyID: String
        let type: String
        let kind: String
        let subjects: [String]
        let objects: [String]
        let properties: [String: Data]
        let propertyVersions: [String: Int]
        let tags: [String]
        let groups: [String]
        let createdDate: Date?
    }
    static let adapter = GraphV1ConversionAdapter(sourceSchema: GraphRuntimeSchema.current,
        targetSchemaIdentifier: GraphRuntimeSchema.nativeIdentity.identifier,
        snapshot: { try snapshot($0, id: $1, limits: $2) }, receipt: { try receipt($0, id: $1) }, apply: { try apply($0, intent: $1, snapshot: $2) })

    private static func snapshot(_ context: NSManagedObjectContext, id: GraphID, limits: GraphV1ConversionLimits) throws -> GraphV1Snapshot {
        try GraphValueDecodingDiagnostics.checking {
            try limits.validate()
            guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
                  let store = coordinator.persistentStores.first, store.isReadOnly,
                  !(context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer) else { throw GraphV1ConversionError.unsupportedSource }
            let metadata = coordinator.metadata(for: store)
            guard metadata[StoreNativeContext.historySyncGraphKey] == nil, metadata[StoreNativeContext.workspaceKey] == nil,
                  let storeID = metadata[NSStoreUUIDKey] as? String else { throw GraphV1ConversionError.unsupportedSource }
            var rows = [NSManagedObject](), allowance = limits.maximumNativeRows
            for entity in coordinator.managedObjectModel.entities {
                guard let name = entity.name else { throw GraphV1ConversionError.unsupportedSource }
                let request = NSFetchRequest<NSManagedObject>(entityName: name); request.fetchLimit = allowance + 1
                let batch = try context.fetch(request)
                guard batch.count <= allowance else { throw GraphV1ConversionError.limitExceeded }
                allowance -= batch.count; rows += batch
            }
            let graph = GraphTypedStoreAdapter.facade(context)
            let nodes = try GraphTypedStoreAdapter.boundedNodes(graph, limit: limits.maximumRecords)
            guard rows.count + 5 * nodes.count + 128 <= GraphSyncLimits().maximumChanges else { throw GraphV1ConversionError.limitExceeded }
            let nativeIDs = Set(nodes.map { $0.node.objectID })
            var details = Set<String>()
            for row in rows where row.entity.relationshipsByName["node"] != nil {
                try StoreNativeContext.cancellationCheck(in: context)()
                guard let owner = row.value(forKey: "node") as? NSManagedObject, nativeIDs.contains(owner.objectID),
                      let name = row.value(forKey: "name") as? String, !name.isEmpty else { throw GraphV1ConversionError.unsupportedSource }
                let key = owner.objectID.uriRepresentation().absoluteString + "/" + (row.entity.name ?? "") + "/" + name
                guard details.insert(key).inserted else { throw GraphV1ConversionError.unsupportedSource }
                if row.entity.attributesByName["object"] != nil, row.value(forKey: "object") == nil { throw GraphV1ConversionError.unsupportedSource }
            }
            guard GraphStructuralValidator.validate(Array(nativeIDs), from: context, legacyReadOnly: true).allSatisfy(\.isValid) else { throw GraphV1ConversionError.unsupportedSource }
            var mapping: [String: GraphNodeID] = [:]
            for node in nodes {
                guard !node.node.objectID.isTemporaryID, let type = node.runtimeTypeIfPresent, !type.isEmpty,
                      !type.hasPrefix(GraphTypedStoreAdapter.prefix), type != GraphAttachmentPayload.graphType else { throw GraphV1ConversionError.unsupportedSource }
                let old = node.id
                guard mapping.updateValue(.init(graphID: id), forKey: old) == nil else { throw GraphV1ConversionError.unsupportedSource }
            }
            let reverse = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
            func reference(_ entity: Entity) throws -> GraphNodeID {
                guard nativeIDs.contains(entity.node.objectID), let mapped = mapping[entity.id] else { throw GraphV1ConversionError.unsupportedSource }
                return mapped
            }
            var records = [GraphRecord](), remaining = limits.maximumPayloadBytes, digest = SHA256()
            var versions = [GraphNodeID: [String: Int]]()
            for node in nodes.sorted(by: { $0.id < $1.id }) {
                try StoreNativeContext.cancellationCheck(in: context)()
                let old = node.id
                guard let mapped = mapping[old] else { throw GraphV1ConversionError.unsupportedSource }
                let endpoints: GraphEndpoints
                if let edge = node as? Relationship { endpoints = .relationship(subject: try edge.subject.map(reference), object: try edge.object.map(reference)) }
                else if let action = node as? Action { endpoints = .action(subjects: Set(try action.subjects.map(reference)), objects: Set(try action.objects.map(reference))) }
                else { endpoints = .entity }
                var values = [String: GraphValue](), canonicalValues = [String: GraphValue]()
                for (key, value) in node.properties {
                    guard !key.hasPrefix(GraphTypedStoreAdapter.prefix) else { throw GraphV1ConversionError.unsupportedSource }
                    values[key] = try valueFromLegacy(value, key: key)
                    canonicalValues[key] = try valueFromLegacy(value, key: key, canonical: true)
                }
                versions[mapped] = node.runtimePropertyVersions
                let record = try GraphRecord(id: mapped, type: node.type, endpoints: endpoints, properties: values,
                    tags: Set(node.tags), groups: Set(node.groups), createdDate: node.createdDateIfPresent)
                do {
                    try GraphQueryStoredCost.charge(64 + old.utf8.count + record.type.utf8.count, remaining: &remaining)
                    try GraphQueryStoredCost.charge(.object(values), remaining: &remaining)
                    for tag in record.tags { try GraphQueryStoredCost.charge(tag.utf8.count, remaining: &remaining) }
                    for group in record.groups { try GraphQueryStoredCost.charge(group.utf8.count, remaining: &remaining) }
                } catch { throw GraphV1ConversionError.limitExceeded }
                let kind: String, subjects: [GraphNodeID], objects: [GraphNodeID]
                switch endpoints {
                case .entity: kind = "entity"; subjects = []; objects = []
                case .relationship(let subject, let object): kind = "relationship"; subjects = subject.map { [$0] } ?? []; objects = object.map { [$0] } ?? []
                case .action(let left, let right): kind = "action"; subjects = Array(left); objects = Array(right)
                }
                try GraphQueryStoredCost.charge(32 * (subjects.count + objects.count), remaining: &remaining)
                let canonical = Canonical(legacyID: old, type: record.type, kind: kind,
                    subjects: try subjects.map { guard let old = reverse[$0] else { throw GraphV1ConversionError.unsupportedSource }; return old }.sorted(),
                    objects: try objects.map { guard let old = reverse[$0] else { throw GraphV1ConversionError.unsupportedSource }; return old }.sorted(),
                    properties: try canonicalValues.mapValues { try GraphValueCodec.encode($0) }, propertyVersions: node.runtimePropertyVersions, tags: record.tags.sorted(), groups: record.groups.sorted(), createdDate: record.createdDate)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                digest.update(data: try encoder.encode(canonical)); records.append(record)
            }
            guard try JSONEncoder().encode(mapping).count <= 3 * 1024 * 1024 else { throw GraphV1ConversionError.limitExceeded }
            return GraphV1Snapshot(storeID: storeID, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined(), records: records, nodeIDs: mapping, propertyVersions: versions)
        }
    }
    private static func receipt(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphV1ConversionReceipt? {
        try GraphValueDecodingDiagnostics.checking {
            let graph = GraphTypedStoreAdapter.facade(context), nodes = try GraphTypedStoreAdapter.allNodes(graph)
            if nodes.isEmpty {
                guard let coordinator = context.persistentStoreCoordinator else { throw GraphV1ConversionError.conflictingDestination }
                for entity in coordinator.managedObjectModel.entities {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity.name!); request.fetchLimit = 1
                    guard try context.fetch(request).isEmpty else { throw GraphV1ConversionError.conflictingDestination }
                }
                if let store = coordinator.persistentStores.first {
                    let metadata = coordinator.metadata(for: store)
                    guard metadata[StoreNativeContext.workspaceKey] == nil,
                          metadata[StoreNativeContext.historySyncGraphKey] == nil || metadata[StoreNativeContext.historySyncGraphKey] as? String == id.rawValue.uuidString else { throw GraphV1ConversionError.conflictingDestination }
                }
                return nil
            }
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            guard let data = root[dynamicMember: receiptKey] as? Data, data.count <= 4 * 1024 * 1024,
                  let value = try? JSONDecoder().decode(GraphV1ConversionReceipt.self, from: data),
                  value.intent.format == 1, value.intent.graphID == id, value.intent.fingerprint.count == 64,
                  value.nodeIDs.count <= 10_000, Set(value.nodeIDs.values).count == value.nodeIDs.count,
                  value.nodeIDs.values.allSatisfy({ $0.graphID == id }),
                  let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first,
                  coordinator.metadata(for: store)[NSStoreUUIDKey] as? String == value.targetStoreID else { throw GraphV1ConversionError.conflictingDestination }
            let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
            let deleted = try GraphMutationMetadata.deletedIDs(root)
            for (legacy, mapped) in value.nodeIDs {
                if let node = try session.node(mapped) {
                    guard node[dynamicMember: GraphTypedStoreAdapter.legacyKey] as? String == legacy else { throw GraphV1ConversionError.invalidReceipt }
                } else if !deleted.contains(mapped.rawValue.uuidString) { throw GraphV1ConversionError.invalidReceipt }
            }
            return value
        }
    }
    private static func apply(_ context: NSManagedObjectContext, intent: GraphV1ConversionIntent, snapshot: GraphV1Snapshot) throws -> GraphV1ConversionReceipt {
        try GraphValueDecodingDiagnostics.checking {
            guard intent.format == 1, intent.fingerprint == snapshot.fingerprint, intent.sourceStoreID == snapshot.storeID,
                  snapshot.records.count == snapshot.nodeIDs.count,
                  Set(snapshot.records.map(\.id)) == Set(snapshot.nodeIDs.values),
                  snapshot.nodeIDs.values.allSatisfy({ $0.graphID == intent.graphID }) else { throw GraphV1ConversionError.invalidReceipt }
            if let existing = try receipt(context, id: intent.graphID) {
                guard existing.intent == intent else { throw GraphV1ConversionError.conflictingDestination }
                return existing
            }
            let adapter = GraphCoordinatorFactory.adapter, id = intent.graphID
            try adapter.initialize(context, id, true); try adapter.initializePolicy?(context, id, .lastEditWins)
            let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
            GraphMutationMetadata.begin(context)
            let legacyByID = Dictionary(uniqueKeysWithValues: snapshot.nodeIDs.map { ($0.value, $0.key) })
            for record in snapshot.records.sorted(by: { ($0.endpoints.kind == .entity ? 0 : 1) < ($1.endpoints.kind == .entity ? 0 : 1) }) {
                try StoreNativeContext.cancellationCheck(in: context)()
                try session.insert(record)
                guard let node = try session.node(record.id) else { throw GraphStoreError.missingNode }
                node.setImportedCreatedDate(record.createdDate)
                try node.runtimeSetPropertyVersions(snapshot.propertyVersions[record.id] ?? [:])
                guard let legacy = legacyByID[record.id] else { throw GraphV1ConversionError.invalidReceipt }
                node[dynamicMember: GraphTypedStoreAdapter.legacyKey] = legacy
            }
            try GraphMutationMetadata.finish(context, graphID: id, clock: { Date() })
            for record in snapshot.records {
                guard let node = try session.node(record.id) else { throw GraphStoreError.missingNode }
                node[dynamicMember: GraphMutationMetadata.modifiedKey] = nil
                guard try session.snapshot(node, id: record.id) == record else { throw GraphV1ConversionError.invalidReceipt }
            }
            try GraphCoordinatorFactory.validateGraph(context, id: id)
            guard let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first,
                  let storeID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String else { throw GraphV1ConversionError.invalidReceipt }
            let value = GraphV1ConversionReceipt(intent: intent, targetStoreID: storeID, nodeIDs: snapshot.nodeIDs)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let data = try encoder.encode(value)
            guard data.count <= 4 * 1024 * 1024 else { throw GraphV1ConversionError.limitExceeded }
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            root[dynamicMember: receiptKey] = data
            context.processPendingChanges()
            guard context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects).count <= GraphSyncLimits().maximumChanges else { throw GraphV1ConversionError.limitExceeded }
            context.transactionAuthor = GraphSyncCheckpointAdapter.localAuthor
            return value
        }
    }
    static func valueFromLegacy(_ value: Any, key: String, depth: Int = 0, canonical: Bool = false) throws -> GraphValue {
        guard depth <= 64 else { throw GraphModelError.unsupportedLegacyValue(key) }
        // The historical unarchiver can return Optional<Any> boxed as Any. Missing data is not a null.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { throw GraphModelError.unsupportedLegacyValue(key) }
            return try valueFromLegacy(child.value, key: key, depth: depth + 1, canonical: canonical)
        }
        let wrapper: String?, wrapped: GraphValue?
        switch value {
        case let value as AnyCodableObject:
            wrapper = "AnyCodableObject"; wrapped = try valueFromLegacy(value.value, key: key, depth: depth + 1, canonical: true)
        case let value as NSArrayOfAnyCodableObject:
            wrapper = "NSArrayOfAnyCodableObject"; wrapped = .array(try value.items.map { try valueFromLegacy($0, key: key, depth: depth + 1, canonical: true) })
        case let value as DictionaryOfAnyCodableObject:
            wrapper = "DictionaryOfAnyCodableObject"; wrapped = .object(try value.items.mapValues { try valueFromLegacy($0, key: key, depth: depth + 1, canonical: true) })
        default: wrapper = nil; wrapped = nil
        }
        if let wrapper, let wrapped {
            // Fingerprint semantic wrapper contents, not keyed-archive object ordering.
            let bytes = canonical ? try GraphValueCodec.encode(wrapped) : try GraphArchiver.archive(value)
            return .encoded(try GraphEncodedValue(codec: canonical ? "GraphEvo.v1.canonical." + wrapper : legacyArchiveCodec, version: 1, data: bytes))
        }
        switch value {
        case is NSNull: return .null
        case let value as UUID: return .uuid(value)
        case let value as String: return .string(value)
        case let value as NSDecimalNumber: return .decimal(value.decimalValue)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
            switch String(cString: value.objCType) {
            case "f", "d": return .floatingPoint(value.doubleValue)
            case "C", "S", "I", "L", "Q": return .unsignedInteger(value.uint64Value)
            default: return .integer(value.int64Value)
            }
        case let value as Data: return .data(value)
        case let value as Date: return .date(value)
        case let value as URL: return .url(value)
        case let value as [Any]: return .array(try value.map { try valueFromLegacy($0, key: key, depth: depth + 1, canonical: canonical) })
        case let value as [String: Any]: return .object(try value.mapValues { try valueFromLegacy($0, key: key, depth: depth + 1, canonical: canonical) })
        default: throw GraphModelError.unsupportedLegacyValue(key)
        }
    }
}
