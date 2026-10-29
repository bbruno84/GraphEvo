import Foundation
import GraphEvoStore

/// Historical laboratory compatibility wrapper; new consumers use the public schema overloads.
enum GraphNativeIdentityPairedLaboratory {
    static func open(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                     containerIdentifier: String) async throws -> GraphDatabase {
        try await GraphDatabase.openMirrored(privateStoreAt: privateURL, sharedStoreAt: sharedURL,
                                             containerIdentifier: containerIdentifier, schema: .nativeIdentity)
    }

    static func validate(_ database: GraphDatabase, graphID: GraphID) async throws -> Int {
        try await database.validateIntegrity(of: graphID)
    }
}
