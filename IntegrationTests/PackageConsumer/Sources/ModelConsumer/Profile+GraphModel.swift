import Foundation
import GraphEvo

extension Profile: GraphModel {
    static var graphType: String { "example.profile.v1" }
    static var graphKind: GraphNodeKind { .entity }

    init(graphRecord: GraphRecord) throws {
        self.init(id: graphRecord.id.rawValue, displayName: try graphRecord.value(for: "display_name"))
    }

    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType,
                        properties: ["display_name": displayName.graphValue])
    }
}
