//
//  NodeTypes.swift
//  GraphEvo
//
//  Shared public and internal type metadata for Graph nodes.
//

import CoreData

public enum NodeClass: Int {
    case entity = 1
    case relationship = 2
    case action = 3

    init?(nodeType: Node.Type) {
        switch nodeType {
        case is Entity.Type: self = .entity
        case is Relationship.Type: self = .relationship
        case is Action.Type: self = .action
        default: return nil
        }
    }

    var identifier: String {
        switch self {
        case .entity: return ModelIdentifier.entityName
        case .relationship: return ModelIdentifier.relationshipName
        case .action: return ModelIdentifier.actionName
        }
    }
}

extension CodingUserInfoKey {
    /// CodingUserInfoKey for passing Graph instance or name to decoding context.
    public static let graph = CodingUserInfoKey(rawValue: "graph")!
}
