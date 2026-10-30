import Foundation
import Testing
@testable import GraphEvoModel

struct GraphValueCodecTests {
    @Test func versionOneGoldenPayloadsRemainReadableAndStable() throws {
        let opaque = try GraphEncodedValue(codec: "future", version: 42, data: Data([0, 255]))
        let fixtures: [(String, GraphValue)] = [
            (#"{"value":{"null":{}},"version":1}"#, .null),
            (#"{"value":{"integer":{"_0":-9223372036854775808}},"version":1}"#, .integer(.min)),
            (#"{"value":{"unsignedInteger":{"_0":18446744073709551615}},"version":1}"#, .unsignedInteger(.max)),
            (#"{"value":{"encoded":{"codec":"future","data":"AP8=","version":42}},"version":1}"#, .encoded(opaque))
        ]
        for (json, value) in fixtures {
            let data = Data(json.utf8)
            #expect(try GraphValueCodec.decode(data) == value)
            #expect(try GraphValueCodec.encode(value) == data)
        }
    }

    @Test func unknownEnvelopeVersionIsNotSilentlyDecodedAsVersionOne() throws {
        let data = Data(#"{"value":{"null":{}},"version":2}"#.utf8)
        #expect(throws: GraphModelError.self) { try GraphValueCodec.decode(data) }
    }
}

extension GraphValueCodecTests {
    @Test func binaryDataIsLengthCheckedAndLegacyJSONRemainsReadable() throws {
        let old = Data(#"{"value":{"data":{"_0":"AP8="}},"version":1}"#.utf8)
        #expect(try GraphValueCodec.decode(old) == .data(Data([0, 255])))
        for bytes in [Data(), Data([0, 255]), Data(repeating: 173, count: 1024 * 1024)] {
            let encoded = try GraphValueCodec.encode(.data(bytes))
            #expect(encoded.count == bytes.count + 18)
            #expect(try GraphValueCodec.decode(encoded) == .data(bytes))
            #expect(throws: (any Error).self) { try GraphValueCodec.decode(Data(encoded.dropLast())) }
            var extended = encoded; extended.append(0)
            #expect(throws: GraphModelError.self) { try GraphValueCodec.decode(extended) }
            var future = encoded; future[9] = 255
            #expect(throws: GraphModelError.self) { try GraphValueCodec.decode(future) }
        }
        let nested: GraphValue = .array([.data(Data([0, 255])), .object(["bytes": .data(Data())])])
        #expect(try GraphValueCodec.decode(GraphValueCodec.encode(nested)) == nested)
    }
}
