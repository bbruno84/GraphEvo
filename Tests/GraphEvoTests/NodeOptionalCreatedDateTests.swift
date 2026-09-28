import CoreData
import XCTest
@testable import GraphEvo

final class NodeOptionalCreatedDateTests: XCTestCase {
    func testMissingDatesAreSafeForAllFacadesWithoutMutatingOrSerializingFallback() throws {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("OptionalDate-\(UUID()).sqlite"), migrationEnabled: false)
        let nodes: [Node] = [Entity("MissingDate", graph: graph), Relationship("MissingDate", graph: graph), Action("MissingDate", graph: graph)]
        graph.sync()
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            for entity in ["ManagedEntity", "ManagedRelationship", "ManagedAction"] {
                let request = NSBatchUpdateRequest(entityName: entity)
                request.propertiesToUpdate = ["createdDate": NSNull()]
                _ = try background.execute(request)
            }
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: graph.runtimeStoreURL, options: [NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let facade = Graph(transactionContext: context, configuration: graph.configuration)
            let loaded: [Node] = Search<Entity>(graph: facade).where(.type("MissingDate")).sync()
                + Search<Relationship>(graph: facade).where(.type("MissingDate")).sync().map { $0 as Node }
                + Search<Action>(graph: facade).where(.type("MissingDate")).sync().map { $0 as Node }
            XCTAssertEqual(loaded.count, nodes.count)
            for node in loaded {
                XCTAssertTrue(node.validateStructure().isValid)
                XCTAssertNil(node.createdDateIfPresent)
                XCTAssertEqual(node.createdDate, .distantPast)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
                XCTAssertNil(json["createdDate"], "A fallback must not masquerade as a real creation date")
                XCTAssertNil(node.node.value(forKey: "createdDate"))
            }
            XCTAssertFalse(context.hasChanges)
        }
    }

    func testPresentDatesAndPendingEditsKeepTheirExistingBehavior() throws {
        var config = GraphStoreConfiguration()
        config.name = "PresentDate-\(UUID())"
        let graph = Graph(configuration: config, migrationEnabled: false)
        let entity = Entity("Dated", graph: graph)
        let original = try XCTUnwrap(entity.createdDateIfPresent)
        XCTAssertEqual(entity.createdDate, original)
        let known = Date(timeIntervalSince1970: 42)
        entity.setCreatedDate(known)
        XCTAssertEqual(entity.createdDateIfPresent, known)
        XCTAssertEqual(entity.createdDate, known)
        let encoded = try JSONEncoder().encode(entity)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["createdDate"])
        graph.sync()
        XCTAssertEqual(entity.createdDate, known)
    }
}
