import Foundation

/// Versioned alpha property storage; independent of Codable conformance on public values.
package enum GraphValueCodec {
    private struct Envelope: Codable { let version: Int; let value: PayloadV1 }
    private indirect enum PayloadV1: Codable {
        case null, boolean(Bool), integer(Int64), unsignedInteger(UInt64), floatingPoint(Double)
        case decimal(Decimal), string(String), data(Data), date(Date), url(URL), uuid(UUID)
        case array([PayloadV1]), object([String: PayloadV1])
        case encoded(codec: String, version: UInt, data: Data)

        init(_ value: GraphValue) {
            switch value {
            case .null: self = .null
            case .boolean(let v): self = .boolean(v)
            case .integer(let v): self = .integer(v)
            case .unsignedInteger(let v): self = .unsignedInteger(v)
            case .floatingPoint(let v): self = .floatingPoint(v)
            case .decimal(let v): self = .decimal(v)
            case .string(let v): self = .string(v)
            case .data(let v): self = .data(v)
            case .date(let v): self = .date(v)
            case .url(let v): self = .url(v)
            case .uuid(let v): self = .uuid(v)
            case .array(let v): self = .array(v.map(Self.init))
            case .object(let v): self = .object(v.mapValues(Self.init))
            case .encoded(let v): self = .encoded(codec: v.codec, version: v.version, data: v.data)
            }
        }
        func value() throws -> GraphValue {
            switch self {
            case .null: return .null
            case .boolean(let v): return .boolean(v)
            case .integer(let v): return .integer(v)
            case .unsignedInteger(let v): return .unsignedInteger(v)
            case .floatingPoint(let v): return .floatingPoint(v)
            case .decimal(let v): return .decimal(v)
            case .string(let v): return .string(v)
            case .data(let v): return .data(v)
            case .date(let v): return .date(v)
            case .url(let v): return .url(v)
            case .uuid(let v): return .uuid(v)
            case .array(let v): return .array(try v.map { try $0.value() })
            case .object(let v): return .object(try v.mapValues { try $0.value() })
            case .encoded(let codec, let version, let data):
                return .encoded(try GraphEncodedValue(codec: codec, version: version, data: data))
            }
        }
    }

    package static func encode(_ value: GraphValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(version: 1, value: PayloadV1(value)))
    }

    package static func decode(_ data: Data) throws -> GraphValue {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw GraphModelError.invalidRecord("Unsupported property envelope version.") }
        return try envelope.value.value()
    }
}
