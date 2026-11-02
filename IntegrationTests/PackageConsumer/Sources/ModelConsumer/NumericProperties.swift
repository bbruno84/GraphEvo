import Foundation
import GraphEvo

private struct NumericSample: GraphModel, Equatable {
    static let graphType = "example.numeric"
    static let graphKind: GraphNodeKind = .entity
    let id: UUID
    let signed8: Int8
    let signed16: Int16
    let signed32: Int32
    let unsigned: UInt
    let unsigned8: UInt8
    let unsigned16: UInt16
    let unsigned32: UInt32
    let fraction: Float

    init(id: UUID) {
        self.id = id; signed8 = .min; signed16 = .max; signed32 = .min
        unsigned = .max; unsigned8 = .max; unsigned16 = .max; unsigned32 = .max
        fraction = .leastNonzeroMagnitude
    }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id.rawValue
        signed8 = try graphRecord.value(for: "signed8")
        signed16 = try graphRecord.value(for: "signed16")
        signed32 = try graphRecord.value(for: "signed32")
        unsigned = try graphRecord.value(for: "unsigned")
        unsigned8 = try graphRecord.value(for: "unsigned8")
        unsigned16 = try graphRecord.value(for: "unsigned16")
        unsigned32 = try graphRecord.value(for: "unsigned32")
        fraction = try graphRecord.value(for: "fraction")
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType, properties: [
            "signed8": signed8.graphValue, "signed16": signed16.graphValue, "signed32": signed32.graphValue,
            "unsigned": unsigned.graphValue, "unsigned8": unsigned8.graphValue,
            "unsigned16": unsigned16.graphValue, "unsigned32": unsigned32.graphValue, "fraction": fraction.graphValue
        ])
    }
}

func checkNumericPropertyValues(at url: URL) async throws {
    let database = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
    let graph = try await database.createGraph(), sample = NumericSample(id: UUID())
    let nodeID = try await graph.insert(sample), graphID = graph.id
    guard try await graph.fetch(sample.id, as: NumericSample.self) == sample else { throw GraphModelError.invalidValue }
    let query = GraphQuery<NumericSample>(budget: try GraphQueryBudget(maximumCandidates: 128))
        .where(.property("signed16", .equal, Int16.max.graphValue))
        .where(.property("fraction", .equal, Float.leastNonzeroMagnitude.graphValue))
    guard try await graph.query(query).items == [sample] else { throw GraphModelError.invalidValue }
    try await graph.close(); try await database.close()
    let reopened = try await GraphDatabase.open(at: url, schema: .nativeIdentity)
    let reader = try await reopened.openGraph(graphID)
    guard try await reader.fetch(sample.id, as: NumericSample.self) == sample else { throw GraphModelError.invalidValue }
    let updated = try await reader.patch(.init(id: nodeID, properties: ["unsigned16": .set(UInt16(17).graphValue)]), as: NumericSample.self)
    guard updated.unsigned16 == 17, updated.fraction.bitPattern == sample.fraction.bitPattern else { throw GraphModelError.invalidValue }
    do {
        _ = try await reader.patch(.init(id: nodeID, properties: ["unsigned8": .set(UInt16(256).graphValue)]), as: NumericSample.self)
        throw GraphStoreError.missingNode
    } catch GraphModelError.propertyDecodingFailed(let key, _) {
        guard key == "unsigned8" else { throw GraphModelError.invalidValue }
    }
    guard try await reader.fetch(sample.id, as: NumericSample.self) == updated else { throw GraphModelError.invalidValue }
    try await reader.close(); try await reopened.close()
}
