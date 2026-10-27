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
