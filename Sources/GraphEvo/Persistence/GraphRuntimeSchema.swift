import CoreData
import GraphEvoRuntime

/// The current graph schema supplied to the v2 owner without retaining a shared native model.
/// Only value hashes and the factory cross the runtime boundary.
package enum GraphRuntimeSchema {
    package static let current = StoreSchema(
        identifier: "GraphEvo.current",
        entityVersionHashes: Model.makeModel().entityVersionHashesByName
    ) {
        GraphValueTransformer.register()
        return Model.makeModel()
    }

    static let nativeModelIdentifier = "GraphEvo.v2.schema.3"

    /// S03 preserves the six native graph/node identity values in deletion history.
    static func makeNativeModel() -> NSManagedObjectModel {
        let model = GraphNativeIdentityColumns.makeModel(indexed: true, preservesIdentityOnDeletion: true)
        model.versionIdentifiers = [nativeModelIdentifier]
        return model
    }

    package static let nativeIdentity = StoreSchema(
        identifier: nativeModelIdentifier,
        entityVersionHashes: makeNativeModel().entityVersionHashesByName,
        requiredModelVersionIdentifier: nativeModelIdentifier
    ) {
        GraphValueTransformer.register()
        return makeNativeModel()
    }

    /// S04 is selected only by the custom-sync coordinator; historical public factories retain S03.
    package static let typedProperties = StoreSchema(
        identifier: GraphNativePropertyStorage.identifier,
        entityVersionHashes: GraphNativePropertyStorage.makeModel().entityVersionHashesByName,
        requiredModelVersionIdentifier: GraphNativePropertyStorage.identifier
    ) {
        GraphValueTransformer.register()
        return GraphNativePropertyStorage.makeModel()
    }

}
