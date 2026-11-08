import Foundation

public enum GraphPropertyChange: Sendable, Equatable {
    case set(GraphValue)
    case remove
}

/// Explicit edits preserve every property the application did not name.
/// Apply to current local state inside a transaction; no stale-write policy is implied.
public struct GraphRecordPatch: Sendable, Equatable {
    public let id: GraphNodeID
    package var storedAttachment: GraphAttachmentContent?
    public let attachments: [String: GraphAttachmentChange]
    public let properties: [String: GraphPropertyChange]
    public let addingTags: Set<String>
    public let removingTags: Set<String>
    public let addingGroups: Set<String>
    public let removingGroups: Set<String>
    public let endpoints: GraphEndpoints?

    public init(id: GraphNodeID, properties: [String: GraphPropertyChange] = [:],
                addingTags: Set<String> = [], removingTags: Set<String> = [],
                addingGroups: Set<String> = [], removingGroups: Set<String> = [],
                endpoints: GraphEndpoints? = nil, attachments: [String: GraphAttachmentChange] = [:]) throws {
        guard addingTags.isDisjoint(with: removingTags), addingGroups.isDisjoint(with: removingGroups),
              properties.keys.allSatisfy({ !$0.isEmpty }), attachments.keys.allSatisfy({ !$0.isEmpty }) else { throw GraphModelError.conflictingPatch }
        if let endpoints, !endpoints.references.allSatisfy({ $0.graphID == id.graphID }) {
            throw GraphModelError.crossGraphReference
        }
        self.id = id
        self.attachments = attachments
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
        var bodies = record.attachments
        for (key, change) in attachments {
            switch change {
            case .set(let value): try value.validateWrite(); bodies[key] = value
            case .remove: bodies.removeValue(forKey: key)
            }
        }
        var result = try GraphRecord(id: id, type: record.type, endpoints: endpoints ?? record.endpoints,
                               properties: values, tags: record.tags.subtracting(removingTags).union(addingTags),
                               groups: record.groups.subtracting(removingGroups).union(addingGroups),
                               createdDate: record.createdDate, file: record.file, attachments: bodies)
        result.storedAttachment = storedAttachment ?? record.storedAttachment
        result.legacyAttachment = record.legacyAttachment
        return result
    }
}
