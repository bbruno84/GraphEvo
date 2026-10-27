import Foundation
import Testing
@testable import GraphEvoModel

@Suite struct GraphAttachmentPayloadTests {
    @Test func malformedMetadataDigestAndFutureVersionNeverBecomeReadableContent() throws {
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), id = GraphNodeID(graphID: graph)
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "data.bin", contentType: "public.data", data: Data([0,255]))
        let record = try payload.graphRecord(legacy: true)
        let bytes: Data = try record.value(for: "content")
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        for change in ["version", "data", "metadata"] {
            var modified = dictionary
            if change == "version" { modified["version"] = 999 }
            if change == "data" { modified["data"] = Data([1,2]) }
            if change == "metadata" {
                var metadata = try #require(modified["metadata"] as? [String: Any])
                metadata["byteCount"] = 999; modified["metadata"] = metadata
            }
            let content = try PropertyListSerialization.data(fromPropertyList: modified, format: .binary, options: 0)
            let invalid = try GraphRecord(id: id, type: GraphAttachmentPayload.graphType, properties: ["content": .data(content)])
            #expect(throws: GraphAttachmentError.self) { try GraphAttachmentPayload(graphRecord: invalid) }
        }
        #expect(try GraphAttachmentPayload(graphRecord: record).content == payload.content)
    }
}

extension GraphAttachmentPayloadTests {
    @Test func splitMetadataDoesNotCertifyBodyButCompleteReadsVerifyBothParts() throws {
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), id = GraphNodeID(graphID: graph)
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "data.bin", contentType: "public.data", data: Data([0, 255]))
        let record = try payload.graphRecord()
        #expect(try GraphAttachmentPayload(graphRecord: record).content == payload.content)
        #expect(try GraphAttachmentPayload.metadata(from: record) == payload.content.metadata)
        for body in [GraphPropertyChange.remove, .set(.data(Data([1, 2])))] {
            let partial = try GraphRecordPatch(id: id, properties: [GraphAttachmentPayload.contentKey: body]).applying(to: record)
            #expect(try GraphAttachmentPayload.metadata(from: partial) == payload.content.metadata)
            #expect(throws: (any Error).self) { try GraphAttachmentPayload(graphRecord: partial) }
        }
        let bytes: Data = try record.value(for: GraphAttachmentPayload.metadataKey)
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
            let bytes = try PropertyListSerialization.data(fromPropertyList: modified, format: .binary, options: 0)
            let invalid = try GraphRecordPatch(id: id, properties: [GraphAttachmentPayload.metadataKey: .set(.data(bytes))]).applying(to: record)
            #expect(throws: GraphAttachmentError.self) { try GraphAttachmentPayload.metadata(from: invalid) }
            #expect(throws: GraphAttachmentError.self) { try GraphAttachmentPayload(graphRecord: invalid) }
        }
    }
}
