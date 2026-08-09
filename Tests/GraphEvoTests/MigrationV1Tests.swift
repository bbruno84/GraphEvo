//
//  MigrationV1Tests.swift
//  GraphEvo
//

import XCTest
import CoreData
@testable import GraphEvo

final class MigrationV1Tests: XCTestCase {
    func testLegacyStoreRequiresApplicationMigration() throws {
        let bundle = Bundle.graphTests
        guard let legacyURL = bundle.url(
            forResource: "Graph",
            withExtension: "sqlite",
            subdirectory: "Legacy"
        ) else {
            XCTFail("Legacy store was not found in the Legacy resource directory")
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-LegacyMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let tempURL = temporaryDirectory.appendingPathComponent("Graph.sqlite")
        try Data(contentsOf: legacyURL).write(to: tempURL, options: .atomic)
        let originalBytes = try Data(contentsOf: tempURL)

        let legacyMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: tempURL
        )
        XCTAssertFalse(
            Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: legacyMetadata),
            "Legacy store unexpectedly already compatible with the GraphEvo model"
        )

        let graph = Graph(storeURL: tempURL, backend: .sqlite, migrationEnabled: false)

        guard case .incompatibleStore(let reportedURL)? = graph.storeOpeningError else {
            XCTFail("GraphEvo must leave migration of the legacy store to the application")
            return
        }
        XCTAssertEqual(reportedURL, tempURL)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try Data(contentsOf: tempURL), originalBytes)
    }
}
