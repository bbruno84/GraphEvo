//
//  GraphValueTransformerTests.swift
//  Graph
//
//  Created by Valerio Buriani on 22/09/25.
//


import XCTest
@testable import Graph

final class CleanGraphStoreOpening: XCTestCase {
    func testSaveStringProperty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphCK-Clean-\(UUID().uuidString)", isDirectory: true)
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
        let bundle = Bundle.graphTests
        guard let legacySQLiteURL = bundle.url(forResource: "Graph", withExtension: "sqlite") else {
            XCTFail("Graph.sqlite non trovato nel bundle")
            return
        }
        let legacyShmURL = bundle.url(forResource: "Graph", withExtension: "sqlite-shm")
        let legacyWalURL = bundle.url(forResource: "Graph", withExtension: "sqlite-wal")

        // 2. Copia in una directory temporanea
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
            XCTFail("GraphCK must reject the incompatible legacy store without migrating it")
            return
        }
        XCTAssertEqual(reportedURL, tempSQLiteURL)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempSQLiteURL.path))
        XCTAssertEqual(try Data(contentsOf: tempSQLiteURL), originalBytes)
    }
}
