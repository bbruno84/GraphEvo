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
}
