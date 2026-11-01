import Foundation

// The domain model deliberately has no dependency on GraphEvo or a graph identity.
struct Profile: Sendable {
    let id: UUID
    let displayName: String
}
