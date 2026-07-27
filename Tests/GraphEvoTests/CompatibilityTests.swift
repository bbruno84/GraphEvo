import XCTest
import CoreData
@testable import GraphEvo

final class CompatibilityTests: XCTestCase {
    func testPersistentContainerCompatibilityInitializerLoadsConfiguredStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Compatibility.sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        let callbackExpectation = expectation(description: "persistent store completion")
        var callbackError: Error?

        let container = NSPersistentContainer(
            name: "Compatibility",
            storeDescription: description
        ) { _, error in
            callbackError = error
            callbackExpectation.fulfill()
        }

        wait(for: [callbackExpectation], timeout: 5)
        XCTAssertNil(callbackError)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.first?.url, storeURL)
    }

    func testCloudStorageTransitionMapsKnownAndUnknownRawValues() {
        XCTAssertEqual(GraphCloudStorageTransition(type: 1).debugDescription, "accountAdded")
        XCTAssertEqual(GraphCloudStorageTransition(type: 2).debugDescription, "accountRemoved")
        XCTAssertEqual(GraphCloudStorageTransition(type: 3).debugDescription, "contentRemoved")
        XCTAssertEqual(GraphCloudStorageTransition(type: 4).debugDescription, "initialImportCompleted")
        XCTAssertEqual(GraphCloudStorageTransition(type: 0).debugDescription, "unknown")
        XCTAssertEqual(GraphCloudStorageTransition(type: 99).debugDescription, "unknown")
    }

    func testPersistentContainerCompatibilityInitializerCanDeferStoreLoading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-ContainerDeferred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Deferred.sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        let container = NSPersistentContainer(name: "Deferred", storeDescription: description)

        XCTAssertEqual(container.persistentStoreDescriptions.count, 1)
        XCTAssertEqual(container.persistentStoreDescriptions.first?.url, storeURL)
        XCTAssertTrue(container.persistentStoreCoordinator.persistentStores.isEmpty)
    }
}
