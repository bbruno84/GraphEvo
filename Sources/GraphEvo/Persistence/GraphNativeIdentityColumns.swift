import CoreData
import Foundation
import GraphEvoModel

/// Projection maintenance for explicitly selected native-column models only.
/// Default schemas have neither field; existing rows are validated, never repaired here.
enum GraphNativeIdentityColumns {
    static let graphAttribute = "ge2GraphID"
    static let nodeAttribute = "ge2NodeID"

    static func makeModel(indexed: Bool) -> NSManagedObjectModel {
        let kinds = [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName]
        let model = Model.makeModel()
        for name in kinds {
            let entity = model.entitiesByName[name]!
            for key in [graphAttribute, nodeAttribute] {
                let attribute = NSAttributeDescription()
                attribute.name = key; attribute.attributeType = .stringAttributeType; attribute.isOptional = true
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

    private static func enabled(_ entity: NSEntityDescription) throws -> Bool {
        let graph = entity.attributesByName[graphAttribute], node = entity.attributesByName[nodeAttribute]
        if graph == nil && node == nil { return false }
        guard let graph, let node, graph.attributeType == .stringAttributeType,
              node.attributeType == .stringAttributeType, graph.isOptional, node.isOptional else {
            throw GraphStoreError.unsupportedLayout
        }
        return true
    }

    /// Preflight before reserving any external shared intent.
    @discardableResult static func validateModel(in context: NSManagedObjectContext) throws -> Bool {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { throw GraphStoreError.unsupportedLayout }
        let states = try [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName].map { name in
            guard let entity = model.entitiesByName[name] else { throw GraphStoreError.unsupportedLayout }
            return try enabled(entity)
        }
        guard Set(states).count == 1 else { throw GraphStoreError.unsupportedLayout }
        return states[0]
    }

    static func validate(_ node: Node, graphID: GraphID, nodeID: UUID?) throws {
        guard try enabled(node.node.entity) else { return }
        guard node.node.value(forKey: graphAttribute) as? String == graphID.rawValue.uuidString,
              node.node.value(forKey: nodeAttribute) as? String == nodeID?.uuidString else { throw GraphStoreError.corruptIdentity }
    }

    static func stamp(_ node: Node, graphID: GraphID, nodeID: UUID?) throws {
        guard try enabled(node.node.entity) else { return }
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
