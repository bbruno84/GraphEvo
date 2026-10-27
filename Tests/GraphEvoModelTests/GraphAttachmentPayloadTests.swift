import Foundation
import Testing
@testable import GraphEvoModel

@Suite struct GraphAttachmentPayloadTests {
    @Test func malformedMetadataDigestAndFutureVersionNeverBecomeReadableContent() throws {
        let graph = GraphID(), owner = GraphNodeID(graphID: graph), id = GraphNodeID(graphID: graph)
        let payload = try GraphAttachmentPayload(id: id, ownerID: owner, fileName: "data.bin", contentType: "public.data", data: Data([0,255]))
        let record = try payload.graphRecord()
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
