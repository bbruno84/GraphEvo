import CloudKit
import GraphEvo
import XCTest

final class PublicGraphCloudRecordIdentityAPICompileTests: XCTestCase {
    func testIdentityAPIIsAvailableWithoutInternalAccess() throws {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicIdentity-\(UUID()).sqlite"), migrationEnabled: false)
        let entity = Entity("E", graph: graph)
        let relationship = Relationship("R", graph: graph)
        let action = Action("A", graph: graph)
        let single: (Node) throws -> CKRecord.ID? = graph.cloudRecordID(for:)
        let batch: ([Node]) throws -> [CKRecord.ID?] = graph.cloudRecordIDs(for:)
        XCTAssertNil(try single(entity))
        XCTAssertEqual(try batch([entity, relationship, action]), [nil, nil, nil])
        let errors: [GraphCloudRecordIdentityError] = [
            .unavailableContext, .foreignContext, .unavailableContainer, .inconsistentContainer
        ]
        XCTAssertTrue(errors.allSatisfy { !$0.localizedDescription.isEmpty })
    }
}
