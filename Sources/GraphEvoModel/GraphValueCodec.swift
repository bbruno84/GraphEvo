import Foundation

/// Versioned alpha property storage; independent of Codable conformance on public values.
package enum GraphValueCodec {
    private indirect enum URLValue: Codable {
        case unbased(String)
        case based(String, URLValue)
        init(_ url: URL, depth: Int = 0) throws {
            guard depth < 32 else { throw GraphModelError.invalidRecord("URL base chain exceeds the codec limit.") }
            if let base = url.baseURL { self = .based(url.relativeString, try URLValue(base, depth: depth + 1)) }
            else { self = .unbased(url.relativeString) }
        }
        func url(depth: Int = 0) throws -> URL {
            guard depth < 32 else { throw GraphModelError.invalidRecord("URL base chain exceeds the codec limit.") }
            let result: URL?
            switch self {
            case .unbased(let string): result = URL(string: string)
            case .based(let string, let base): result = URL(string: string, relativeTo: try base.url(depth: depth + 1))
            }
            guard let result else { throw GraphModelError.invalidRecord("Invalid URL components.") }
            return result
        }
    }
    private struct Envelope: Codable { let version: Int; let value: PayloadV1 }
    private indirect enum PayloadV1: Codable {
        case null, boolean(Bool), integer(Int64), unsignedInteger(UInt64), floatingPoint(Double)
        case decimal(Decimal), string(String), date(Date), url(URL), uuid(UUID)
        case array([PayloadV1]), object([String: PayloadV1])
        case urlComponents(URLValue)

        init(_ value: GraphValue) throws {
            switch value {
            case .null: self = .null
            case .boolean(let v): self = .boolean(v)
            case .integer(let v): self = .integer(v)
            case .unsignedInteger(let v): self = .unsignedInteger(v)
            case .floatingPoint(let v): self = .floatingPoint(v)
            case .decimal(let v): self = .decimal(v)
            case .string(let v): self = .string(v)
            case .date(let v): self = .date(v)
            case .url(let v): self = v.baseURL == nil ? .url(v) : .urlComponents(try URLValue(v))
            case .uuid(let v): self = .uuid(v)
            case .array(let v): self = .array(try v.map(Self.init))
            case .object(let v): self = .object(try v.mapValues(Self.init))
            }
        }
        var requiresVersionTwo: Bool {
            switch self {
            case .urlComponents: return true
            case .array(let values): return values.contains { $0.requiresVersionTwo }
            case .object(let values): return values.values.contains { $0.requiresVersionTwo }
            default: return false
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
            case .date(let v): return .date(v)
            case .url(let v): return .url(v)
            case .urlComponents(let v): return .url(try v.url())
            case .uuid(let v): return .uuid(v)
            case .array(let v): return .array(try v.map { try $0.value() })
            case .object(let v): return .object(try v.mapValues { try $0.value() })
            }
        }
    }

    package static func encode(_ value: GraphValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try PayloadV1(value)
        return try encoder.encode(Envelope(version: 3, value: payload))
    }

    package static func decode(_ data: Data) throws -> GraphValue {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 3 else { throw GraphModelError.invalidRecord("Unsupported property envelope version.") }
        return try envelope.value.value()
    }
}
