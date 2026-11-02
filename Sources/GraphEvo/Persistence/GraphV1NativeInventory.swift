import CoreData
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Inspects the retained receipt format without retaining the graph's property payload.
enum GraphV1NativeInventory {
    static let nodeEntities = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]

    static func facade(_ object: NSManagedObject) throws -> Node {
        guard let node = object as? ManagedNode else { throw GraphV1ConversionError.unsupportedSource }
        switch object.entity.name {
        case ModelIdentifier.entityName: return Entity(managedNode: node)
        case ModelIdentifier.relationshipName: return Relationship(managedNode: node)
        case ModelIdentifier.actionName: return Action(managedNode: node)
        default: throw GraphV1ConversionError.unsupportedSource
        }
    }

    static func inspect(_ context: NSManagedObjectContext, id: GraphID) throws -> GraphV1Snapshot {
        try GraphValueDecodingDiagnostics.checking {
            guard let coordinator = context.persistentStoreCoordinator, coordinator.persistentStores.count == 1,
                  let store = coordinator.persistentStores.first, store.isReadOnly,
                  !(context.userInfo[StoreNativeContext.containerKey] is NSPersistentCloudKitContainer),
                  let storeID = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
                  coordinator.metadata(for: store)[StoreNativeContext.workspaceKey] == nil,
                  coordinator.metadata(for: store)[StoreNativeContext.historySyncGraphKey] == nil else {
                throw GraphV1ConversionError.unsupportedSource
            }
            var rows = 0
            for entity in coordinator.managedObjectModel.entities {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity.name!)
                rows += try context.count(for: request)
                guard rows <= 100_000 else { throw GraphV1ConversionError.limitExceeded }
                if entity.relationshipsByName["node"] != nil {
                    request.predicate = NSPredicate(format: "node == nil OR name == nil OR name == ''")
                    guard try context.count(for: request) == 0 else { throw GraphV1ConversionError.unsupportedSource }
                }
            }
            var objects = [NSManagedObjectID]()
            for name in nodeEntities {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: name)
                request.resultType = .managedObjectIDResultType
                objects += try context.fetch(request)
                guard objects.count <= 10_000 else { throw GraphV1ConversionError.limitExceeded }
            }
            guard rows + 5 * objects.count + 128 <= GraphSyncLimits().maximumChanges else {
                throw GraphV1ConversionError.limitExceeded
            }
            var mapping = [String: GraphNodeID](), ordered = [(String, NSManagedObjectID)]()
            for objectID in objects {
                try StoreNativeContext.cancellationCheck(in: context)()
                let node = try facade(context.existingObject(with: objectID)), legacy = node.id
                guard mapping.updateValue(.init(graphID: id), forKey: legacy) == nil else { throw GraphV1ConversionError.unsupportedSource }
                ordered.append((legacy, objectID))
                context.reset()
            }
            let reverse = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
            var digest = SHA256()
            for (legacy, objectID) in ordered.sorted(by: { $0.0 < $1.0 }) {
                try autoreleasepool {
                    try StoreNativeContext.cancellationCheck(in: context)()
                    guard GraphStructuralValidator.validate([objectID], from: context, legacyReadOnly: true).allSatisfy(\.isValid) else {
                        throw GraphV1ConversionError.unsupportedSource
                    }
                    let node = try facade(context.existingObject(with: objectID))
                    guard let type = node.runtimeTypeIfPresent, !type.isEmpty,
                          !type.hasPrefix(GraphTypedStoreAdapter.prefix), type != GraphAttachmentPayload.graphType else {
                        throw GraphV1ConversionError.unsupportedSource
                    }
                    func reference(_ node: Entity) throws -> GraphNodeID {
                        guard let value = mapping[node.id] else { throw GraphV1ConversionError.unsupportedSource }; return value
                    }
                    let endpoints: GraphEndpoints
                    if let edge = node as? Relationship { endpoints = .relationship(subject: try edge.subject.map(reference), object: try edge.object.map(reference)) }
                    else if let action = node as? Action { endpoints = .action(subjects: Set(try action.subjects.map(reference)), objects: Set(try action.objects.map(reference))) }
                    else { endpoints = .entity }
                    var properties = [String: GraphValue]()
                    for (key, value) in node.properties {
                        guard !key.hasPrefix(GraphTypedStoreAdapter.prefix) else { throw GraphV1ConversionError.unsupportedSource }
                        properties[key] = try GraphV1NativeConversion.valueFromLegacy(value, key: key, canonical: true)
                    }
                    let record = try GraphRecord(id: mapping[legacy]!, type: type, endpoints: endpoints, properties: properties,
                        tags: Set(node.tags), groups: Set(node.groups), createdDate: node.createdDateIfPresent)
                    try append(record, legacy: legacy, reverse: reverse,
                               versions: node.runtimePropertyVersions, digest: &digest)
                }
                context.reset()
            }
            guard try JSONEncoder().encode(mapping).count <= 3 * 1024 * 1024 else { throw GraphV1ConversionError.limitExceeded }
            return .init(storeID: storeID, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined(), records: [], nodeIDs: mapping)
        }
    }

    static func append(_ record: GraphRecord, legacy: String, reverse: [GraphNodeID: String], versions: [String: Int], digest: inout SHA256) throws {
        let kind: String, subjects: [GraphNodeID], objects: [GraphNodeID]
        switch record.endpoints {
        case .entity: kind = "entity"; subjects = []; objects = []
        case .relationship(let subject, let object): kind = "relationship"; subjects = subject.map { [$0] } ?? []; objects = object.map { [$0] } ?? []
        case .action(let left, let right): kind = "action"; subjects = Array(left); objects = Array(right)
        }
        func key(_ id: GraphNodeID) throws -> String {
            guard let value = reverse[id] else { throw GraphV1ConversionError.unsupportedSource }; return value
        }
        let canonical = GraphV1NativeConversion.Canonical(legacyID: legacy, type: record.type, kind: kind,
            subjects: try subjects.map(key).sorted(), objects: try objects.map(key).sorted(),
            properties: try record.properties.mapValues { try GraphValueCodec.encode($0) }, propertyVersions: versions,
            tags: record.tags.sorted(), groups: record.groups.sorted(), createdDate: record.createdDate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest.update(data: try encoder.encode(canonical))
    }
}
