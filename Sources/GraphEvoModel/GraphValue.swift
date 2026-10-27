import Foundation

/// An application-owned encoded payload; unknown codecs retain their bytes.
public struct GraphEncodedValue: Sendable, Equatable {
    public let codec: String
    public let version: UInt
    public let data: Data

    public init(codec: String, version: UInt, data: Data) throws {
        guard !codec.isEmpty, version > 0 else { throw GraphModelError.invalidRecord("Invalid codec identity.") }
        self.codec = codec
        self.version = version
        self.data = data
    }
}

/// Detached property values. Containers and encoded payloads are not implicitly queryable.
public indirect enum GraphValue: Sendable, Equatable {
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
    case array([GraphValue])
    case object([String: GraphValue])
    case encoded(GraphEncodedValue)
}

/// Explicit conversion of a model property to a detached graph value.
public protocol GraphPropertyValue: Sendable {
    var graphValue: GraphValue { get }
    init(graphValue: GraphValue) throws
}

extension String: GraphPropertyValue {
    public var graphValue: GraphValue { .string(self) }
    public init(graphValue: GraphValue) throws {
        guard case .string(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Bool: GraphPropertyValue {
    public var graphValue: GraphValue { .boolean(self) }
    public init(graphValue: GraphValue) throws {
        guard case .boolean(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Int64: GraphPropertyValue {
    public var graphValue: GraphValue { .integer(self) }
    public init(graphValue: GraphValue) throws {
        guard case .integer(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension UInt64: GraphPropertyValue {
    public var graphValue: GraphValue { .unsignedInteger(self) }
    public init(graphValue: GraphValue) throws {
        guard case .unsignedInteger(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Int: GraphPropertyValue {
    public var graphValue: GraphValue { .integer(Int64(self)) }
    public init(graphValue: GraphValue) throws {
        let value = try Int64(graphValue: graphValue)
        guard let result = Int(exactly: value) else { throw GraphModelError.invalidValue }
        self = result
    }
}
extension Double: GraphPropertyValue {
    public var graphValue: GraphValue { .floatingPoint(self) }
    public init(graphValue: GraphValue) throws {
        guard case .floatingPoint(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Decimal: GraphPropertyValue {
    public var graphValue: GraphValue { .decimal(self) }
    public init(graphValue: GraphValue) throws {
        guard case .decimal(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Data: GraphPropertyValue {
    public var graphValue: GraphValue { .data(self) }
    public init(graphValue: GraphValue) throws {
        guard case .data(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Date: GraphPropertyValue {
    public var graphValue: GraphValue { .date(self) }
    public init(graphValue: GraphValue) throws {
        guard case .date(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension URL: GraphPropertyValue {
    public var graphValue: GraphValue { .url(self) }
    public init(graphValue: GraphValue) throws {
        guard case .url(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension UUID: GraphPropertyValue {
    public var graphValue: GraphValue { .uuid(self) }
    public init(graphValue: GraphValue) throws {
        guard case .uuid(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
extension Optional: GraphPropertyValue where Wrapped: GraphPropertyValue {
    public var graphValue: GraphValue { map(\.graphValue) ?? .null }
    public init(graphValue: GraphValue) throws {
        if case .null = graphValue { self = nil }
        else { self = try Wrapped(graphValue: graphValue) }
    }
}
extension Array: GraphPropertyValue where Element: GraphPropertyValue {
    public var graphValue: GraphValue { .array(map(\.graphValue)) }
    public init(graphValue: GraphValue) throws {
        guard case .array(let values) = graphValue else { throw GraphModelError.invalidValue }
        self = try values.map { try Element(graphValue: $0) }
    }
}
extension Dictionary: GraphPropertyValue where Key == String, Value: GraphPropertyValue {
    public var graphValue: GraphValue { .object(mapValues(\.graphValue)) }
    public init(graphValue: GraphValue) throws {
        guard case .object(let values) = graphValue else { throw GraphModelError.invalidValue }
        self = try values.mapValues { try Value(graphValue: $0) }
    }
}

extension GraphValue: GraphPropertyValue {
    public var graphValue: GraphValue { self }
    public init(graphValue: GraphValue) { self = graphValue }
}

extension GraphEncodedValue: GraphPropertyValue {
    public var graphValue: GraphValue { .encoded(self) }
    public init(graphValue: GraphValue) throws {
        guard case .encoded(let value) = graphValue else { throw GraphModelError.invalidValue }
        self = value
    }
}
