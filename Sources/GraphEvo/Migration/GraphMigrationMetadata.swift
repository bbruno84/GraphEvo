import Foundation

/// Identifies the local ledger value that changed; the application owns its type.
public struct GraphMigrationMetadataChange: Sendable {
    public let storeScope: String
    public let migrationID: String
    public let version: Int
    public let key: String
}

public extension Notification.Name {
    /// Posted on the main queue after a changed write/removal. The object is a
    /// GraphMigrationMetadataChange. Read the value through the metadata API.
    static let graphMigrationMetadataDidChange = Notification.Name("GraphEvo.migration.metadataDidChange")
}

/// Opaque compatibility storage for an early prerelease JSON extension field.
/// No application payload type or meaning is interpreted here.
enum GraphMigrationMetadataJSON: Codable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
