//
//  GraphModelTransformerTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 04/09/25.
//


import XCTest
@testable import GraphEvo

final class GraphModelTransformerTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        GraphValueTransformer.register()
    }

    func testStringPropertyRoundTrip() async throws {
        var config = GraphStoreConfiguration()
        config.name = "ModelTransformerTests0-\(UUID().uuidString)"
        let g = Graph(configuration: config)
        g.clear()
        g.sync()
        let e = Entity("Note", graph: g)
        e[dynamicMember: "title"] = "Hello"

        g.sync()

        let fetched = Search<Entity>(graph: g).where(.type("Note")).sync().first
        XCTAssertEqual(fetched?[dynamicMember: "title"] as? String, "Hello")
    }

    func testAllSupportedTypesRoundTrip() async throws {
        var config = GraphStoreConfiguration()
        config.name = "ModelTransformerTests2-\(UUID().uuidString)"
        let g = Graph(configuration: config)
        g.clear()
        let e = Entity("Multi", graph: g)

        let now = Date()
        let data = "data".data(using: .utf8)!
        let array: [Any] = ["a", 1, true]
        let dict: [String: Any] = ["one": 1, "two": "2"]

        e[dynamicMember: "string"] = "Test"
        e[dynamicMember: "int"] = 42
        e[dynamicMember: "double"] = 3.14
        e[dynamicMember: "bool"] = true
        e[dynamicMember: "date"] = now
        e[dynamicMember: "data"] = data
        e[dynamicMember: "array"] = array
        e[dynamicMember: "dict"] = dict

        g.sync()

        let fetched = Search<Entity>(graph: g).where(.type("Multi")).sync().first
        XCTAssertEqual(fetched?[dynamicMember: "string"] as? String, "Test")
        XCTAssertEqual(fetched?[dynamicMember: "int"] as? Int, 42)
        XCTAssertEqual(fetched?[dynamicMember: "double"] as? Double, 3.14)
        XCTAssertEqual(fetched?[dynamicMember: "bool"] as? Bool, true)
        XCTAssertEqual(fetched?[dynamicMember: "date"] as? Date, now)
        XCTAssertEqual(fetched?[dynamicMember: "data"] as? Data, data)

        let arr = fetched?[dynamicMember: "array"] as? [Any]
        XCTAssertEqual(arr?.count, 3)

        let dct = fetched?[dynamicMember: "dict"] as? [String: Any]
        XCTAssertEqual(dct?["one"] as? Int, 1)
        XCTAssertEqual(dct?["two"] as? String, "2")
    }
}

