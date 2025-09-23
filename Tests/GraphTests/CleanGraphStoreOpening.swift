//
//  GraphValueTransformerTests.swift
//  Graph
//
//  Created by Valerio Buriani on 22/09/25.
//


import XCTest
@testable import Graph // o il nome del package/libreria

final class GraphValueTransformerTests: XCTestCase {
    func testSaveStringProperty() throws {
        // 1. Configurazione pulita
        var config = GraphStoreConfiguration()
        config.name = "DebugGraph"
        config.backend = .sqlite
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent("DebugGraph")

        // 2. Istanzia Graph
        let graph = Graph(configuration: config)

        // 3. Crea un nodo con una proprietà di tipo String
        let entity = Entity("TestEntity", graph: graph)
        entity["myProperty"] = "ciao debug"

        // 4. Forza sync
        graph.sync { success, error in
            print("🔎 sync result success=\(success) error=\(String(describing: error))")
        }
    }
}