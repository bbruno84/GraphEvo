import Foundation
import GraphEvoStore

/// Internal opt-in for controlled fresh native-column private/shared acceptance.
/// Public mirrored opens keep the current schema until independent replica checks pass.
enum GraphNativeIdentityPairedLaboratory {
    static func open(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                     containerIdentifier: String) async throws -> GraphDatabase {
        try await GraphDatabase.open(configuration: .init(location: .sqlite(privateURL),
            cloudKitContainerIdentifier: containerIdentifier, sharedStoreURL: sharedURL),
            schema: GraphRuntimeSchema.nativeIdentity,
            adapter: GraphNativeIdentityDatabaseAdapter.makeDatabase(allowsMirroredPair: true))
    }

    static func validate(_ database: GraphDatabase, graphID: GraphID) async throws -> Int {
        try await database.contextRead {
            try GraphNativeIdentityDatabaseAdapter.validate($0, graphID: graphID, allowsMirroredPair: true)
        }
    }
}
