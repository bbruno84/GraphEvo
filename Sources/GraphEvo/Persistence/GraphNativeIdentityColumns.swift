import CoreData
import Foundation
import GraphEvoModel

/// Projection maintenance for explicitly selected native-column models only.
/// Historical laboratories select identity-only models explicitly. S01 also stores
/// an optional application version; its presence does not implement data admission.
enum GraphNativeIdentityColumns {
    static let graphAttribute = "ge2GraphID"
    static let nodeAttribute = "ge2NodeID"
    static let dataVersionAttribute = "ge2DataVersion"
    private enum Layout: Hashable { case current, identityOnly, s01 }

    static func makeModel(indexed: Bool, includingDataVersion: Bool) -> NSManagedObjectModel {
        let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]
        let model = Model.makeModel()
        for name in kinds {
            let entity = model.entitiesByName[name]!
            for key in [graphAttribute, nodeAttribute] {
                let attribute = NSAttributeDescription()
                attribute.name = key; attribute.attributeType = .stringAttributeType; attribute.isOptional = true
                entity.properties.append(attribute)
            }
            if includingDataVersion {
                let attribute = NSAttributeDescription()
                attribute.name = dataVersionAttribute
                attribute.attributeType = .integer64AttributeType
                attribute.isOptional = true
                entity.properties.append(attribute)
            }
            if indexed {
                entity.indexes.append(NSFetchIndexDescription(name: name + "_ge2_identity", elements: [graphAttribute, nodeAttribute].map {
                    NSFetchIndexElementDescription(property: entity.attributesByName[$0]!, collationType: .binary)
                }))
            }
        }
        return model
    }

    private static func layout(_ entity: NSEntityDescription) throws -> Layout {
        let graph = entity.attributesByName[graphAttribute], node = entity.attributesByName[nodeAttribute]
        let version = entity.attributesByName[dataVersionAttribute]
        if graph == nil && node == nil {
            guard version == nil else { throw GraphStoreError.unsupportedLayout }
            return .current
        }
        guard let graph, let node, graph.attributeType == .stringAttributeType,
              node.attributeType == .stringAttributeType, graph.isOptional, node.isOptional,
              graph.defaultValue == nil, node.defaultValue == nil, !graph.isTransient, !node.isTransient else {
            throw GraphStoreError.unsupportedLayout
        }
        guard let version else { return .identityOnly }
        guard version.attributeType == .integer64AttributeType, version.isOptional,
              version.defaultValue == nil, !version.isTransient,
              entity.indexes.contains(where: { index in
                  index.name == entity.name! + "_ge2_identity" &&
                  index.elements.compactMap(\.propertyName) == [graphAttribute, nodeAttribute] &&
                  index.elements.allSatisfy { $0.collationType == .binary }
              }) else { throw GraphStoreError.unsupportedLayout }
        return .s01
    }

    /// Preflight before reserving any external shared intent.
    @discardableResult static func validateModel(in context: NSManagedObjectContext) throws -> Bool {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { throw GraphStoreError.unsupportedLayout }
        let states = try [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName].map { name in
            guard let entity = model.entitiesByName[name] else { throw GraphStoreError.unsupportedLayout }
            return try layout(entity)
        }
        guard Set(states).count == 1 else { throw GraphStoreError.unsupportedLayout }
        return states[0] != .current
    }

    static func validate(_ node: Node, graphID: GraphID, nodeID: UUID?) throws {
        guard try layout(node.node.entity) != .current else { return }
        guard node.node.value(forKey: graphAttribute) as? String == graphID.rawValue.uuidString,
              node.node.value(forKey: nodeAttribute) as? String == nodeID?.uuidString else { throw GraphStoreError.corruptIdentity }
    }

    static func stamp(_ node: Node, graphID: GraphID, nodeID: UUID?) throws {
        guard try layout(node.node.entity) != .current else { return }
        guard node.node.isInserted else {
            try validate(node, graphID: graphID, nodeID: nodeID)
            return
        }
        let graph = node.node.value(forKey: graphAttribute) as? String
        let identity = node.node.value(forKey: nodeAttribute) as? String
        guard graph == nil || graph == graphID.rawValue.uuidString,
              identity == nil || identity == nodeID?.uuidString else { throw GraphStoreError.corruptIdentity }
        node.node.setValue(graphID.rawValue.uuidString, forKey: graphAttribute)
        node.node.setValue(nodeID?.uuidString, forKey: nodeAttribute)
    }
}
