//
//  MigrationV1Tests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 15/09/25.
//


import XCTest
import CoreData
@testable import Graph

final class MigrationV1Tests: XCTestCase {
    
    func testLegacyStoreMigratesToCurrentModel() throws {
        // 1. Path dello store legacy incluso nei test bundle
        let bundle = Bundle.module
        guard let legacyURL = bundle.url(forResource: "Graph", withExtension: "sqlite") else {
            XCTFail("Legacy store not found in test bundle")
            return
        }
        
        // 2. Copia in temp directory (Core Data deve avere permessi di scrittura)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        try FileManager.default.copyItem(at: legacyURL, to: tempURL)
        
        // 3. Verifica metadata -> non compatibile
        let legacyMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: tempURL
        )
        XCTAssertFalse(Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: legacyMetadata),
                       "Legacy store unexpectedly already compatible with new model")
        
        // 4. Forza la migrazione: apriamo con il nuovo modello
        let container = NSPersistentContainer(name: "GraphCK", managedObjectModel: Model.create())
        let storeDesc = NSPersistentStoreDescription(url: tempURL)
        container.persistentStoreDescriptions = [storeDesc]
        
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        XCTAssertNil(loadError, "Migration failed: \(String(describing: loadError))")
        
        // 5. Verifica metadata post-migrazione -> compatibile
        let migratedMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: tempURL
        )
        XCTAssertTrue(Model.create().isConfiguration(withName: nil, compatibleWithStoreMetadata: migratedMetadata),
                      "Migrated store is not compatible with new model")
    }
}
