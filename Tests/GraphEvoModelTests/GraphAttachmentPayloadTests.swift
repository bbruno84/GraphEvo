import Foundation
import Testing
@testable import GraphEvoModel

@Suite struct GraphAttachmentPayloadTests {
    @Test func nativeAttachmentHasNoBinaryPropertiesAndVerifiesItsDigest() throws {
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), id = GraphNodeID(graphID: graph)
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "data.bin", contentType: "public.data", data: Data([0, 255]))
        let record = try payload.graphRecord()
        #expect(record.properties.isEmpty)
        #expect(try GraphAttachmentPayload(graphRecord: record).content == payload.content)
        var corrupt = record
        corrupt.storedAttachment = GraphAttachmentContent(metadata: payload.content.metadata, data: Data([1, 2]))
        #expect(try GraphAttachmentPayload.metadata(from: corrupt) == payload.content.metadata)
        #expect(throws: GraphAttachmentError.self) { try GraphAttachmentPayload(graphRecord: corrupt) }
        let fake = try GraphRecord(id: id, type: GraphAttachmentPayload.graphType)
        #expect(throws: GraphAttachmentError.self) { try GraphAttachmentPayload(graphRecord: fake) }
    }

    @Test func fixedMetadataRejectsFutureVersionAndInvalidOwners() throws {
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), id = GraphNodeID(graphID: graph)
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "data.bin", contentType: "public.data", data: Data([0, 255]))
        let bytes = try GraphAttachmentPayload.metadataBytes(payload.content.metadata)
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        for field in ["version", "id", "byteCount", "sha256", "ownerID"] {
            var modified = dictionary
            if field == "version" { modified[field] = 999 }
            else {
                var metadata = try #require(modified["metadata"] as? [String: Any])
                if field == "byteCount" { metadata[field] = -1 }
                if field == "sha256" { metadata[field] = "invalid" }
                if field == "id" { metadata[field] = metadata["ownerID"] }
                if field == "ownerID" { metadata[field] = metadata["id"] }
                modified["metadata"] = metadata
            }
            let invalid = try PropertyListSerialization.data(fromPropertyList: modified, format: .binary, options: 0)
            #expect(throws: (any Error).self) { try GraphAttachmentPayload.decodeMetadata(invalid) }
        }
    }

    @Test func currentPropertyCodecRefusesLegacyBinaryAndRoundTripsCollections() throws {
        for legacy: GraphLegacyValue in [.data(Data([0, 255])), .array([.data(Data())])] {
            #expect(throws: (any Error).self) { try GraphValueCodec.decode(GraphLegacyValueCodec.encode(legacy)) }
        }
        let value: GraphValue = .object(["nested": .array([.integer(.min), .unsignedInteger(.max), .null, .boolean(true)])])
        #expect(try GraphValueCodec.decode(GraphValueCodec.encode(value)) == value)
    }

    @Test func keyedValuesDecodeCodableAndRejectCrossChannelCollisions() throws {
        struct Value: Codable, Sendable, Equatable { let names: [String]; let count: Int }
        let value = Value(names: ["Ada", "Grace"], count: 2)
        let record = try GraphRecord(id: .init(graphID: GraphID()), type: "Item", attachments: ["model": try .init(codable: value), "raw": .init(data: Data([0, 255]))])
        #expect(try record.attachmentValue(for: "model", as: Value.self) == value)
        #expect(try record.attachmentData(for: "raw") == Data([0, 255]))
        #expect(throws: (any Error).self) { try record.attachmentValue(for: "raw", as: Value.self) }
        #expect(throws: GraphModelError.self) {
            try GraphRecord(id: record.id, type: record.type, properties: ["raw": .null], attachments: record.attachments)
        }
    }
    @Test func oversizedDetachedValuesDoNotImposeAReadLimit() throws {
        let value = GraphAttachmentValue(data: Data(repeating: 7, count: GraphAttachmentValue.maximumByteCount + 1))
        #expect(value.data.count > GraphAttachmentValue.maximumByteCount)
        #expect(throws: GraphAttachmentError.self) { try value.validateWrite() }
    }

}
