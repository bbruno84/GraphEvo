import XCTest
import Foundation
@testable import GraphEvo

final class SearchAdvancedTests: XCTestCase {
    private func makeGraph() -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "SearchAdvanced-\(UUID().uuidString)"
        configuration.backend = .inMemory
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    func testNumericDateAndStringPredicatesReturnExactMatches() {
        let graph = makeGraph()
        let first = Entity("SearchEntity", graph: graph)
        first[dynamicMember: "score"] = 5
        first[dynamicMember: "name"] = "Alpha"
        first[dynamicMember: "created"] = Date(timeIntervalSince1970: 100)

        let second = Entity("SearchEntity", graph: graph)
        second[dynamicMember: "score"] = 10
        second[dynamicMember: "name"] = "Beta"
        second[dynamicMember: "created"] = Date(timeIntervalSince1970: 200)

        let third = Entity("SearchEntity", graph: graph)
        third[dynamicMember: "score"] = 20
        third[dynamicMember: "name"] = "Gamma"
        third[dynamicMember: "created"] = Date(timeIntervalSince1970: 300)
        graph.sync()

        XCTAssertEqual(
            Search<Entity>(graph: graph).where("score" >= NSNumber(value: 10)).sync().count,
            2
        )
        XCTAssertEqual(
            Search<Entity>(graph: graph).where("score" < NSNumber(value: 10)).sync().map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            Search<Entity>(graph: graph).where("created" >= NSDate(timeIntervalSince1970: 200)).sync().count,
            2
        )
        XCTAssertEqual(
            Search<Entity>(graph: graph).where("name" != "beta").sync().count,
            2
        )
    }

    func testSearchCompositionClearPaginationAndAsyncCallback() async {
        let graph = makeGraph()
        for index in 0..<3 {
            let entity = Entity("SearchEntity", graph: graph)
            entity[dynamicMember: "score"] = index
        }
        graph.sync()

        let typeSearch = Search<Entity>(graph: graph).where(.type("SearchEntity"))
        let highScoreSearch = Search<Entity>(graph: graph).where("score" >= NSNumber(value: 1))
        XCTAssertEqual((typeSearch + highScoreSearch).sync().count, 3)

        var composed = Search<Entity>(graph: graph).where(.type("SearchEntity"))
        composed += highScoreSearch
        XCTAssertEqual(composed.sync().count, 3)
        XCTAssertTrue(composed.clear().sync().isEmpty)

        graph.batchSize = 1
        graph.batchOffset = 1
        let paged = Search<Entity>(graph: graph).where(.type("SearchEntity")).sync()
        XCTAssertEqual(paged.count, 2)
        XCTAssertEqual(paged.map { $0[dynamicMember: "score"] as? Int }.compactMap { $0 }.count, 2)

        graph.batchSize = 0
        graph.batchOffset = 0
        let expectation = expectation(description: "async search")
        Search<Entity>(graph: graph).where(.type("SearchEntity")).async { results in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(results.count, 3)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10)
    }
}
