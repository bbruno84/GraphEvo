import Foundation

// This file must remain independent of GraphEvo imports and graph-specific stored identity.
struct FoundationPerson: Sendable, Equatable {
    let id: UUID
    let name: String
}
