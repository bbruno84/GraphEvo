import CoreData
import XCTest
@testable import GraphEvo

final class GraphStructuralReadFailureTests: XCTestCase {
    /// Inject a store read failure after references have been saved normally.
    /// All other requests still execute against the real SQLite store.
    private final class FailingCoordinator: NSPersistentStoreCoordinator {
        var failingEntity: String?
        override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext) throws -> Any {
            if let fetch = request as? NSFetchRequest<NSFetchRequestResult>, fetch.entity?.name == failingEntity,
               failingEntity != nil {
                throw NSError(domain: "GraphEvoTests.StoreRead", code: 71)
            }
            return try super.execute(request, with: context)
        }
    }

    func testExposedActionParticipantsFailWithOriginalReadError() throws {
        try withFixture { graph, coordinator in
            let action = Action("Action", graph: graph)
            action.add(subjects: Entity("Subject", graph: graph)).add(objects: Entity("Object", graph: graph))
            try graph.managedObjectContext.save()
            coordinator.failingEntity = "ManagedEntity"
            let result = action.validateStructure()
            XCTAssertFalse(result.isValid)
            XCTAssertEqual(Set(result.issues.compactMap(\.relationshipName)), ["subjectSet", "objectSet"])
            XCTAssertEqual(result.issues.count, 2)
            for issue in result.issues {
                XCTAssertEqual(issue.sourceObjectID, action.node.objectID)
                XCTAssertNotNil(issue.destinationObjectID)
                XCTAssertEqual((issue.error as NSError?)?.domain, "GraphEvoTests.StoreRead")
                XCTAssertEqual((issue.error as NSError?)?.code, 71)
            }
            coordinator.failingEntity = nil
            XCTAssertTrue(action.validateStructure().isValid)
        }
    }

    func testExposedTagsFailForEveryNodeFamilyAndAssociatedEntity() throws {
        try assertDetailReadFailure(key: "tagSet", suffix: "Tag")
    }

    func testExposedGroupsFailForEveryNodeFamilyAndAssociatedEntity() throws {
        try assertDetailReadFailure(key: "groupSet", suffix: "Group")
    }

    private func assertDetailReadFailure(key: String, suffix: String) throws {
        for family in ["Entity", "Relationship", "Action"] {
            try withFixture { graph, coordinator in
                let root = Entity("Root", graph: graph)
                let owner: Node
                switch family {
                case "Relationship": owner = root.is(relationship: "Edge").of(Entity("Target", graph: graph))
                case "Action": owner = root.will(action: "Edge").add(objects: Entity("Target", graph: graph))
                default: owner = root
                }
                owner.add(tags: "tag").add(to: "group")
                try graph.managedObjectContext.save()
                let id = try XCTUnwrap(owner.node.objectIDs(forRelationshipNamed: key).first)
                XCTAssertTrue(owner.validateStructure().isValid)
                coordinator.failingEntity = "Managed" + family + suffix
                for node in family == "Entity" ? [owner] : [owner, root] {
                    let result = node.validateStructure()
                    XCTAssertFalse(result.isValid, family + key)
                    XCTAssertEqual(result.issues.count, 1)
                    let issue = try XCTUnwrap(result.issues.first)
                    XCTAssertEqual(issue.state, .unresolved)
                    XCTAssertEqual(issue.sourceObjectID, owner.node.objectID)
                    XCTAssertEqual(issue.relationshipName, key)
                    XCTAssertEqual(issue.destinationObjectID, id)
                    XCTAssertEqual((issue.error as NSError?)?.domain, "GraphEvoTests.StoreRead")
                    XCTAssertEqual((issue.error as NSError?)?.code, 71)
                }
                coordinator.failingEntity = nil
                XCTAssertTrue(owner.validateStructure().isValid)
                XCTAssertTrue(root.validateStructure().isValid)
            }
        }
    }

    private func withFixture(_ body: (Graph, FailingCoordinator) throws -> Void) throws {
        GraphValueTransformer.register()
        let coordinator = FailingCoordinator(managedObjectModel: Model.create())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadFailure-\(UUID()).sqlite")
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let graph = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
        defer { context.reset(); try? coordinator.remove(store) }
        try body(graph, coordinator)
    }
}
