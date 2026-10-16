import GraphEvo
import XCTest

final class PublicGraphWatchReportAPICompileTests: XCTestCase {
    func testBatchWatchAPIIsPubliclyConsumable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicWatchReport-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.watchReportSources = [.cloud]
        graph.watchReportCompletion = { report, error in
            if let report {
                _ = report.graph
                _ = report.source
                _ = report.events
                _ = report.structuralValidationResults
                _ = report.unmaterializedDeletions.map { ($0.objectID, $0.error) }
            }
            _ = error
        }

        let event: GraphWatchEvent = .insertedEntity(Entity("Public", graph: graph))
        if case .insertedEntity = event {} else { XCTFail("Unexpected event") }
        XCTAssertNotNil(graph.watchReportCompletion)
    }

    func testBatchWatchCompletionAPIIsPubliclyConsumable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicWatchCompletion-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.watchReportSources = [.local, .cloud]
        graph.watchReportCompletion = { report, error in
            if let report {
                _ = report.graph
                _ = report.source
                _ = report.events
                _ = report.structuralValidationResults
                _ = report.unmaterializedDeletions.map { ($0.objectID, $0.error) }
            }
            _ = error
        }

        let completion: GraphWatchReportCompletion? = graph.watchReportCompletion
        XCTAssertNotNil(completion)
    }

    func testStructuralValidationIsAvailableOnAllPublicNodeFamilies() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PublicValidation-\(UUID().uuidString)"
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let nodes: [Node] = [Entity("E", graph: graph), Relationship("R", graph: graph), Action("A", graph: graph)]
        graph.sync()
        for node in nodes {
            let result: GraphStructuralValidationResult = node.validateStructure()
            _ = node.createdDateIfPresent
            XCTAssertTrue(result.isValid)
            for reference in result.references {
                switch reference.state {
                case .absent: XCTAssertNil(reference.destinationObjectID)
                case .materialized: XCTAssertNotNil(reference.destinationObjectID)
                case .unresolved: XCTFail("Unexpected unresolved reference")
                }
            }
        }
    }

}
