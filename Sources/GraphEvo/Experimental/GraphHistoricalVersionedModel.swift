import CoreData

/// Exact historical S01/M2a shape, retained only for experiment recovery and refusal tests.
/// Public native opening selects the separate identity-only S02 factory.
enum GraphHistoricalVersionedModel {
    static let versionAttribute = "ge2DataVersion"

    static func makeModel() -> NSManagedObjectModel {
        let model = GraphNativeIdentityColumns.makeModel(indexed: true)
        for name in [ModelIdentifier.entityName, ModelIdentifier.relationshipName, ModelIdentifier.actionName] {
            let attribute = NSAttributeDescription()
            attribute.name = versionAttribute
            attribute.attributeType = .integer64AttributeType
            attribute.isOptional = true
            model.entitiesByName[name]!.properties.append(attribute)
        }
        return model
    }
}
