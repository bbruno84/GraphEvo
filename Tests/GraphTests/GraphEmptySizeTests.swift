//
//  GraphEmptySizeTests.swift
//  GraphCKTests
//
//  Created by Valerio Buriani on 19/09/25.
//

import XCTest
@testable import GraphCK

final class GraphEmptySizeTests: XCTestCase {
    func testEmptyGraphFileSize() throws {
        // 1. Usa un nome random per non confliggere con altri test
        let graphName = "EmptyGraph-\(UUID().uuidString)"
        let graph = Graph(name: graphName)

        // 2. Sincronizza subito (crea i file sul disco)
        graph.sync()

        // 3. Recupera il percorso
        let sqliteURL = graph.location

        // 4. Verifica esistenza
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL.path),
                      "Il file Graph.sqlite non esiste al percorso atteso")

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

        // 6. Assert: deve essere > 0
        XCTAssertGreaterThan(sizeBytes, 0, "Graph.sqlite vuoto deve avere size > 0")
    }
}
