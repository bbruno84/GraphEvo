import XCTest
import CoreData
@testable import GraphEvo

final class GraphCloudSyncTests: XCTestCase {
    private final class Delegate: GraphEventDelegate {
        var events: [GraphCloudImportEvent] = []
        var onEvent: ((GraphCloudImportEvent) -> Void)?

        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            guard case .stateChanged(.cloudImport(.finished(let importEvent))) = event else { return }
            events.append(importEvent)
            onEvent?(importEvent)
        }
    }

    func testSuccessfulImportOnEmptyReplicaIsInitial() throws {
        let graph = makeGraph()
        let cloudContainer = makeOfflineCloudContainer()
        graph.persistentContainer = cloudContainer
        graph.prepareCloudSyncTracking(for: cloudContainer)
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.eventDelegate = delegate
        let storeIdentifier = try XCTUnwrap(
            cloudContainer.persistentStoreCoordinator.persistentStores.first?.identifier
        )

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

    func testImportPublishesStartedAndFinishedGraphEvents() {
        let graph = makeGraph()
        var events: [GraphEvent] = []
        let eventDelegate = EventDelegate { events.append($0) }
        graph.eventDelegate = eventDelegate
        events.removeAll()
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)
        let identifier = UUID()

        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .import,
            succeeded: true
        )

        XCTAssertEqual(events.count, 2)
        guard case .stateChanged(.cloudImport(.started(let started))) = events[0],
              case .stateChanged(.cloudImport(.finished(let finished))) = events[1]
        else {
            return XCTFail("Expected started and finished import events")
        }
        XCTAssertEqual(started.identifier, identifier)
        XCTAssertNil(started.endDate)
        XCTAssertTrue(started.isInitialImport)
        XCTAssertEqual(finished.identifier, identifier)
        XCTAssertNotNil(finished.endDate)
        XCTAssertTrue(finished.succeeded)
    }

    func testPendingImportCompletionReplacesPendingStartEvent() throws {
        let graph = makeGraph()
        var events: [GraphEvent] = []
        let eventDelegate = EventDelegate { events.append($0) }
        graph.eventDelegate = eventDelegate
        events.removeAll()
        let identifier = UUID()

        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .import,
            succeeded: true
        )
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)

        XCTAssertEqual(events.count, 1)
        guard case .stateChanged(.cloudImport(.finished(let finished))) = try XCTUnwrap(events.first)
        else {
            return XCTFail("Expected the pending import completion event")
        }
        XCTAssertEqual(finished.identifier, identifier)
        XCTAssertTrue(finished.succeeded)
    }

    func testSuccessfulImportOnPopulatedReplicaIsNotInitial() throws {
        let graph = makeGraph()
        _ = Entity("User", graph: graph)
        let cloudContainer = makeOfflineCloudContainer()
        graph.persistentContainer = cloudContainer
        graph.prepareCloudSyncTracking(for: cloudContainer)
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.eventDelegate = delegate
        let storeIdentifier = try XCTUnwrap(
            cloudContainer.persistentStoreCoordinator.persistentStores.first?.identifier
        )

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
        graph.eventDelegate = delegate
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: true)

        graph.receiveCloudKitEventForTesting(
            storeIdentifier: "store-1",
            type: .export,
            succeeded: true
        )

        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testExportPublishesStartedAndFinishedGraphEvents() {
        let graph = makeGraph()
        var events: [GraphEvent] = []
        let eventDelegate = EventDelegate { events.append($0) }
        graph.eventDelegate = eventDelegate
        events.removeAll()
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: false)
        let identifier = UUID()

        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .export,
            endDate: nil,
            succeeded: false
        )
        graph.receiveCloudKitEventForTesting(
            identifier: identifier,
            storeIdentifier: "store-1",
            type: .export,
            succeeded: true
        )

        XCTAssertEqual(events.count, 2)
        guard case .stateChanged(.cloudUpload(.started(let started))) = events[0],
              case .stateChanged(.cloudUpload(.finished(let finished))) = events[1]
        else {
            return XCTFail("Expected started and finished upload events")
        }
        XCTAssertEqual(started.identifier, identifier)
        XCTAssertNil(started.endDate)
        XCTAssertEqual(finished.identifier, identifier)
        XCTAssertNotNil(finished.endDate)
        XCTAssertTrue(finished.succeeded)
    }

    func testDuplicateExportNotificationsDoNotRepeatUploadState() {
        let graph = makeGraph()
        var events: [GraphEvent] = []
        let eventDelegate = EventDelegate { events.append($0) }
        graph.eventDelegate = eventDelegate
        events.removeAll()
        graph.configureCloudSyncTrackingForTesting(storeIdentifier: "store-1", initialImportPending: false)
        let identifier = UUID()

        for _ in 0..<2 {
            graph.receiveCloudKitEventForTesting(
                identifier: identifier,
                storeIdentifier: "store-1",
                type: .export,
                endDate: nil,
                succeeded: false
            )
        }
        for _ in 0..<2 {
            graph.receiveCloudKitEventForTesting(
                identifier: identifier,
                storeIdentifier: "store-1",
                type: .export,
                succeeded: true
            )
        }

        XCTAssertEqual(events.count, 2)
    }

    func testFailedImportIsDeliveredWithError() {
        let graph = makeGraph()
        let delegate = Delegate()
        let expectation = expectation(description: "import callback")
        delegate.onEvent = { _ in expectation.fulfill() }
        graph.eventDelegate = delegate
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
        graph.eventDelegate = delegate
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
        graph.eventDelegate = delegate
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
        graph.eventDelegate = delegate

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
        firstGraph.eventDelegate = firstDelegate
        firstGraph.receiveCloudKitEventForTesting(storeIdentifier: "store-1", type: .import, succeeded: true)

        let reopenedGraph = makeGraph()
        let reopenedDelegate = Delegate()
        let expectation = expectation(description: "reopened import callback")
        reopenedDelegate.onEvent = { _ in expectation.fulfill() }
        reopenedGraph.eventDelegate = reopenedDelegate
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

    private final class EventDelegate: GraphEventDelegate {
        private let handler: (GraphEvent) -> Void

        init(handler: @escaping (GraphEvent) -> Void) {
            self.handler = handler
        }

        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            handler(event)
        }
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
