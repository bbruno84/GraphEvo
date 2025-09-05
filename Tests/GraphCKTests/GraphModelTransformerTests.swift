//
//  GraphModelTransformerTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//

/*
import XCTest
@testable import GraphCK

final class GraphModelTransformerTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        GraphValueTransformer.register()
    }

    func testStringPropertyRoundTrip() async throws {
        let g = Graph(name: "ModelTransformerTests1")
        let e = Entity("Note")
        e[dynamicMember: "title"] = "Hello"

        try await g.sync()

        let fetched = try await g.search(forEntityTypes: ["Note"]).first
        XCTAssertEqual(fetched?["title"] as? String, "Hello")
    }

    func testAllSupportedTypesRoundTrip() async throws {
        let g = Graph(name: "ModelTransformerTests2")
        let e = Entity(type: "Multi")

        let now = Date()
        let data = "data".data(using: .utf8)!
        let array: [Any] = ["a", 1, true]
        let dict: [String: Any] = ["one": 1, "two": "2"]

        e["string"] = "Test"
        e["int"] = 42
        e["double"] = 3.14
        e["bool"] = true
        e["date"] = now
        e["data"] = data
        e["array"] = array
        e["dict"] = dict

        try await g.sync()

        let fetched = try await g.search(forEntityTypes: ["Multi"]).first
        XCTAssertEqual(fetched?["string"] as? String, "Test")
        XCTAssertEqual(fetched?["int"] as? Int, 42)
        XCTAssertEqual(fetched?["double"] as? Double, 3.14)
        XCTAssertEqual(fetched?["bool"] as? Bool, true)
        XCTAssertEqual(fetched?["date"] as? Date, now)
        XCTAssertEqual(fetched?["data"] as? Data, data)

        let arr = fetched?["array"] as? [Any]
        XCTAssertEqual(arr?.count, 3)

        let dct = fetched?["dict"] as? [String: Any]
        XCTAssertEqual(dct?["one"] as? Int, 1)
        XCTAssertEqual(dct?["two"] as? String, "2")
    }

    func testPropertyUpdateTriggersWatcher() async throws {
        let g = Graph(name: "ModelTransformerTests3")
        let e = Entity(type: "Note")
        e["title"] = "Start"
        try await g.sync()

        let exp = expectation(description: "Watcher triggers on update")
        let w = Watcher<Entity>(graph: g)
        w.delegate = BlockWatcherDelegate(onUpdate: { _ in exp.fulfill() })
        w.watch(forEntityTypes: ["Note"])

        e["title"] = "Updated"
        try await g.sync()

        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testPropertyRemovalTriggersWatcher() async throws {
        let g = Graph(name: "ModelTransformerTests4")
        let e = Entity(type: "Note")
        e["title"] = "Start"
        try await g.sync()

        let exp = expectation(description: "Watcher triggers on removal")
        let w = Watcher<Entity>(graph: g)
        w.delegate = BlockWatcherDelegate(onUpdate: { _ in exp.fulfill() })
        w.watch(forEntityTypes: ["Note"])

        e["title"] = nil
        try await g.sync()

        await fulfillment(of: [exp], timeout: 2.0)
    }
}

// Helper delegate
final class BlockWatcherDelegate<T: Node>: WatcherDelegate {
    let onUpdate: ((T) -> Void)?

    init(onUpdate: ((T) -> Void)? = nil) {
        self.onUpdate = onUpdate
    }

    func graph(_ graph: Graph, didUpdate node: Node) {
        if let t = node as? T {
            onUpdate?(t)
        }
    }
}
*/
