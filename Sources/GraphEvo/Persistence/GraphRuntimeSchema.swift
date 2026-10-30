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

    static let nativeModelIdentifier = "GraphEvo.v2.schema.2"

    /// A fresh S02 model with a distinct physical identity from historical laboratories.
    static func makeNativeModel() -> NSManagedObjectModel {
        let model = GraphNativeIdentityColumns.makeModel(indexed: true)
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

}
