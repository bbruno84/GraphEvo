import Foundation
import Testing
@testable import GraphEvo

@Suite struct GraphSharingPlanTests {
    @Test func durableInsertionPlanRoundTripsAllNodeKindsAndExplicitValues() throws {
        let graph = GraphID(), entityID = GraphNodeID(graphID: graph)
        let records = try [
            GraphRecord(id: entityID, type: "person", properties: ["null": .null, "uuid": .uuid(UUID()), "data": .data(Data([0,255]))], tags: ["tag"], groups: ["group"]),
            GraphRecord(id: GraphNodeID(graphID: graph), type: "edge", endpoints: .relationship(subject: entityID, object: nil)),
            GraphRecord(id: GraphNodeID(graphID: graph), type: "action", endpoints: .action(subjects: [], objects: [entityID]))
        ]
        let plan = try GraphSharedInsertionPlan(graphID: graph, records: records)
        let reopened = try JSONDecoder().decode(GraphSharedInsertionPlan.self, from: JSONEncoder().encode(plan))
        #expect(reopened.operationID == plan.operationID)
        #expect(try reopened.records() == records)
    }

    @Test func foreignAndDuplicateRecordsCannotBecomeDurableIntent() throws {
        let graph = GraphID()
        let record = try GraphRecord(id: GraphNodeID(graphID: graph), type: "node")
        #expect(throws: GraphStoreError.self) { try GraphSharedInsertionPlan(graphID: GraphID(), records: [record]).records() }
        #expect(throws: GraphStoreError.self) { try GraphSharedInsertionPlan(graphID: graph, records: [record, record]).records() }
        #expect(throws: GraphStoreError.self) { try GraphSharedInsertionPlan(graphID: graph, records: []).records() }
    }

    @Test func unknownJournalVersionsAndMalformedValuesFailBeforeLinking() throws {
        let graph = GraphID(), record = try GraphRecord(id: GraphNodeID(graphID: graph), type: "node")
        let bytes = try JSONEncoder().encode(GraphSharedInsertionPlan(graphID: graph, records: [record]))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["version"] = 999
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GraphSharedInsertionPlan.self, from: corrupt)
        #expect(throws: GraphStoreError.self) { try decoded.records() }
    }
    @Test func detailPatchPlanRetainsDeltasAndStagesAnUnlinkedClone() throws {
        let id = GraphNodeID(graphID: GraphID())
        let current = try GraphRecord(id: id, type: "event", endpoints: .action(subjects: [], objects: []),
                                      properties: ["unknown": .string("retain")], tags: ["old"])
        let patch = try GraphRecordPatch(id: id, properties: ["new": .set(.null), "remove": .remove], addingTags: ["new"], removingTags: ["old"])
        let plan = try GraphSharedInsertionPlan(graphID: id.graphID, patch: patch, current: current)
        let decoded = try JSONDecoder().decode(GraphSharedInsertionPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded.version == 2)
        #expect(try decoded.patch?.value() == patch)
        let clone = try #require(try decoded.records().first)
        #expect(clone.id != current.id)
        #expect(clone.endpoints == .action(subjects: [], objects: []))
        #expect(clone.properties == ["new": .null])
        #expect(clone.tags == ["new"])
        #expect(try patch.applying(to: current).properties["unknown"] == .string("retain"))
    }

    @Test func invalidOpaqueIdentityAndInvitationFailBeforeNativeLookup() throws {
        #expect(throws: GraphSharingError.self) {
            try JSONDecoder().decode(GraphSharingIdentity.self, from: Data("{\"recordName\":\"\"}".utf8))
        }
        let identity = try GraphSharingIdentity(recordName: "synthetic-recipient")
        #expect(try JSONDecoder().decode(GraphSharingIdentity.self, from: JSONEncoder().encode(identity)) == identity)
        #expect(throws: GraphSharingError.self) {
            try GraphInvitation(graphID: GraphID(), url: URL(fileURLWithPath: "/invalid"), recipient: identity)
        }
    }

}
