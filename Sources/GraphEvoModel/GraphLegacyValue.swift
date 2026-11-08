import Foundation

/// An application-owned encoded payload; unknown codecs retain their bytes.
package struct GraphLegacyEncodedValue: Sendable, Equatable {
    package let codec: String
    package let version: UInt
    package let data: Data

    package init(codec: String, version: UInt, data: Data) throws {
        guard !codec.isEmpty, version > 0 else { throw GraphModelError.invalidRecord("Invalid codec identity.") }
        self.codec = codec
        self.version = version
        self.data = data
    }
}

/// Detached property values. Containers and encoded payloads are not implicitly queryable.
package indirect enum GraphLegacyValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)
    case decimal(Decimal)
    case string(String)
    case data(Data)
    case date(Date)
    case url(URL)
    case uuid(UUID)
    case array([GraphLegacyValue])
    case object([String: GraphLegacyValue])
    case encoded(GraphLegacyEncodedValue)
}


extension GraphLegacyValue {
    package init(_ value: GraphValue) {
        switch value {
        case .null: self = .null
        case .boolean(let v): self = .boolean(v)
        case .integer(let v): self = .integer(v)
        case .unsignedInteger(let v): self = .unsignedInteger(v)
        case .floatingPoint(let v): self = .floatingPoint(v)
        case .decimal(let v): self = .decimal(v)
        case .string(let v): self = .string(v)
        case .date(let v): self = .date(v)
        case .url(let v): self = .url(v)
        case .uuid(let v): self = .uuid(v)
        case .array(let v): self = .array(v.map(Self.init))
        case .object(let v): self = .object(v.mapValues(Self.init))
        }
    }

    package func property() throws -> GraphValue {
        switch self {
        case .null: return .null
        case .boolean(let v): return .boolean(v)
        case .integer(let v): return .integer(v)
        case .unsignedInteger(let v): return .unsignedInteger(v)
        case .floatingPoint(let v): return .floatingPoint(v)
        case .decimal(let v): return .decimal(v)
        case .string(let v): return .string(v)
        case .date(let v): return .date(v)
        case .url(let v): return .url(v)
        case .uuid(let v): return .uuid(v)
        case .array(let v): return .array(try v.map { try $0.property() })
        case .object(let v): return .object(try v.mapValues { try $0.property() })
        case .data, .encoded: throw GraphModelError.invalidValue
        }
    }
}
