import Foundation

// Model-facing widths share the existing logical integer categories and wire format.
private func signedInteger<Value: FixedWidthInteger & SignedInteger>(
    from value: GraphValue, as type: Value.Type
) throws -> Value {
    guard case .integer(let number) = value, let result = Value(exactly: number) else {
        throw GraphModelError.invalidValue
    }
    return result
}

private func unsignedInteger<Value: FixedWidthInteger & UnsignedInteger>(
    from value: GraphValue, as type: Value.Type
) throws -> Value {
    guard case .unsignedInteger(let number) = value, let result = Value(exactly: number) else {
        throw GraphModelError.invalidValue
    }
    return result
}

extension Int8: GraphPropertyValue {
    public var graphValue: GraphValue { .integer(Int64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try signedInteger(from: graphValue, as: Self.self)
    }
}

extension Int16: GraphPropertyValue {
    public var graphValue: GraphValue { .integer(Int64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try signedInteger(from: graphValue, as: Self.self)
    }
}

extension Int32: GraphPropertyValue {
    public var graphValue: GraphValue { .integer(Int64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try signedInteger(from: graphValue, as: Self.self)
    }
}

extension UInt: GraphPropertyValue {
    public var graphValue: GraphValue { .unsignedInteger(UInt64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try unsignedInteger(from: graphValue, as: Self.self)
    }
}

extension UInt8: GraphPropertyValue {
    public var graphValue: GraphValue { .unsignedInteger(UInt64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try unsignedInteger(from: graphValue, as: Self.self)
    }
}

extension UInt16: GraphPropertyValue {
    public var graphValue: GraphValue { .unsignedInteger(UInt64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try unsignedInteger(from: graphValue, as: Self.self)
    }
}

extension UInt32: GraphPropertyValue {
    public var graphValue: GraphValue { .unsignedInteger(UInt64(self)) }
    public init(graphValue: GraphValue) throws {
        self = try unsignedInteger(from: graphValue, as: Self.self)
    }
}

extension Float: GraphPropertyValue {
    /// Widening preserves every finite Float exactly in the existing Double representation.
    public var graphValue: GraphValue { .floatingPoint(Double(self)) }
    public init(graphValue: GraphValue) throws {
        guard case .floatingPoint(let number) = graphValue, number.isFinite,
              let result = Float(exactly: number) else { throw GraphModelError.invalidValue }
        self = result
    }
}
