import Foundation
import os

/// Native setup progress is distinct from graph import, record mappings and account authorization.
package struct StoreCloudSetup: Sendable {
    package let configured: Bool
    package let storeCount: Int
    package let readyStoreCount: Int
    package let latestFailureDomain: String?
    package let latestFailureCode: Int?
}

/// Notifications update state synchronously, avoiding reordering through unstructured actor tasks.
final class StoreCloudSetupTracker: Sendable {
    private struct State: Sendable {
        var ready = Set<String>()
        var failure: (String, Int)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ identifier: String, success: Bool, failure: (String, Int)?) {
        state.withLock { state in
            if success { state.ready.insert(identifier) }
            else { state.ready.remove(identifier); state.failure = failure }
        }
    }

    func snapshot(configured: Bool, identifiers: [String]) -> StoreCloudSetup {
        state.withLock { state in
            StoreCloudSetup(configured: configured, storeCount: identifiers.count,
                readyStoreCount: identifiers.filter { state.ready.contains($0) }.count,
                latestFailureDomain: state.failure?.0, latestFailureCode: state.failure?.1)
        }
    }
}
