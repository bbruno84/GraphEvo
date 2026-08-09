import XCTest
import CoreData
@testable import GraphEvo

final class GraphCloudSyncTests: XCTestCase {
    private final class Delegate: GraphCloudSyncDelegate {
        var events: [GraphCloudImportEvent] = []
        var onEvent: ((GraphCloudImportEvent) -> Void)?

        func graph(_ graph: Graph, didCompleteCloudImport event: GraphCloudImportEvent) {
            events.append(event)
            onEvent?(event)
        }
    }

    func testSuccessfulImportOnEmptyReplicaIsInitial() {
        let graph = makeGraph()
        let cloudContainer = makeOfflineCloudContainer()
        graph.persistentContainer = cloudContainer
        graph.prepareCloudSyncTracking(for: cloudContainer)
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.cloudSyncDelegate = delegate
        let storeIdentifier = cloudContainer.persistentStoreCoordinator.persistentStores.first!.identifier

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: storeIdentifier,
            type: .import,
            succeeded: true
        )

        waitForExpectations(timeout: 1)
        XCTAssertEqual(delegate.events.count, 1)
        XCTAssertTrue(delegate.events[0].isInitialImport)
        XCTAssertTrue(delegate.events[0].succeeded)
    }

    func testSuccessfulImportOnPopulatedReplicaIsNotInitial() {
        let graph = makeGraph()
        _ = Entity("User", graph: graph)
        let cloudContainer = makeOfflineCloudContainer()
        graph.persistentContainer = cloudContainer
        graph.prepareCloudSyncTracking(for: cloudContainer)
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.cloudSyncDelegate = delegate
        let storeIdentifier = cloudContainer.persistentStoreCoordinator.persistentStores.first!.identifier

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: storeIdentifier,
            type: .import,
            succeeded: true
        )

        waitForExpectations(timeout: 1)
        XCTAssertEqual(delegate.events.count, 1)
        XCTAssertFalse(delegate.events[0].isInitialImport)
    }

    func testExportDoesNotProduceImportCallback() {
        let graph = makeGraph()
        let delegate = Delegate()
        graph.cloudSyncDelegate = delegate
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: "store-1",
            type: .export,
            succeeded: true
        )

        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testFailedImportIsDeliveredWithError() {
        let graph = makeGraph()
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.cloudSyncDelegate = delegate
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)
        let expectedError = NSError(domain: "CloudKitTests", code: 7)

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: "store-1",
            type: .import,
            succeeded: false,
            error: expectedError
        )

        waitForExpectations(timeout: 1)
        XCTAssertEqual(delegate.events.count, 1)
        XCTAssertFalse(delegate.events[0].succeeded)
        XCTAssertEqual((delegate.events[0].error as NSError?)?.code, expectedError.code)
        XCTAssertTrue(delegate.events[0].isInitialImport)
    }

    func testDuplicateEventIdentifierProducesOneCallback() {
        let graph = makeGraph()
        let delegate = Delegate()
        let expectation = expectation(description: "single import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.cloudSyncDelegate = delegate
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)
        let identifier = UUID()

        for _ in 0..<2 {
            graph.receiveCloudKitEventForTesting(
                identifier: identifier,
                storeIdentifier: "store-1",
                type: .import,
                succeeded: true
            )
        }

        waitForExpectations(timeout: 1)
        XCTAssertEqual(delegate.events.count, 1)
    }

    func testDifferentStoreIdentifierIsIgnored() {
        let graph = makeGraph()
        let delegate = Delegate()
        graph.cloudSyncDelegate = delegate
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: "store-2",
            type: .import,
            succeeded: true
        )

        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testLocalGraphDoesNotPublishCloudImportEvents() {
        let graph = makeGraph()
        let delegate = Delegate()
        graph.cloudSyncDelegate = delegate

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: "store-1",
            type: .import,
            succeeded: true
        )

        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testNewEmptyGraphStartsInitialImportWaitingAgain() {
        let firstGraph = makeGraph()
        firstGraph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)
        let firstDelegate = Delegate()
        firstGraph.cloudSyncDelegate = firstDelegate
        firstGraph.receiveCloudKitEventForTesting(storeIdentifier: "store-1", type: .import, succeeded: true)

        let reopenedGraph = makeGraph()
        let reopenedDelegate = Delegate()
        let expectation = expectation(description: "reopened import callback")
        reopenedDelegate.onEvent = { _ in expectation.fulfill() }
        reopenedGraph.cloudSyncDelegate = reopenedDelegate
        reopenedGraph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)
        reopenedGraph.receiveCloudKitEventForTesting(storeIdentifier: "store-1", type: .import, succeeded: true)

        waitForExpectations(timeout: 1)
        XCTAssertTrue(reopenedDelegate.events.first?.isInitialImport == true)
    }

    private func makeGraph() -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "CloudSyncTests-\(UUID().uuidString)"
        configuration.backend = .inMemory
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    private func makeOfflineCloudContainer() -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(
            name: "CloudSyncTests",
            managedObjectModel: Model.create()
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        let expectation = expectation(description: "offline cloud store load")
        container.loadPersistentStores { _, error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
        return container
    }
}
