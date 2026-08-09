//
//  GraphValueTransformerTests.swift
//  Graph
//
//  Created by Valerio Buriani on 22/09/25.
//


import XCTest
@testable import GraphEvo

final class CleanGraphStoreOpening: XCTestCase {
    func testSaveStringProperty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var config = GraphStoreConfiguration()
        config.name = "StringRoundTrip"
        config.backend = .sqlite
        config.location = directory

        let graph = Graph(configuration: config)
        XCTAssertNil(graph.storeOpeningError)
        XCTAssertNotNil(graph.managedObjectContext)

        let entity = Entity("TestEntity", graph: graph)
        entity[dynamicMember: "myProperty"] = "expected-value"

        var saveSuccess = false
        var saveError: Error?
        graph.sync { success, error in
            saveSuccess = success
            saveError = error
        }
        XCTAssertTrue(saveSuccess, "Graph.sync failed: \(String(describing: saveError))")

        let results = Search<Entity>(graph: graph).where(.type("TestEntity")).sync()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?[dynamicMember: "myProperty"] as? String, "expected-value")
    }

    func testOpenGraphFromSQLiteFile() throws {
        guard let legacySQLiteURL = Bundle.graphTestResource(named: "Graph", withExtension: "sqlite") else {
            XCTFail("Graph.sqlite was not found in the Legacy resource directory")
            return
        }
        let legacyShmURL = Bundle.graphTestResource(named: "Graph", withExtension: "sqlite-shm")
        let legacyWalURL = Bundle.graphTestResource(named: "Graph", withExtension: "sqlite-wal")

        // 2. Copy to a temporary directory.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGraphSQLite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

        let tempSQLiteURL = tempDir.appendingPathComponent("Graph.sqlite")
        try Data(contentsOf: legacySQLiteURL).write(to: tempSQLiteURL, options: .atomic)

        if let legacyShmURL = legacyShmURL {
            let tempShmURL = tempDir.appendingPathComponent("Graph.sqlite-shm")
            try Data(contentsOf: legacyShmURL).write(to: tempShmURL, options: .atomic)
        }
        if let legacyWalURL = legacyWalURL {
            let tempWalURL = tempDir.appendingPathComponent("Graph.sqlite-wal")
            try Data(contentsOf: legacyWalURL).write(to: tempWalURL, options: .atomic)
        }

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalBytes = try Data(contentsOf: tempSQLiteURL)
        let graph = Graph(storeURL: tempSQLiteURL, backend: .sqlite, migrationEnabled: false)

        guard case .incompatibleStore(let reportedURL)? = graph.storeOpeningError else {
            XCTFail("GraphEvo must reject the incompatible legacy store without migrating it")
            return
        }
        XCTAssertEqual(reportedURL, tempSQLiteURL)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempSQLiteURL.path))
        XCTAssertEqual(try Data(contentsOf: tempSQLiteURL), originalBytes)
    }
}
