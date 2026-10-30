import Foundation
import Testing
import GraphEvoModel

private enum FormatDecoderProbe: Error { case invoked }
private struct UndeclaredProbe: GraphModel {
    static let graphType = "format.item"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    init(graphRecord: GraphRecord) throws { throw FormatDecoderProbe.invoked }
    func graphRecord() throws -> GraphRecord { try GraphRecord(id: id, type: Self.graphType) }
}
private struct VersionedItem: GraphModel {
    static let graphType = "format.item"
    static let graphKind: GraphNodeKind = .entity
    static let graphDataFormat = try! GraphDataFormat(currentVersion: 2, readableVersions: [1, 2, 4])
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

@Suite struct GraphDataFormatTests {
    private func record(version: Int64?) throws -> GraphRecord {
        try GraphRecord(id: GraphNodeID(graphID: GraphID()), type: VersionedItem.graphType,
            properties: ["unknown": .null], dataVersion: version)
    }

    @Test func undeclaredZeroAndFutureFormatsAreDistinct() throws {
        let zero = try GraphDataFormat(currentVersion: 0)
        #expect(GraphDataFormat.undeclared.canRead(nil))
        #expect(!GraphDataFormat.undeclared.canRead(0))
        #expect(!zero.canRead(nil))
        #expect(zero.canRead(0))
        #expect(!zero.canRead(1))
        #expect(!zero.canRead(-1))
        #expect(try GraphDataFormat(currentVersion: 0, acceptsUndeclared: true).canRead(nil))
    }

    @Test func invalidDeclarationsAndNegativeRecordVersionsAreRefused() throws {
        #expect(throws: GraphDataFormatError.invalidDeclaration) { try GraphDataFormat(currentVersion: -1) }
        #expect(throws: GraphDataFormatError.invalidDeclaration) { try GraphDataFormat(currentVersion: 1, readableVersions: [0]) }
        #expect(throws: GraphDataFormatError.invalidDeclaration) { try GraphDataFormat(currentVersion: 1, readableVersions: [-1, 1]) }
        #expect(throws: GraphDataFormatError.invalidVersion) { try record(version: -1) }
        #expect(try record(version: Int64.max).dataVersion == Int64.max)
    }

    @Test func formatIsCheckedBeforeCallingTheConsumerDecoder() throws {
        #expect(throws: GraphDataFormatError.unreadableVersion(0)) { try record(version: 0).decoded(as: UndeclaredProbe.self) }
        #expect(throws: FormatDecoderProbe.self) { try record(version: nil).decoded(as: UndeclaredProbe.self) }
        #expect(throws: GraphDataFormatError.unreadableVersion(nil)) { try record(version: nil).decoded(as: VersionedItem.self) }
        #expect(throws: GraphDataFormatError.unreadableVersion(3)) { try record(version: 3).decoded(as: VersionedItem.self) }
    }

    @Test func explicitReadCompatibilityDoesNotAuthorizeReencoding() throws {
        for version: Int64 in [1, 4] {
            let source = try record(version: version)
            let model = try source.decoded(as: VersionedItem.self)
            #expect(model.record == source)
            #expect(throws: GraphDataFormatError.unwritableVersion(version)) { try GraphRecord(model) }
        }
        let current = try record(version: 2)
        #expect(try GraphRecord(current.decoded(as: VersionedItem.self)) == current)
    }

    @Test func patchPreservesVersionAndUnknownValues() throws {
        let source = try record(version: 4)
        let result = try GraphRecordPatch(id: source.id, properties: ["new": .set(.integer(1))]).applying(to: source)
        #expect(result.dataVersion == 4)
        #expect(result.properties["unknown"] == .null)
        #expect(result.properties["new"] == .integer(1))
        #expect(result.id == source.id && result.endpoints == source.endpoints)
    }
}
