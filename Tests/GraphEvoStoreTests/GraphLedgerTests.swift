import Foundation
import Testing
@testable import GraphEvoStore
import GraphEvoModel

@Suite struct GraphLedgerTests {
    private let origin = UUID()
    private let date = Date(timeIntervalSince1970: 100)

    @Test func manyOperationsRetainOnlyCurrentPreviousAndThirtyTwoEvents() throws {
        var value = GraphLedger.empty(GraphID())
        var prior: GraphLedgerOperation?
        for index in 0..<100 {
            value = try value.applying(.begin(kind: "migration-\(index)", phase: "prepare", information: Data("{\"step\":\(index)}".utf8)), origin: origin, date: date)
            #expect(value.previous == prior)
            let id = try #require(value.current?.id)
            value = try value.applying(.finish(operation: id, outcome: .succeeded, summary: "Completed"), origin: origin, date: date)
            prior = value.current
            #expect(value.history.count <= 32)
        }
        #expect(value.current?.kind == "migration-99" && value.previous?.kind == "migration-98")
        #expect(value.history.count == 32)
        #expect(try JSONEncoder().encode(value).count < GraphLedger.maximumPayloadBytes)
    }
    @Test func retriesCoalesceWithoutGrowingTheHistory() throws {
        var value = try GraphLedger.empty(GraphID()).applying(.begin(kind: "repair", phase: "convert", information: GraphLedger.emptyInformation), origin: origin, date: date)
        let id = try #require(value.current?.id), initial = try JSONEncoder().encode(value).count
        for _ in 0..<2000 { value = try value.applying(.retry(operation: id, failure: "Consumer retry"), origin: origin, date: date) }
        #expect(value.current?.id == id && value.current?.attempts == 2001)
        #expect(value.history.count == 1)
        #expect(try JSONEncoder().encode(value).count < initial + 128)
        value = try value.applying(.interrupt(operation: id, failure: "Needs inspection"), origin: origin, date: date)
        #expect(throws: GraphLedgerError.operationInProgress) {
            try value.applying(.begin(kind: "other", phase: "prepare", information: GraphLedger.emptyInformation), origin: origin, date: date)
        }
        value = try value.applying(.resume(operation: id), origin: origin, date: date)
        #expect(value.history.map(\.summary) == ["Started", "Interrupted", "Resumed"])
    }
    @Test func consumerInformationIsIndependentAndCanonicalNoOpsKeepRevision() throws {
        var value = GraphLedger.empty(GraphID())
        value = try value.applying(.information(Data("{\"b\":2,\"a\":1}".utf8)), origin: origin, date: date)
        let noOp = try value.applying(.information(Data("{ \"a\":1,\"b\":2 }".utf8)), origin: origin, date: date)
        #expect(noOp == value && value.current == nil && value.history.isEmpty)
        value = try value.applying(.begin(kind: "migration", phase: "prepare", information: Data("{\"custom\":true}".utf8)), origin: origin, date: date)
        let id = try #require(value.current?.id)
        #expect(try value.applying(.progress(operation: id, phase: "prepare"), origin: origin, date: .distantFuture) == value)
        let changed = try value.applying(.operationInformation(operation: id, json: Data("{\"consumer\":\"value\"}".utf8)), origin: origin, date: date)
        #expect(changed.information == value.information && changed.current?.id == id && changed.history == value.history)
        #expect(changed.current?.information != value.current?.information)
    }
    @Test(arguments: ["[]", "null", "{", "{\"x\":1e9999}", "{\"\":1}"])
    func malformedInformationCannotPartiallyEditLedger(json: String) throws {
        let value = GraphLedger.empty(GraphID())
        #expect(throws: (any Error).self) { try value.applying(.information(Data(json.utf8)), origin: origin, date: date) }
        #expect(value.information == GraphLedger.emptyInformation && value.current == nil)
    }
    @Test func informationDepthSizeAndTextLimitsAreExplicit() throws {
        let value = GraphLedger.empty(GraphID())
        #expect(throws: (any Error).self) { try value.applying(.information(Data(repeating: 32, count: 16 * 1024 + 1)), origin: origin, date: date) }
        let nested = "{\"x\":" + String(repeating: "[", count: 10) + "0" + String(repeating: "]", count: 10) + "}"
        #expect(throws: (any Error).self) { try value.applying(.information(Data(nested.utf8)), origin: origin, date: date) }
        #expect(throws: (any Error).self) { try value.applying(.begin(kind: String(repeating: "x", count: 129), phase: "a", information: GraphLedger.emptyInformation), origin: origin, date: date) }
    }
    @Test func staleOperationAndTerminalTransitionsAreRefused() throws {
        var value = try GraphLedger.empty(GraphID()).applying(.begin(kind: "migration", phase: "prepare", information: GraphLedger.emptyInformation), origin: origin, date: date)
        #expect(throws: GraphLedgerError.staleOperation) { try value.applying(.progress(operation: UUID(), phase: "commit"), origin: origin, date: date) }
        let id = try #require(value.current?.id)
        #expect(throws: GraphLedgerError.staleOperation) { try value.applying(.finish(operation: id, outcome: .running, summary: "Invalid"), origin: origin, date: date) }
        value = try value.applying(.finish(operation: id, outcome: .failed, summary: "Failed"), origin: origin, date: date)
        #expect(throws: GraphLedgerError.staleOperation) { try value.applying(.retry(operation: id, failure: "Invalid"), origin: origin, date: date) }
        #expect(value.current?.finishedAt == date)
    }
    @Test func clocksDoNotOrderOrAuthorizeUpdates() throws {
        let initial = try GraphLedger.empty(GraphID()).applying(.begin(kind: "migration", phase: "prepare", information: GraphLedger.emptyInformation), origin: origin, date: date)
        let next = try initial.applying(.progress(operation: #require(initial.current?.id), phase: "convert"), origin: origin, date: Date(timeIntervalSince1970: 1))
        #expect(next.revision != initial.revision && next.current?.updatedAt == Date(timeIntervalSince1970: 1))
        #expect(next.history.last?.phase == "convert")
    }
}
