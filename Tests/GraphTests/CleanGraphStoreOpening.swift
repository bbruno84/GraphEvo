//
//  GraphValueTransformerTests.swift
//  Graph
//
//  Created by Valerio Buriani on 22/09/25.
//


import XCTest
import UIKit
import PDFKit
@testable import Graph // o il nome del package/libreria

final class CleanGraphStoreOpening: XCTestCase {
    func testSaveStringProperty() throws {
        // 1. Configurazione pulita
        GraphValueTransformer.register()
        var config = GraphStoreConfiguration()
        config.name = "DebugGraph2"
        config.backend = .sqlite
        

        // 2. Istanzia Graph
        let graph = Graph(configuration: config)
        graph.clear()

        // 3. Crea un nodo con una proprietà di tipo String
        let entity = Entity("TestEntity", graph: graph)
        entity[dynamicMember: "myProperty"] = "me cojoni"
        
        // 4. Forza sync
        graph.sync { success, error in
            print("🔎 sync result success=\(success) error=\(String(describing: error))")
        }
        
        for obj in graph.managedObjectContext.insertedObjects {
            if obj.entity.attributesByName.keys.contains("object") {
                let raw = obj.primitiveValue(forKey: "object")
                print("🔍 Primitive object stored = \(String(describing: raw)) type=\(type(of: raw))")
            }
        }
        
        for obj in graph.managedObjectContext.insertedObjects {
            if obj.entity.attributesByName.keys.contains("object") {
                let v = obj.value(forKey: "object")
                print("🔎 Inserted object entity=\(obj.entity.name ?? "?") type=\(type(of: v)) value=\(String(describing: v))")
            } else {
                print("ℹ️ Inserted object entity=\(obj.entity.name ?? "?") has no 'object' field")
            }
        }
        
        for obj in graph.managedObjectContext.insertedObjects {
            if obj.entity.attributesByName.keys.contains("appDataVersion") {
                let v = obj.value(forKey: "appDataVersion")
                print("🆕 Inserted object entity=\(obj.entity.name ?? "?") appDataVersion=\(String(describing: v))")
            }
        }
        
        
        
        let entities = Search<Entity>(graph: graph).where(.type("TestEntity")).sync().first!
        print("Entity content: \(entities[dynamicMember: "myProperty"]!)")
        
    }
    
    func testOpenGraphFromSQLiteFile() throws {
        
        GraphValueTransformer.register()
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
            
        
        
        // 6. Assert: il file è stato aperto correttamente
        XCTAssertNotNil(graph.managedObjectContext, "Il database è stato aperto correttamente")
    }
    
    
}



extension Graph {
    func dbdump() {
        let allEntities = Search<Entity>(graph: self).where(.type("*")).sync()
        print("🔎 Entity count: \(allEntities.count)")

        var expectedPDF = 0
        var expectedImage = 0
        var PDFcount = 0
        var imageCount = 0
        var dataCount = 0
        var otherCount = 0
        var categorieCount = 0
        var categorieCustom = 0
        
        var entityTypeCounts: [String: Int] = [:]
        
        for entitiy in allEntities {
            entityTypeCounts[entitiy.type, default: 0] += 1
        }
        
        print("📊 Entities trovate:")
        for (type, count) in entityTypeCounts.sorted(by: { $0.value > $1.value }) {
            print("   • \(type): \(count)")
            switch type {
                case "MediaBollette":
                let mediaEntities = Search<Entity>(graph: self).where(.type("MediaBollette")).sync()
                for entity in mediaEntities {
                    if entity[dynamicMember: "media_type"] as? String == "pdf" {
                        expectedPDF += 1
                    } else if entity[dynamicMember: "media_type"] as? String == "img" {
                        expectedImage += 1
                    }
                    if let value = entity[dynamicMember: "media"] {
                        if value is UIImage {
                            
                            imageCount += 1
                        } else if let data = value as? Data {
                            if PDFDocument(data: data) != nil {
                                PDFcount += 1
                                //saveDocumentToDisk(document, named: UUID().uuidString)
                            } else if UIImage(data: data) != nil {
                                imageCount += 1
                            } else {
                                dataCount += 1
                            }
                        } else {
                            otherCount += 1
                        }
                    }
                }
                print("     • Expected images: \(expectedImage)")
                print("     • 🖼️ UIImage: \(imageCount)")
                print("     • Expected PDFs: \(expectedPDF)")
                print("     • 📄 PDFDocument: \(PDFcount)")
            case "Categoria":
                let categorie = Search<Entity>(graph: self).where(.type("Categoria")).sync()
                for categoria in categorie {
                    if categoria[dynamicMember: "tipo"] as? String == "custom" {
                        categorieCustom += 1
                    } else {
                        categorieCount += 1
                    }
                }
                print("     • di cui custom: \(categorieCustom)")
            default:
                continue
            }
        }
    }

}
