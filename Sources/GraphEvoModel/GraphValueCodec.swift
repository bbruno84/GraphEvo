import Foundation

/// Versioned alpha property storage; independent of Codable conformance on public values.
package enum GraphValueCodec {
    // Distinct from legacy JSON. A declared length rejects truncated/extended binary payloads.
    private static let binaryMagic = Data([0x47, 0x45, 0x56, 0x4f, 0, 0x44, 0x41, 0x54, 0x41])
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
        case decimal(Decimal), string(String), data(Data), date(Date), url(URL), uuid(UUID)
        case array([PayloadV1]), object([String: PayloadV1])
        case urlComponents(URLValue)
        case encoded(codec: String, version: UInt, data: Data)

        init(_ value: GraphValue) throws {
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
            case .url(let v): self = v.baseURL == nil ? .url(v) : .urlComponents(try URLValue(v))
            case .uuid(let v): self = .uuid(v)
            case .array(let v): self = .array(try v.map(Self.init))
            case .object(let v): self = .object(try v.mapValues(Self.init))
            case .encoded(let v): self = .encoded(codec: v.codec, version: v.version, data: v.data)
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
            case .data(let v): return .data(v)
            case .date(let v): return .date(v)
            case .url(let v): return .url(v)
            case .urlComponents(let v): return .url(try v.url())
            case .uuid(let v): return .uuid(v)
            case .array(let v): return .array(try v.map { try $0.value() })
            case .object(let v): return .object(try v.mapValues { try $0.value() })
            case .encoded(let codec, let version, let data):
                return .encoded(try GraphEncodedValue(codec: codec, version: version, data: data))
            }
        }
    }

    package static func encode(_ value: GraphValue) throws -> Data {
        if case .data(let bytes) = value {
            var result = binaryMagic
            result.append(1)
            let count = UInt64(bytes.count)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: count >> shift)) }
            result.append(bytes)
            return result
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try PayloadV1(value)
        return try encoder.encode(Envelope(version: payload.requiresVersionTwo ? 2 : 1, value: payload))
    }

    package static func decode(_ data: Data) throws -> GraphValue {
        if data.starts(with: binaryMagic) {
            let header = binaryMagic.count + 9
            guard data.count >= header, data[data.startIndex + binaryMagic.count] == 1 else {
                throw GraphModelError.invalidRecord("Unsupported or incomplete binary property envelope.")
            }
            let length = data.dropFirst(binaryMagic.count + 1).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length == UInt64(data.count - header) else { throw GraphModelError.invalidRecord("Invalid binary property length.") }
            return .data(Data(data.dropFirst(header)))
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard (envelope.version == 1 && !envelope.value.requiresVersionTwo) || envelope.version == 2 else { throw GraphModelError.invalidRecord("Unsupported property envelope version.") }
        return try envelope.value.value()
    }
}
