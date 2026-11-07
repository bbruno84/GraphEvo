import CoreData
import GraphEvoModel
import GraphEvoStore

/// Fixed attachment fields are separate from application property envelopes.
enum GraphNativeAttachmentStorage {
    static let identifier = "GraphEvo.v2.schema.6"
    static let fileIdentifier = "GraphEvo.v2.schema.7.local-files"
    static let ownerKey = "geAttachmentOwner", propertyKey = "geAttachmentKey"
    static let metadataKey = "geAttachmentMetadata", contentKey = "geAttachmentContent"

    static func makeModel(files: Bool = false) -> NSManagedObjectModel {
        let model = files ? ManagedGraphFile.makeModel() : GraphNativePropertyStorage.makeModel()
        let entity = model.entitiesByName[ModelIdentifier.entityName]!
        for (name, type) in [(ownerKey, NSAttributeType.stringAttributeType), (propertyKey, .stringAttributeType),
                             (metadataKey, .binaryDataAttributeType), (contentKey, .binaryDataAttributeType)] {
            let attribute = NSAttributeDescription()
            attribute.name = name; attribute.attributeType = type; attribute.isOptional = true
            attribute.allowsExternalBinaryDataStorage = name == contentKey
            attribute.preservesValueInHistoryOnDeletion = name == ownerKey || name == propertyKey
            entity.properties.append(attribute)
        }
        entity.indexes.append(NSFetchIndexDescription(name: "ge_attachment_owner_key", elements:
            [GraphNativeIdentityColumns.graphAttribute, ownerKey, propertyKey].map {
                NSFetchIndexElementDescription(property: entity.propertiesByName[$0]!, collationType: .binary)
            }))
        model.versionIdentifiers = [files ? fileIdentifier : identifier]
        return model
    }

    static func enabled(_ context: NSManagedObjectContext) -> Bool {
        let versions = context.persistentStoreCoordinator?.managedObjectModel.versionIdentifiers
        return versions == [AnyHashable(identifier)] || versions == [AnyHashable(fileIdentifier)]
    }

    static func metadata(_ node: Node, id: GraphNodeID) throws -> GraphAttachmentMetadata {
        guard node is Entity, !(node.node is ManagedGraphFile) else { throw GraphAttachmentError.notAnAttachment }
        if node.node.entity.attributesByName[metadataKey] == nil {
            let value = try isLegacy(node) ? legacyContent(node, id: id).metadata : GraphAttachmentPayload.decodeMetadata(legacyData(node, key: GraphAttachmentPayload.metadataKey))
            guard value.id == id else { throw GraphAttachmentError.invalidMetadata }
            return value
        }
        guard let bytes = node.node.value(forKey: metadataKey) as? Data else { throw GraphAttachmentError.invalidMetadata }
        let metadata = try GraphAttachmentPayload.decodeMetadata(bytes)
        guard metadata.id == id,
              node.node.value(forKey: ownerKey) as? String == metadata.ownerID.rawValue.uuidString,
              node.node.value(forKey: propertyKey) as? String == metadata.propertyKey.map(GraphNativePropertyStorage.physicalKey) else {
            throw GraphAttachmentError.invalidMetadata
        }
        return metadata
    }

    static func read(_ node: Node, id: GraphNodeID) throws -> GraphAttachmentContent {
        if node.node.entity.attributesByName[metadataKey] == nil { return try legacyContent(node, id: id) }
        let metadata = try metadata(node, id: id)
        guard let data = node.node.value(forKey: contentKey) as? Data else { throw GraphAttachmentError.incompleteOrInvalidContent }
        return try GraphAttachmentPayload(metadata: metadata, data: data.withUnsafeBytes { Data($0) }).content
    }

    static func isLegacy(_ node: Node) -> Bool {
        node.node.entity.attributesByName[metadataKey] == nil &&
        !node.node.propertySet.contains(where: { $0.name == GraphAttachmentPayload.metadataKey })
    }

    private static func legacyData(_ node: Node, key: String) throws -> Data {
        if GraphNativePropertyStorage.enabled(node.node.managedObjectContext!),
           let row = node.node.propertySet.first(where: { $0.name == key }),
           let bytes = row.value(forKey: "ge2Bytes") as? Data { return bytes.withUnsafeBytes { Data($0) } }
        guard let envelope = node[dynamicMember: key] as? Data,
              case .data(let bytes) = try GraphLegacyValueCodec.decode(envelope) else { throw GraphAttachmentError.incompleteOrInvalidContent }
        return bytes
    }

    private static func legacyContent(_ node: Node, id: GraphNodeID) throws -> GraphAttachmentContent {
        if isLegacy(node) {
            let content = try GraphAttachmentPayload.decodeLegacyEnvelope(legacyData(node, key: GraphAttachmentPayload.contentKey))
            guard content.metadata.id == id else { throw GraphAttachmentError.invalidMetadata }
            return content
        }
        let metadata = try GraphAttachmentPayload.decodeMetadata(legacyData(node, key: GraphAttachmentPayload.metadataKey))
        guard metadata.id == id else { throw GraphAttachmentError.invalidMetadata }
        return try GraphAttachmentPayload(metadata: metadata, data: legacyData(node, key: GraphAttachmentPayload.contentKey)).content
    }

    static func listMetadata(_ context: NSManagedObjectContext, graphID: GraphID, ownerID: GraphNodeID?) throws -> [GraphAttachmentMetadata] {
        let request = NSFetchRequest<NSDictionary>(entityName: ModelIdentifier.entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [GraphNativeIdentityColumns.nodeAttribute, ownerKey, propertyKey, metadataKey]
        var predicates = [NSPredicate(format: "ge2GraphID == %@ AND type == %@", graphID.rawValue.uuidString, GraphAttachmentPayload.graphType)]
        if let ownerID { predicates.append(NSPredicate(format: "geAttachmentOwner == %@", ownerID.rawValue.uuidString)) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        var seen = Set<GraphNodeID>()
        return try context.fetch(request).map { row in
            guard let bytes = row[metadataKey] as? Data else { throw GraphAttachmentError.invalidMetadata }
            let metadata = try GraphAttachmentPayload.decodeMetadata(bytes)
            guard metadata.id.graphID == graphID, row[GraphNativeIdentityColumns.nodeAttribute] as? String == metadata.id.rawValue.uuidString,
                  row[ownerKey] as? String == metadata.ownerID.rawValue.uuidString,
                  row[propertyKey] as? String == metadata.propertyKey.map(GraphNativePropertyStorage.physicalKey),
                  seen.insert(metadata.id).inserted else { throw GraphAttachmentError.invalidMetadata }
            return metadata
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    static func values(_ context: NSManagedObjectContext, ownerID: GraphNodeID, charge: ((Int) throws -> Void)? = nil) throws -> [String: GraphAttachmentValue] {
        guard enabled(context) else { return [:] }
        let request = NSFetchRequest<ManagedEntity>(entityName: ModelIdentifier.entityName)
        request.predicate = NSPredicate(format: "ge2GraphID == %@ AND geAttachmentOwner == %@ AND geAttachmentKey != nil",
            ownerID.graphID.rawValue.uuidString, ownerID.rawValue.uuidString)
        var values: [String: GraphAttachmentValue] = [:]
        for row in try context.fetch(request) {
            guard row.type == GraphAttachmentPayload.graphType,
                  let rawID = row.value(forKey: GraphNativeIdentityColumns.nodeAttribute) as? String,
                  let uuid = UUID(uuidString: rawID) else { throw GraphAttachmentError.invalidMetadata }
            let node = Entity(managedNode: row), id = GraphNodeID(graphID: ownerID.graphID, rawValue: uuid)
            let metadata = try metadata(node, id: id)
            guard let key = metadata.propertyKey, values[key] == nil else { throw GraphAttachmentError.invalidMetadata }
            try charge?(key.utf8.count)
            try charge?(metadata.byteCount)
            let content = try read(node, id: id)
            values[key] = try GraphAttachmentValue(data: content.data, codec: metadata.codec ?? "GraphEvo.raw", version: metadata.codecVersion ?? 1)
        }
        return values
    }

    static func write(_ content: GraphAttachmentContent, to node: Node, legacy: Bool = false) throws {
        if node.node.entity.attributesByName[metadataKey] == nil {
            let values = legacy ? [GraphAttachmentPayload.contentKey: try GraphAttachmentPayload.legacyEnvelopeBytes(content)] : [GraphAttachmentPayload.metadataKey: try GraphAttachmentPayload.metadataBytes(content.metadata, version: 2), GraphAttachmentPayload.contentKey: content.data]
            if GraphNativePropertyStorage.enabled(node.node.managedObjectContext!) {
                for (key, data) in values {
                    try GraphNativePropertyStorage.write(.init(kind: .data, encoding: 0, field: "ge2Bytes", value: data), key: key, to: node)
                }
            } else {
                for (key, data) in values { node[dynamicMember: key] = try GraphLegacyValueCodec.encode(.data(data)) }
                node[dynamicMember: GraphTypedStoreAdapter.formatsKey] = values.keys.sorted()
            }
            return
        }
        try write(content, to: node.node)
    }

    static func write(_ content: GraphAttachmentContent, to node: NSManagedObject) throws {
        let metadata = content.metadata
        let bytes = try GraphAttachmentPayload.metadataBytes(metadata)
        node.setValue(metadata.ownerID.rawValue.uuidString, forKey: ownerKey)
        node.setValue(metadata.propertyKey.map(GraphNativePropertyStorage.physicalKey), forKey: propertyKey)
        node.setValue(bytes, forKey: metadataKey)
        // Detach Core Data external-data references before changing another row/store.
        node.setValue(content.data.withUnsafeBytes { Data($0) }, forKey: contentKey)
    }
}
