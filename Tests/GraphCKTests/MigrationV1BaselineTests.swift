//
//  MigrationV1BaselineTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 15/09/25.
//


import XCTest
import CoreData
import UIKit
import PDFKit
@testable import GraphCK

final class MigrationV1BaselineTests: XCTestCase {

    func testBaselineZipMigration() throws {
        // 1. Recupera baseline.zip dalle resources
        let bundle = Bundle.module
        guard let baselineURL = bundle.url(forResource: "baseline", withExtension: "zip") else {
            XCTFail("baseline.zip non trovato nelle resources")
            return
        }

        // 2. Copia in temp dir (necessario per avere permessi di scrittura)
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("baseline-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: baselineURL, to: tempZipURL)

        // 3. Migra il baseline tramite la logica MigrationV1
        let migratedURL = try MigrationV1.migrateBaseline(baselineURL: tempZipURL)

        // 4. Apri con NSPersistentContainer e il nuovo modello
        let container = NSPersistentContainer(name: "GraphCK", managedObjectModel: Model.create())
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: migratedURL)]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        XCTAssertNil(loadError, "Impossibile caricare lo store migrato dal baseline.zip: \(String(describing: loadError))")

        // 5. Verifica compatibilità con il nuovo modello
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: migratedURL
        )
        XCTAssertTrue(Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                      "Lo store migrato da baseline.zip non è compatibile con il nuovo model")
    }
    
    func testDedupBetweenLocalAndBaseline() throws {
        // 1. Recupera Graph.sqlite legacy dalle resources
        let bundle = Bundle.module
        guard let legacySQLiteURL = bundle.url(forResource: "Graph", withExtension: "sqlite") else {
            XCTFail("Graph.sqlite legacy non trovato nelle resources")
            return
        }
        let legacyShmURL = bundle.url(forResource: "Graph", withExtension: "sqlite-shm")
        let legacyWalURL = bundle.url(forResource: "Graph", withExtension: "sqlite-wal")
        
        // Crea una directory temporanea unica per il legacy store
        let tempLegacyDir = FileManager.default.temporaryDirectory.appendingPathComponent("Graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempLegacyDir, withIntermediateDirectories: true, attributes: nil)
        
        // Copia i file mantenendo i nomi originali
        let tempLegacySQLiteURL = tempLegacyDir.appendingPathComponent("Graph.sqlite")
        try FileManager.default.copyItem(at: legacySQLiteURL, to: tempLegacySQLiteURL)
        
        if let legacyShmURL = legacyShmURL {
            let tempShmURL = tempLegacyDir.appendingPathComponent("Graph.sqlite-shm")
            try FileManager.default.copyItem(at: legacyShmURL, to: tempShmURL)
        }
        if let legacyWalURL = legacyWalURL {
            let tempWalURL = tempLegacyDir.appendingPathComponent("Graph.sqlite-wal")
            try FileManager.default.copyItem(at: legacyWalURL, to: tempWalURL)
        }

        // 2. Apri il legacy store direttamente con Graph (migrazione automatica)
        let localGraph = Graph(storeURL: tempLegacySQLiteURL, backend: .sqlite)

        // 3. Recupera baseline.zip
        guard let baselineZip = bundle.url(forResource: "baseline", withExtension: "zip") else {
            XCTFail("baseline.zip non trovato nelle resources")
            return
        }
        let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: baselineZip, to: tempZipURL)

        // 4. Migra baseline
        let migratedBaselineURL = try MigrationV1.migrateBaseline(baselineURL: tempZipURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempLegacySQLiteURL.path),
                      "Legacy sqlite file non trovato a \(tempLegacySQLiteURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedBaselineURL.path),
                      "Baseline sqlite file non trovato a \(migratedBaselineURL.path)")

        // Debug: stampa i contenuti delle cartelle
        let legacyDirContents = try FileManager.default.contentsOfDirectory(atPath: tempLegacyDir.path)
        print("📂 Legacy dir contents: \(legacyDirContents)")
        let baselineDirContents = try FileManager.default.contentsOfDirectory(atPath: migratedBaselineURL.deletingLastPathComponent().path)
        print("📂 Baseline dir contents: \(baselineDirContents)")

        let baselineGraph = Graph(storeURL: migratedBaselineURL, backend: .sqlite)

        // 5. Conta entità nei due graph
        let localCount = Search<Entity>(graph: localGraph).where(.type("*")).sync().count
        let baselineCount = Search<Entity>(graph: baselineGraph).where(.type("*")).sync().count

        print("Local entities count = \(localCount)")
        print("Baseline entities count = \(baselineCount)")

        XCTAssertGreaterThan(localCount, 0, "Local graph entity count should be greater than 0")
        XCTAssertGreaterThan(baselineCount, 0, "Baseline graph entity count should be greater than 0")
        
        print("Local Graph:")
        localGraph.dbdump()
        
        print("Baseline Graph:")
        baselineGraph.dbdump()
        
        // 6. Esegui dedup
        let discriminator = BaselineDedupDiscriminator(
            localEntityCount: localCount,
            baselineEntityCount: baselineCount,
            originOf: { entity in
                if entity.managedNode.managedObjectContext == localGraph.managedObjectContext {
                    return .local
                } else {
                    return .baseline
                }
            }
        )

        try DedupTool.deduplicateBetween(
            primaryGraph: localGraph,
            secondaryGraph: baselineGraph,
            discriminator: discriminator
        )

        // 7. Post-condition: dopo il dedup non devono esserci più entità del massimo iniziale
        localGraph.dbdump()
        
        let finalCount = Search<Entity>(graph: localGraph).where(.type("*")).sync().count
        XCTAssertLessThanOrEqual(finalCount, localCount + baselineCount,
                                 "Deduplication should not increase entity count")
    }
    
    func testOpenGraphFromSQLiteFile() throws {
        // 1. Recupera Graph.sqlite legacy dal bundle
        let bundle = Bundle.module
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
        try FileManager.default.copyItem(at: legacySQLiteURL, to: tempSQLiteURL)

        if let legacyShmURL = legacyShmURL {
            let tempShmURL = tempDir.appendingPathComponent("Graph.sqlite-shm")
            try FileManager.default.copyItem(at: legacyShmURL, to: tempShmURL)
        }
        if let legacyWalURL = legacyWalURL {
            let tempWalURL = tempDir.appendingPathComponent("Graph.sqlite-wal")
            try FileManager.default.copyItem(at: legacyWalURL, to: tempWalURL)
        }

        // 3. Debug: stampa contenuti della directory
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        print("📂 Contenuti tempDir: \(contents)")
        print("📍 Path sqlite: \(tempSQLiteURL.path)")

        // 4. Tenta di aprire l'istanza Graph
        let graph = Graph(storeURL: tempSQLiteURL, backend: .sqlite)
                
        // 5. Query semplice per verificare che funzioni
        graph.dbdump()
        
        GraphTools.deepScanUnarchivingIssues(context: graph.managedObjectContext)
        
        // 6. Assert: il file è stato aperto correttamente
        XCTAssertNotNil(graph.managedObjectContext, "Il database è stato aperto correttamente")
    }
    
    
}
