import CoreFoundation
import Foundation

/// Candidate-schema adapter used inside an existing scoped Graph operation.
/// Identity mapping is supplied explicitly; this does not derive durable IDs from local URIs.
package enum GraphRecordMapper {
    package static func snapshot(
        _ node: Node, id: GraphNodeID, excludingRoot root: Entity? = nil,
        referenceID: (Entity) throws -> GraphNodeID
    ) throws -> GraphRecord {
        try GraphValueDecodingDiagnostics.checking {
            let endpoints: GraphEndpoints
            switch node {
            case let relationship as Relationship:
                let subject = relationship.subject.flatMap { candidate in
                    root.map { candidate.sharesBackingObject(with: $0) } == true ? nil : candidate
                }
                endpoints = .relationship(subject: try subject.map(referenceID),
                                          object: try relationship.object.map(referenceID))
            case let action as Action:
                let subjects = action.subjects.filter { candidate in
                    root.map { candidate.sharesBackingObject(with: $0) } != true
                }
                endpoints = .action(subjects: Set(try subjects.map(referenceID)),
                                    objects: Set(try action.objects.map(referenceID)))
            case _ as Entity:
                endpoints = .entity
            default:
                throw GraphModelError.unexpectedKind
            }
            var properties: [String: GraphValue] = [:]
            for (key, value) in node.properties { properties[key] = try detached(value, key: key) }
            return try GraphRecord(id: id, type: node.type, endpoints: endpoints, properties: properties,
                                   tags: Set(node.tags), groups: Set(node.groups), createdDate: node.createdDateIfPresent)
        }
    }

    /// Applies property/tag/group edits only, preserving all untouched native rows.
    /// Structural endpoint writes need the future identity resolver and membership scope.
    package static func apply(_ patch: GraphRecordPatch, to node: Node, id: GraphNodeID) throws {
        guard patch.id == id else { throw GraphModelError.identityMismatch }
        guard patch.endpoints == nil else {
            throw GraphModelError.invalidRecord("Endpoint edits require a graph membership resolver.")
        }
        // Convert every changed value before performing the first edit.
        var values: [String: Any] = [:]
        for (key, change) in patch.properties {
            if case .set(let value) = change { values[key] = try native(value, key: key) }
        }
        for (key, change) in patch.properties {
            switch change {
            case .set: node[dynamicMember: key] = values[key]
            case .remove: node[dynamicMember: key] = nil
            }
        }
        node.add(tags: Array(patch.addingTags))
        node.remove(tags: Array(patch.removingTags))
        node.add(to: Array(patch.addingGroups))
        node.remove(from: Array(patch.removingGroups))
    }

    private static func detached(_ value: Any, key: String) throws -> GraphValue {
        switch value {
        case is NSNull: return .null
        case let value as String: return .string(value)
        case let value as NSDecimalNumber: return .decimal(value.decimalValue)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
            switch String(cString: value.objCType) {
            case "f", "d": return .floatingPoint(value.doubleValue)
            case "C", "S", "I", "L", "Q": return .unsignedInteger(value.uint64Value)
            default: return .integer(value.int64Value)
            }
        case let value as Data: return .data(value)
        case let value as Date: return .date(value)
        case let value as URL: return .url(value)
        case let value as [Any]: return .array(try value.map { try detached($0, key: key) })
        case let value as [String: Any]: return .object(try value.mapValues { try detached($0, key: key) })
        default: throw GraphModelError.unsupportedLegacyValue(key)
        }
    }

    private static func native(_ value: GraphValue, key: String) throws -> Any {
        switch value {
        case .boolean(let value): return NSNumber(value: value)
        case .integer(let value): return NSNumber(value: value)
        case .unsignedInteger(let value): return NSNumber(value: value)
        case .floatingPoint(let value): return NSNumber(value: value)
        case .decimal(let value): return NSDecimalNumber(decimal: value)
        case .string(let value): return value
        case .data(let value): return value
        case .date(let value): return value
        case .url(let value): return value
        case .array(let values): return try values.map { try native($0, key: key) }
        case .object(let values): return try values.mapValues { try native($0, key: key) }
        case .null, .uuid, .encoded: throw GraphModelError.unsupportedLegacyValue(key)
        }
    }
}
