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
        let data = Data(#"{"value":{"null":{}},"version":99}"#.utf8)
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


extension GraphValueCodecTests {
    @Test func basedURLsAndNestedValuesUseVersionTwoWithoutFlattening() throws {
        let base = URL(string: "https://example.invalid/base/")!
        let url = URL(string: "child?q=1", relativeTo: base)!
        for value: GraphValue in [.url(url), .array([.url(url)]), .object(["key": .url(url)])] {
            let bytes = try GraphValueCodec.encode(value)
            #expect(String(decoding: bytes, as: UTF8.self).contains("\"version\":2"))
            #expect(try GraphValueCodec.decode(bytes) == value)
            let invalidV1 = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":1")
            #expect(throws: GraphModelError.self) { try GraphValueCodec.decode(Data(invalidV1.utf8)) }
        }
        let decoded = try GraphValueCodec.decode(GraphValueCodec.encode(.url(url)))
        if case .url(let round) = decoded { #expect(round.baseURL == base); #expect(round.relativeString == url.relativeString) }
        else { Issue.record("URL kind changed") }
        #expect(String(decoding: try GraphValueCodec.encode(.url(base)), as: UTF8.self).contains("\"version\":1"))
    }
}
