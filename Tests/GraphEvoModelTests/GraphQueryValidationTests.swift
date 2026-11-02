import Foundation
import os
import Testing
@testable import GraphEvoModel

private struct QueryShape: GraphModel {
    static let graphType = "shape"
    static let graphKind: GraphNodeKind = .entity
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}
@Suite struct GraphQueryValidationTests {
    @Test func unsupportedTypesReservedNamesAndExcessiveExpressionDepthFailStatically() throws {
        let query = GraphQuery<QueryShape>(budget: try GraphQueryBudget(maximumCandidates: 10))
        for value in [GraphValue.data(Data()), .array([]), .object([:]), .floatingPoint(.infinity)] {
            #expect(throws: GraphQueryError.self) { try query.where(.property("x", .equal, value)).explain() }
        }
        #expect(throws: GraphQueryError.self) { try query.where(.exists("__graphevo_v2.nodeID")).explain() }
        #expect(throws: GraphQueryError.self) { try query.limit(0).explain() }
        var predicate = GraphQueryPredicate.all
        for _ in 0..<5 { predicate = .related(.outgoing(nil), matching: predicate) }
        #expect(throws: GraphQueryError.self) { try query.where(predicate).explain() }
        #expect(throws: GraphQueryError.self) { try query.where(.and(Array(repeating: .all, count: 257))).explain() }
        #expect(throws: GraphQueryError.self) { try GraphQueryBudget(maximumCandidates: Int.max) }
        #expect(throws: GraphQueryError.self) { try GraphTraversal(from: [], via: .outgoing(nil), maximumDepth: 1, budget: query.budget) }
    }
    @Test func evaluationChecksCancellationAfterWorkHasStarted() throws {
        let graph = GraphID(), budget = try GraphQueryBudget(maximumCandidates: 1000)
        let query = GraphQuery<QueryShape>(budget: budget)
        let records = try (0..<100).map { _ in try GraphRecord(id: GraphNodeID(graphID: graph), type: QueryShape.graphType) }
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let evaluation = try GraphQueryEvaluation(request: query.request, graphID: graph, records: records) {
            let count = checks.withLock { count in count += 1; return count }
            if count == 3 { throw CancellationError() }
        }
        #expect(throws: CancellationError.self) { try evaluation.execute(nativeCandidates: 100, propertyBytesCharged: 0) }
        #expect(checks.withLock { $0 } == 3)
    }

    @Test func nativeOrderSurvivesResidualFilteringAndRejectsIncompleteOrRepeatedIDs() throws {
        let graph = GraphID(), budget = try GraphQueryBudget(maximumCandidates: 10)
        let records = try (1...3).map { value in
            try GraphRecord(id: GraphNodeID(graphID: graph), type: QueryShape.graphType,
                properties: ["score": .integer(Int64(value))])
        }
        let query = GraphQuery<QueryShape>(budget: budget)
            .where(.property("score", .greaterThanOrEqual, .integer(2)))
            .sorted(by: [.init(.property("score"), direction: .descending)]).limit(1)
        let order = records.reversed().map(\.id)
        let first = try GraphQueryEvaluation(request: query.request, graphID: graph,
            records: records, nativeOrder: order).execute(nativeCandidates: 3, propertyBytesCharged: 0)
        #expect(first.records == [records[2]])
        let cursor = try #require(first.cursor)
        let second = try GraphQueryEvaluation(request: query.after(cursor).request, graphID: graph,
            records: records, nativeOrder: order).execute(nativeCandidates: 3, propertyBytesCharged: 0)
        #expect(second.records == [records[1]] && second.cursor == nil)
        for invalid in [[order[0], order[0], order[1], order[2]], [order[0], order[2]]] {
            #expect(throws: GraphQueryError.unsupportedStorage) {
                try GraphQueryEvaluation(request: query.request, graphID: graph,
                    records: records, nativeOrder: invalid).execute(nativeCandidates: 3, propertyBytesCharged: 0)
            }
        }
    }

}
