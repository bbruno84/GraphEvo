import Foundation

public enum GraphPropertyChange: Sendable, Equatable {
    case set(GraphValue)
    case remove
}

/// Explicit edits preserve every property the application did not name.
/// Apply to current local state inside a transaction; no stale-write policy is implied.
public struct GraphRecordPatch: Sendable, Equatable {
    public let id: GraphNodeID
    public let properties: [String: GraphPropertyChange]
    public let addingTags: Set<String>
    public let removingTags: Set<String>
    public let addingGroups: Set<String>
    public let removingGroups: Set<String>
    public let endpoints: GraphEndpoints?

    public init(id: GraphNodeID, properties: [String: GraphPropertyChange] = [:],
                addingTags: Set<String> = [], removingTags: Set<String> = [],
                addingGroups: Set<String> = [], removingGroups: Set<String> = [],
                endpoints: GraphEndpoints? = nil) throws {
        guard addingTags.isDisjoint(with: removingTags), addingGroups.isDisjoint(with: removingGroups),
              properties.keys.allSatisfy({ !$0.isEmpty }) else { throw GraphModelError.conflictingPatch }
        if let endpoints, !endpoints.references.allSatisfy({ $0.graphID == id.graphID }) {
            throw GraphModelError.crossGraphReference
        }
        self.id = id
        self.properties = properties
        self.addingTags = addingTags
        self.removingTags = removingTags
        self.addingGroups = addingGroups
        self.removingGroups = removingGroups
        self.endpoints = endpoints
    }

    public func applying(to record: GraphRecord) throws -> GraphRecord {
        guard id == record.id else { throw GraphModelError.identityMismatch }
        if let endpoints, endpoints.kind != record.endpoints.kind { throw GraphModelError.unexpectedKind }
        var values = record.properties
        for (key, change) in properties {
            switch change {
            case .set(let value): values[key] = value
            case .remove: values.removeValue(forKey: key)
            }
        }
        return try GraphRecord(id: id, type: record.type, endpoints: endpoints ?? record.endpoints,
                               properties: values, tags: record.tags.subtracting(removingTags).union(addingTags),
                               groups: record.groups.subtracting(removingGroups).union(addingGroups),
                               createdDate: record.createdDate)
    }
}
