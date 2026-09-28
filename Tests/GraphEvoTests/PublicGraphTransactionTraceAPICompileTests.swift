import GraphEvo
import XCTest

final class PublicGraphTransactionTraceAPICompileTests: XCTestCase {
    func testOptInAndCodableEventArePublic() throws {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicTrace-\(UUID()).sqlite"), migrationEnabled: false)
        final class Delegate: GraphEventDelegate {
            var receive: ((GraphTransactionTrace) -> Void)?
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                if case .transactionDiagnostic(let trace) = event { receive?(trace) }
            }
        }
        let delegate = Delegate()
        graph.eventDelegate = delegate
        let delivered = expectation(description: "public diagnostic API")
        delivered.expectedFulfillmentCount = 2
        let id = UUID()
        delegate.receive = { trace in
            XCTAssertEqual(trace.diagnosticID, id)
            do { _ = try JSONEncoder().encode(trace) }
            catch { XCTFail("Encoding failed: \(error)") }
            _ = trace.phase
            _ = trace.checkpoints.map { ($0.stage, $0.elapsed, $0.generationsEqual) }
            _ = trace.history?.groups.map { ($0.author, $0.entityName, $0.operation, $0.count) }
            delivered.fulfill()
        }
        XCTAssertEqual(try graph.transaction(diagnosticID: id) { _ in "done" }, "done")
        wait(for: [delivered], timeout: 3)
    }
}
