import Foundation
import Testing
@testable import GraphEvoModel

@Suite struct GraphNumericPropertyValueTests {
    private func signed<Value: FixedWidthInteger & SignedInteger & GraphPropertyValue>(_ type: Value.Type) throws {
        for value: Value in [.min, -1, 0, 1, .max] {
            #expect(value.graphValue == .integer(Int64(value)))
            #expect(try Value(graphValue: GraphValueCodec.decode(GraphValueCodec.encode(value.graphValue))) == value)
        }
        #expect(throws: GraphModelError.self) { try Value(graphValue: .integer(Int64(Value.min) - 1)) }
        #expect(throws: GraphModelError.self) { try Value(graphValue: .integer(Int64(Value.max) + 1)) }
        for wrong: GraphValue in [.unsignedInteger(1), .floatingPoint(1), .boolean(true), .null, .string("1")] {
            #expect(throws: GraphModelError.self) { try Value(graphValue: wrong) }
        }
    }
    private func unsigned<Value: FixedWidthInteger & UnsignedInteger & GraphPropertyValue>(_ type: Value.Type) throws {
        for value: Value in [0, 1, .max] {
            #expect(value.graphValue == .unsignedInteger(UInt64(value)))
            #expect(try Value(graphValue: GraphValueCodec.decode(GraphValueCodec.encode(value.graphValue))) == value)
        }
        if Value.bitWidth < 64 {
            #expect(throws: GraphModelError.self) { try Value(graphValue: .unsignedInteger(UInt64(Value.max) + 1)) }
        }
        for wrong: GraphValue in [.integer(-1), .integer(1), .floatingPoint(1), .boolean(true), .null, .string("1")] {
            #expect(throws: GraphModelError.self) { try Value(graphValue: wrong) }
        }
    }
    @Test func signedWidthsPreserveBoundsAndRejectOverflowAndOtherCategories() throws {
        try signed(Int8.self); try signed(Int16.self); try signed(Int32.self)
    }
    @Test func unsignedWidthsPreserveBoundsAndRejectOverflowAndOtherCategories() throws {
        try unsigned(UInt8.self); try unsigned(UInt16.self); try unsigned(UInt32.self); try unsigned(UInt.self)
    }
    @Test(arguments: [Float.zero, -Float.zero, Float(0.1), -Float(1.25), Float.leastNonzeroMagnitude,
                      Float.leastNormalMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude])
    func floatWideningAndExistingCodecPreserveFiniteValuesExactly(value: Float) throws {
        #expect(value.graphValue == .floatingPoint(Double(value)))
        #expect(try Float(graphValue: value.graphValue).bitPattern == value.bitPattern)
        let decoded = try GraphValueCodec.decode(GraphValueCodec.encode(value.graphValue))
        #expect(try Float(graphValue: decoded).bitPattern == value.bitPattern)
    }
    @Test func floatNarrowingRejectsRoundingOverflowUnderflowAndNonFiniteValues() throws {
        for number: Double in [0.1, 1.0.nextUp, .greatestFiniteMagnitude, .leastNonzeroMagnitude, .infinity, -.infinity, .nan] {
            #expect(throws: GraphModelError.self) { try Float(graphValue: .floatingPoint(number)) }
        }
        for wrong: GraphValue in [.integer(1), .unsignedInteger(1), .decimal(1), .boolean(true), .null] {
            #expect(throws: GraphModelError.self) { try Float(graphValue: wrong) }
        }
        #expect(throws: (any Error).self) { try GraphValueCodec.encode(Float.infinity.graphValue) }
        #expect(throws: (any Error).self) { try GraphValueCodec.encode(Float.nan.graphValue) }
    }
    @Test func newTypesComposeWithNullableCollectionsAndKeyedDecodingErrors() throws {
        let signed: [Int16?] = [.min, nil, .max]
        let unsigned: [String: [UInt32]] = ["bounds": [0, .max]]
        let floats: [Float?] = [0.1, nil, .leastNonzeroMagnitude]
        #expect(try [Int16?](graphValue: GraphValueCodec.decode(GraphValueCodec.encode(signed.graphValue))) == signed)
        #expect(try [String: [UInt32]](graphValue: unsigned.graphValue) == unsigned)
        #expect(try [Float?](graphValue: floats.graphValue) == floats)
        let record = try GraphRecord(id: .init(graphID: GraphID()), type: "Numeric", properties: ["small": .integer(128)])
        do {
            let _: Int8 = try record.value(for: "small")
            Issue.record("Out-of-range property decoded")
        } catch GraphModelError.propertyDecodingFailed(let key, let underlying) {
            #expect(key == "small"); #expect(underlying is GraphModelError)
        }
    }
}
