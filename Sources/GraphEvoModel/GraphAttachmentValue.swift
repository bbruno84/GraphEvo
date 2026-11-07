import Foundation

/// Detached binary content. Codable values use GraphEvo's fixed JSON codec.
/// Construction does not grant write admission; the limit applies when inserting or replacing content.
public struct GraphAttachmentValue: Sendable, Equatable {
    public let data: Data
    public let codec: String
    public let version: UInt
    public static let maximumByteCount = 2 * 1024 * 1024

    public init(data: Data) {
        self.data = data
        codec = "GraphEvo.raw"
        version = 1
    }

    public init<Value: Encodable & Sendable>(codable value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        data = try encoder.encode(value)
        codec = "GraphEvo.codable.json"
        version = 1
    }

    package init(data: Data, codec: String, version: UInt) throws {
        guard !codec.isEmpty, version > 0 else { throw GraphAttachmentError.invalidMetadata }
        self.data = data; self.codec = codec; self.version = version
    }

    public func decoded<Value: Decodable & Sendable>(as type: Value.Type = Value.self) throws -> Value {
        guard codec == "GraphEvo.codable.json", version == 1 else { throw GraphAttachmentError.unsupportedVersion }
        return try JSONDecoder().decode(type, from: data)
    }

    package func validateWrite() throws {
        guard data.count <= Self.maximumByteCount else {
            throw GraphAttachmentError.limitExceeded(maxBytes: Self.maximumByteCount)
        }
    }
}

public enum GraphAttachmentChange: Sendable, Equatable {
    case set(GraphAttachmentValue)
    case remove
}
