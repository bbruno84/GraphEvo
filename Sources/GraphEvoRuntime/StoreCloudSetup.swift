import Foundation

/// Native setup progress is distinct from graph import, record mappings and account authorization.
package struct StoreCloudSetup: Sendable {
    package let configured: Bool
    package let storeCount: Int
    package let readyStoreCount: Int
    package let latestFailureDomain: String?
    package let latestFailureCode: Int?
}
