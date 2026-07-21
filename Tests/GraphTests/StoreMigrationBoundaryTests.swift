import XCTest
import CoreData
@testable import Graph

final class StoreMigrationBoundaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-MigrationBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testIncompatibleExistingStoreIsRejectedWithoutChangingItsPathOrBytes() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "LegacyBoundary"
        configuration.location = directory
        let storeURL = configuration.storeURL
        try createLegacyStore(at: storeURL)
        let originalBytes = try Data(contentsOf: storeURL)

        let graph = Graph(configuration: configuration, migrationEnabled: false)

        guard case .incompatibleStore(let reportedURL)? = graph.storeOpeningError else {
            XCTFail("Expected GraphCK to reject the incompatible store")
            return
        }
        XCTAssertEqual(reportedURL, storeURL)
        XCTAssertEqual(graph.runtimeStoreURL, storeURL)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(try Data(contentsOf: storeURL), originalBytes)
    }

    func testCompatibilityPreflightIsReadOnly() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "LegacyBoundaryPreflight"
        configuration.location = directory
        let storeURL = configuration.storeURL
        try createLegacyStore(at: storeURL)

        XCTAssertFalse(try GraphStoreMetadata.isCompatible(at: storeURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testUnreadableStoreReportsErrorWithoutReplacingThePath() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "UnreadableBoundary"
        configuration.location = directory
        let storeURL = configuration.storeURL
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)

        let graph = Graph(configuration: configuration, migrationEnabled: false)

        guard case .unreadableStore(let reportedURL, _)? = graph.storeOpeningError else {
            XCTFail("Expected an unreadable-store error")
            return
        }
        XCTAssertEqual(reportedURL.standardizedFileURL.path, storeURL.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertNil(graph.managedObjectContext)
    }

    private func createLegacyStore(at url: URL) throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "LegacyEntity"
        entity.managedObjectClassName = "NSManagedObject"

        let attribute = NSAttributeDescription()
        attribute.name = "legacyValue"
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = true
        entity.properties = [attribute]
        model.entities = [entity]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url,
            options: [:]
        )
        try coordinator.remove(store)
    }
}
