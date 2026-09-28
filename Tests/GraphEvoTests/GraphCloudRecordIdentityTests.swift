import CloudKit
import CoreData
import XCTest
@testable import GraphEvo

final class GraphCloudRecordIdentityTests: XCTestCase {
    /// Simulates Apple's mapping only; never starts mirroring or contacts CloudKit.
    private final class Reader: GraphCloudRecordIDReading {
        var mapping: [NSManagedObjectID: CKRecord.ID] = [:]
        var calls: [[NSManagedObjectID]] = []
        func recordIDs(for ids: [NSManagedObjectID], in container: NSPersistentCloudKitContainer) -> [NSManagedObjectID: CKRecord.ID] {
            calls.append(ids)
            return mapping.filter { ids.contains($0.key) }
        }
    }

    private func cloudFixture() throws -> (Graph, Reader) {
        let container = NSPersistentCloudKitContainer(name: "IdentityTest", managedObjectModel: Model.create())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Identity-\(UUID()).sqlite")
        let description = NSPersistentStoreDescription(url: url)
        // A plain description intentionally disables mirroring in this simulated fixture.
        description.cloudKitContainerOptions = nil
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        var configuration = GraphStoreConfiguration()
        configuration.location = url
        let graph = Graph(transactionContext: container.viewContext, configuration: configuration)
        graph.isTransactionFacade = false
        graph.persistentContainer = container
        graph.runtimeStoreURL = url
        let reader = Reader()
        graph.cloudRecordIDReader = reader
        return (graph, reader)
    }

    private func localGraph(cloudRequested: Bool = false) -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.location = FileManager.default.temporaryDirectory.appendingPathComponent("LocalIdentity-\(UUID()).sqlite")
        if cloudRequested { configuration.cloudKitContainerIdentifier = "iCloud.test.identity" }
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    func testAllNodeFamiliesUseMainObjectIDsAndPreserveCompleteIdentity() throws {
        let (graph, reader) = try cloudFixture()
        let nodes: [Node] = [Entity("Entity", graph: graph), Relationship("Relationship", graph: graph), Action("Action", graph: graph)]
        for node in nodes { node[dynamicMember: "payload"] = "detail" }
        try graph.managedObjectContext.save()
        let zone = CKRecordZone.ID(zoneName: "different-zone", ownerName: "different-owner")
        for (index, node) in nodes.enumerated() {
            let expected = CKRecord.ID(recordName: "record-\(index)", zoneID: zone)
            reader.mapping[node.node.objectID] = expected
            XCTAssertEqual(try graph.cloudRecordID(for: node), expected)
            XCTAssertEqual(reader.calls.last, [node.node.objectID])
        }
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
    }

    func testBatchPreservesPositionsDuplicatesAndMissingValuesWithoutCaching() throws {
        let (graph, reader) = try cloudFixture()
        let first = Entity("First", graph: graph)
        let second = Entity("Second", graph: graph)
        try graph.managedObjectContext.save()
        let identity = CKRecord.ID(recordName: "available")
        reader.mapping[first.node.objectID] = identity
        XCTAssertEqual(try graph.cloudRecordIDs(for: [second, first, first]), [nil, identity, identity])
        XCTAssertEqual(reader.calls.count, 1)
        XCTAssertEqual(Set(reader.calls[0]), [first.node.objectID, second.node.objectID])
        let later = CKRecord.ID(recordName: "later")
        reader.mapping[second.node.objectID] = later
        XCTAssertEqual(try graph.cloudRecordID(for: second), later)
        reader.mapping.removeValue(forKey: first.node.objectID)
        XCTAssertNil(try graph.cloudRecordID(for: first))
        let calls = reader.calls.count
        XCTAssertEqual(try graph.cloudRecordIDs(for: []), [])
        XCTAssertEqual(reader.calls.count, calls)
    }

    func testUnsavedTemporaryAndPermanentIDsAreNotAssignedSavedOrLookedUp() throws {
        let (graph, reader) = try cloudFixture()
        let temporary = Entity("Temporary", graph: graph)
        let permanent = Action("PermanentButUnsaved", graph: graph)
        try graph.managedObjectContext.obtainPermanentIDs(for: [permanent.node])
        let original = temporary.node.objectID
        XCTAssertTrue(original.isTemporaryID)
        let inserted = graph.managedObjectContext.insertedObjects
        XCTAssertEqual(try graph.cloudRecordIDs(for: [temporary, permanent]), [nil, nil])
        XCTAssertTrue(reader.calls.isEmpty)
        XCTAssertEqual(temporary.node.objectID, original)
        XCTAssertEqual(graph.managedObjectContext.insertedObjects, inserted)
        let fresh = try XCTUnwrap(graph.newBackgroundContext())
        try fresh.performAndWait {
            XCTAssertEqual(try fresh.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ManagedEntity")), 0)
            XCTAssertEqual(try fresh.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ManagedAction")), 0)
        }
    }

    func testLocalAndLocalFallbackModeReturnNilButRejectForeignInputs() throws {
        for cloudRequested in [false, true] {
            // Tests force local mode; this simulates the effective plain-container fallback,
            // not an actual CloudKit account/setup failure.
            let graph = localGraph(cloudRequested: cloudRequested)
            XCTAssertFalse(graph.persistentContainer is NSPersistentCloudKitContainer)
            let nodes: [Node] = [Entity("E", graph: graph), Relationship("R", graph: graph), Action("A", graph: graph)]
            graph.sync()
            XCTAssertEqual(try graph.cloudRecordIDs(for: nodes), [nil, nil, nil])
            let scopedRead: (Graph) throws -> [CKRecord.ID?] = { scoped in
                let entity = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("E")).sync().first)
                let relationship = try XCTUnwrap(Search<Relationship>(graph: scoped).where(.type("R")).sync().first)
                let action = try XCTUnwrap(Search<Action>(graph: scoped).where(.type("A")).sync().first)
                return try scoped.cloudRecordIDs(for: [entity, relationship, action])
            }
            XCTAssertEqual(try graph.readSnapshot(scopedRead), [nil, nil, nil])
            XCTAssertEqual(try graph.transaction(scopedRead), [nil, nil, nil])
            let other = localGraph()
            let foreign = Entity("Foreign", graph: other)
            XCTAssertThrowsError(try graph.cloudRecordIDs(for: nodes + [foreign])) {
                XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .foreignContext)
            }
        }
    }

    func testInvalidBatchFailsBeforeAnyLookupAndContainerMismatchIsTyped() throws {
        let (graph, reader) = try cloudFixture()
        let node = Entity("Node", graph: graph)
        try graph.managedObjectContext.save()
        let other = localGraph()
        let foreign = Entity("Foreign", graph: other)
        XCTAssertThrowsError(try graph.cloudRecordIDs(for: [node, foreign])) {
            XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .foreignContext)
        }
        XCTAssertTrue(reader.calls.isEmpty)
        graph.persistentContainer = other.persistentContainer
        XCTAssertThrowsError(try graph.cloudRecordID(for: node)) {
            XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .inconsistentContainer)
        }
        graph.persistentContainer = nil
        XCTAssertThrowsError(try graph.cloudRecordID(for: node)) {
            XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .unavailableContainer)
        }
    }

    func testDetachedNodeAndUnavailableGraphContextAreTypedErrors() throws {
        let graph = localGraph()
        let node = Entity("Node", graph: graph)
        graph.sync()
        graph.managedObjectContext.reset()
        XCTAssertThrowsError(try graph.cloudRecordID(for: node)) {
            XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .unavailableContext)
        }
        graph.managedObjectContext = nil
        XCTAssertThrowsError(try graph.cloudRecordID(for: node)) {
            XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .unavailableContext)
        }
        XCTAssertEqual(try graph.cloudRecordIDs(for: []), [])
    }

    func testSnapshotAndTransactionReuseContainerAndRejectUIContextNodes() throws {
        let (graph, reader) = try cloudFixture()
        let node = Entity("Persisted", graph: graph)
        let relationship = Relationship("Persisted", graph: graph)
        let action = Action("Persisted", graph: graph)
        try graph.managedObjectContext.save()
        let identities = ["entity", "relationship", "action"].map { CKRecord.ID(recordName: $0) }
        for (node, identity) in zip([node as Node, relationship, action], identities) {
            reader.mapping[node.node.objectID] = identity
        }
        let container = try XCTUnwrap(graph.persistentContainer)
        let stores = container.persistentStoreCoordinator.persistentStores
        let read: (Graph) throws -> [CKRecord.ID?] = { scoped in
            XCTAssertTrue(scoped.scopedIdentityContainer === container)
            let fetched = try XCTUnwrap(Search<Entity>(graph: scoped).where(.type("Persisted")).sync().first)
            XCTAssertThrowsError(try scoped.cloudRecordID(for: node)) {
                XCTAssertEqual($0 as? GraphCloudRecordIdentityError, .foreignContext)
            }
            let fetchedRelationship = try XCTUnwrap(Search<Relationship>(graph: scoped).where(.type("Persisted")).sync().first)
            let fetchedAction = try XCTUnwrap(Search<Action>(graph: scoped).where(.type("Persisted")).sync().first)
            let result = try scoped.cloudRecordIDs(for: [fetched, fetchedRelationship, fetchedAction])
            XCTAssertFalse(scoped.managedObjectContext.hasChanges)
            return result
        }
        XCTAssertEqual(try graph.readSnapshot(read), identities.map(Optional.some))
        XCTAssertEqual(try graph.transaction(read), identities.map(Optional.some))
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores, stores)
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
        XCTAssertEqual(reader.calls.count, 2)
    }

    func testPendingChangesAndPendingDeletionAreNotSavedByLookup() throws {
        let (graph, reader) = try cloudFixture()
        let node = Entity("Node", graph: graph)
        node[dynamicMember: "value"] = "saved"
        try graph.managedObjectContext.save()
        reader.mapping[node.node.objectID] = CKRecord.ID(recordName: "record")
        node[dynamicMember: "value"] = "pending"
        XCTAssertNotNil(try graph.cloudRecordID(for: node))
        XCTAssertTrue(graph.managedObjectContext.hasChanges)
        let saved = try graph.readSnapshot { scoped in
            Search<Entity>(graph: scoped).where(.type("Node")).sync().first?[dynamicMember: "value"] as? String
        }
        XCTAssertEqual(saved, "saved")
        node.delete()
        let calls = reader.calls.count
        XCTAssertNil(try graph.cloudRecordID(for: node))
        XCTAssertEqual(reader.calls.count, calls)
        XCTAssertTrue(graph.managedObjectContext.hasChanges)
    }

    func testAppleReaderReturnsMissingMappingOnNonMirroredStore() throws {
        let (graph, _) = try cloudFixture()
        let node = Entity("Node", graph: graph)
        try graph.managedObjectContext.save()
        graph.cloudRecordIDReader = AppleGraphCloudRecordIDReader()
        XCTAssertNil(try graph.cloudRecordID(for: node))
        XCTAssertFalse(graph.managedObjectContext.hasChanges)
    }
}
