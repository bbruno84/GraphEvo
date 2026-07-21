//
//  MigrationV1Tests.swift
//  GraphCK
//

import XCTest
import CoreData
@testable import Graph

final class MigrationV1Tests: XCTestCase {
    func testLegacyStoreRequiresApplicationMigration() throws {
        let bundle = Bundle.module
        guard let legacyURL = bundle.url(forResource: "Graph", withExtension: "sqlite") else {
            XCTFail("Legacy store not found in test bundle")
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-LegacyMigration-\(UUID().uuidString)", isDirectory: true)
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
            "Legacy store unexpectedly already compatible with the GraphCK model"
        )

        let graph = Graph(storeURL: tempURL, backend: .sqlite, migrationEnabled: false)

        guard case .incompatibleStore(let reportedURL)? = graph.storeOpeningError else {
            XCTFail("GraphCK must leave migration of the legacy store to the application")
            return
        }
        XCTAssertEqual(reportedURL, tempURL)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try Data(contentsOf: tempURL), originalBytes)
    }
}
