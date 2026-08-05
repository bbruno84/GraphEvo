import XCTest
import CoreData
import CloudKit
@testable import GraphEvo

final class GraphCloudPurgeTests: XCTestCase {
    func testPublicPurgeIsRejectedWhileRunningUnderTests() {
        let graph = makeGraph()
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStore { result in
            guard case .failure(let error) = result else {
                return XCTFail("A real CloudKit purge must never run in unit tests")
            }
            XCTAssertEqual((error as? GraphCloudPurgeError), .notSupportedDuringTests)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testLocalConfigurationIsRejected() {
        let graph = makeGraph()
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudKitNotConfigured)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testMissingCloudContainerIsRejected() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        graph.persistentContainer = nil
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudContainerUnavailable)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testCloudContainerWithoutCloudStoreIsRejected() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        graph.persistentContainer = NSPersistentCloudKitContainer(
            name: "PurgeTests",
            managedObjectModel: Model.create()
        )
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudStoreUnavailable)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testCloudKitErrorIsPropagatedAfterOfficialCompletion() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = graph.persistentContainer!.persistentStoreCoordinator.persistentStores.first!
        let expected = NSError(domain: "CloudKitTests", code: 42)
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStoreForTesting(
            container: container,
            store: store,
            executor: { _, _, _, completion in completion(nil, expected) }
        ) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected CloudKit failure") }
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testNilZoneWithoutErrorIsNotReportedAsSuccess() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = graph.persistentContainer!.persistentStoreCoordinator.persistentStores.first!
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStoreForTesting(
            container: container,
            store: store,
            executor: { _, _, _, completion in completion(nil, nil) }
        ) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected invalid completion") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .invalidCompletion)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    private func makeGraph(cloudKitIdentifier: String? = nil) -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PurgeTests-\(UUID().uuidString)"
        configuration.backend = .inMemory
        configuration.cloudKitContainerIdentifier = cloudKitIdentifier
        return Graph(configuration: configuration, migrationEnabled: false)
    }
}
