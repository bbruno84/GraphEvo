//
//  GraphEmptySizeTests.swift
//  GraphEvoTests
//
//  Created by Valerio Buriani on 19/09/25.
//

import XCTest
@testable import GraphEvo

final class GraphEmptySizeTests: XCTestCase {
    func testEmptyGraphFileSize() throws {
        // 1. Use a random name to avoid conflicts with other tests.
        var configuration = GraphStoreConfiguration()
        configuration.name = "EmptyGraph-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration)

        // 2. Sync immediately (creates the files on disk).
        graph.sync()

        // 3. Get the path.
        let sqliteURL = graph.location

        // 4. Verify existence.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL.path),
                      "Graph.sqlite does not exist at the expected path")

        // 5. Recupera dimensione
        let attrs = try FileManager.default.attributesOfItem(atPath: sqliteURL.path)
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? -1

        print("📦 Empty Graph.sqlite size = \(sizeBytes) bytes (\(Double(sizeBytes)/1024.0) KB)")

        // 5b. Check for WAL and SHM files and print their sizes if present
        let walURL = sqliteURL.deletingLastPathComponent().appendingPathComponent("Graph.sqlite-wal")
        let shmURL = sqliteURL.deletingLastPathComponent().appendingPathComponent("Graph.sqlite-shm")
        let fm = FileManager.default
        for (fileURL, label) in [(walURL, "wal"), (shmURL, "shm")] {
            if fm.fileExists(atPath: fileURL.path) {
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value {
                    print("📦 Empty Graph.sqlite-\(label) size = \(sizeBytes) bytes (\(Double(sizeBytes)/1024.0) KB)")
                } else {
                    print("📦 Empty Graph.sqlite-\(label) exists but failed to get size.")
                }
            }
        }

        // 6. Assert: must be greater than zero.
        XCTAssertGreaterThan(sizeBytes, 0, "An empty Graph.sqlite must have size > 0")
    }
}
