//
//  GraphModelTransformerTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//


import XCTest
@testable import GraphCK

final class GraphModelTransformerTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        GraphValueTransformer.register()
    }

    func testStringPropertyRoundTrip() async throws {
        let g = Graph(name: "ModelTransformerTests1")
        g.clear()
        g.sync()
        let e = Entity("Note")
        e[dynamicMember: "title"] = "Hello"

        g.sync()

        let fetched = Search<Entity>().where(.type("Note")).sync().first
        XCTAssertEqual(fetched?[dynamicMember: "title"] as? String, "Hello")
    }

    func testAllSupportedTypesRoundTrip() async throws {
        let g = Graph(name: "ModelTransformerTests2")
        let e = Entity("Multi")

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

        let fetched = Search<Entity>().where(.type("Multi")).sync().first
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



