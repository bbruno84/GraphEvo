import GraphEvo
import XCTest

final class PublicGraphWatchReportAPICompileTests: XCTestCase {
    private final class Delegate: GraphWatchReportDelegate {
        var received: [GraphWatchEvent] = []

        func graph(_ graph: Graph, didReceive report: GraphWatchReport) {
            received.append(contentsOf: report.events)
            _ = report.graph
            _ = report.source
        }
    }

    func testBatchWatchAPIIsPubliclyConsumable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicWatchReport-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let delegate = Delegate()
        graph.watchReportSources = [.cloud]
        graph.watchReportDelegate = delegate

        let event: GraphWatchEvent = .insertedEntity(Entity("Public", graph: graph))
        if case .insertedEntity = event {} else { XCTFail("Unexpected event") }
        XCTAssertTrue(graph.watchReportDelegate === delegate)
    }
}
