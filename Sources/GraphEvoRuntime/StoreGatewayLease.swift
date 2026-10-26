import Foundation
import os

/// Excludes independent legacy and v2 coordinators before native store access.
/// The lease follows the native coordinator, not an individual facade.
package final class StoreGatewayLease: Sendable {
    private struct Claim: Sendable {
        let owner: UUID
        var tokens: Set<UUID>
    }
    private static let claims = OSAllocatedUnfairLock(initialState: [StoreKey: Claim]())
    private static let legacyOwner = UUID()
    private let key: StoreKey
    private let token: UUID

    private init(key: StoreKey, token: UUID) { self.key = key; self.token = token }

    package static func legacy(at url: URL) throws -> StoreGatewayLease {
        try acquire(.init(location: .sqlite(url)), owner: legacyOwner)
    }

    static func acquire(_ configuration: StoreConfiguration, owner: UUID) throws -> StoreGatewayLease {
        let resolved = try ResolvedStore(configuration)
        let token = UUID()
        try claims.withLock { entries in
            if var entry = entries[resolved.key] {
                guard entry.owner == owner else { throw StoreRuntimeError.configurationConflict(resolved.url) }
                entry.tokens.insert(token)
                entries[resolved.key] = entry
            } else { entries[resolved.key] = Claim(owner: owner, tokens: [token]) }
        }
        return StoreGatewayLease(key: resolved.key, token: token)
    }

    package func release() {
        Self.claims.withLock { entries in
            guard var entry = entries[key], entry.tokens.remove(token) != nil else { return }
            if entry.tokens.isEmpty { entries.removeValue(forKey: key) }
            else { entries[key] = entry }
        }
    }

    deinit { release() }
}
