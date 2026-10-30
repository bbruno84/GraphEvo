import CoreData
import Foundation
import GraphEvo

/// Model construction only; this process never opens a store or uses Graph data APIs.
@main struct ModelExporter {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let model = Model.create().copy() as! NSManagedObjectModel
        for name in ["ManagedEntity", "ManagedRelationship", "ManagedAction"] {
            let entity = model.entitiesByName[name]!
            for key in ["ge2GraphID", "ge2NodeID"] {
                let attribute = NSAttributeDescription()
                attribute.name = key; attribute.attributeType = .stringAttributeType; attribute.isOptional = true
                entity.properties.append(attribute)
            }
            entity.indexes.append(NSFetchIndexDescription(name: name + "_ge2_identity", elements: ["ge2GraphID", "ge2NodeID"].map {
                NSFetchIndexElementDescription(property: entity.attributesByName[$0]!, collationType: .binary)
            }))
        }
        model.versionIdentifiers = ["GraphEvo.v2.schema.2"]
        let hashes = model.entityVersionHashesByName
        // Generic classes prevent the independent reader from loading Graph managed subclasses.
        for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
        guard model.entityVersionHashesByName == hashes else { throw CocoaError(.persistentStoreIncompatibleVersionHash) }
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: true)
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
        print("Exported twelve-entity S02 model with generic Core Data classes and unchanged entity hashes.")
    }
}
