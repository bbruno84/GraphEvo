import Foundation
import Testing
import GraphEvo

private struct Person: GraphModel {
    static let graphType = "person.v1"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let name: String
    let nickname: String?

    init(id: GraphNodeID, name: String, nickname: String? = nil) {
        self.id = id; self.name = name; self.nickname = nickname
    }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id
        name = try graphRecord.value(for: "name")
        nickname = try graphRecord.value(for: "nickname")
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: id, type: Self.graphType,
                        properties: ["name": name.graphValue, "nickname": nickname.graphValue])
    }
}

private struct Link: GraphModel {
    static let graphType = "writes.v1"
    static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

private struct Event: GraphModel {
    static let graphType = "reviews.v1"
    static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite struct GraphModelTests {
    @Test func applicationModelsRoundTripThroughThePublicProduct() throws {
        let person = Person(id: GraphNodeID(graphID: GraphID()), name: "Ada")
        let record = try GraphRecord(person)
        let decoded = try record.decoded(as: Person.self)
        #expect(decoded.id == person.id)
        #expect(decoded.name == "Ada")
        #expect(decoded.nickname == nil)
        #expect(record.properties["nickname"] == .null)
        #expect(record.createdDate == nil)
    }

    @Test func missingNullAndInvalidPropertyRemainDistinct() throws {
        let record = try GraphRecord(id: .init(graphID: GraphID()), type: "record",
                                     properties: ["null": .null, "wrong": .boolean(true)])
        #expect(throws: GraphModelError.self) { try record.value(for: "missing", as: String?.self) }
        #expect(try record.value(for: "null", as: String?.self) == nil)
        #expect(throws: GraphModelError.self) { try record.value(for: "wrong", as: String.self) }
        do {
            _ = try record.value(for: "wrong", as: String.self)
            Issue.record("Invalid data unexpectedly decoded.")
        } catch GraphModelError.propertyDecodingFailed(let key, let underlying) {
            #expect(key == "wrong")
            #expect(underlying is GraphModelError)
        }
    }

    @Test func modelTypeAndNodeKindAreCheckedBeforeDecoding() throws {
        let id = GraphNodeID(graphID: GraphID())
        let wrongType = try GraphRecord(id: id, type: "some.other.type")
        #expect(throws: GraphModelError.self) { try wrongType.decoded(as: Person.self) }
        let wrongKind = try GraphRecord(id: id, type: Person.graphType, endpoints: .action(subjects: [], objects: []))
        #expect(throws: GraphModelError.self) { try wrongKind.decoded(as: Person.self) }
        let invalidEncoder = try Link(graphRecord: wrongKind)
        #expect(throws: GraphModelError.self) { try GraphRecord(invalidEncoder) }
    }

    @Test func referencesRetainDirectionSetsAndOptionalShapes() throws {
        let graph = GraphID(), author = GraphNodeID(graphID: GraphID())
        let subject = GraphNodeID(graphID: graph), object = GraphNodeID(graphID: graph)
        let relationship = try GraphRecord(id: .init(graphID: graph), type: Link.graphType,
                                          endpoints: .relationship(subject: subject, object: object))
        #expect(try GraphRecord(relationship.decoded(as: Link.self)) == relationship)
        let action = try GraphRecord(id: .init(graphID: graph), type: Event.graphType,
                                    endpoints: .action(subjects: [subject], objects: [object]))
        #expect(try GraphRecord(action.decoded(as: Event.self)) == action)
        _ = try GraphRecord(id: .init(graphID: graph), type: Link.graphType,
                            endpoints: .relationship(subject: nil, object: nil))
        _ = try GraphRecord(id: .init(graphID: graph), type: Event.graphType,
                            endpoints: .action(subjects: [], objects: []))
        #expect(throws: GraphModelError.self) {
            try GraphRecord(id: .init(graphID: graph), type: Link.graphType,
                            endpoints: .relationship(subject: subject, object: author))
        }
    }

    @Test func partialEditsPreserveUnknownValuesAndMetadata() throws {
        let id = GraphNodeID(graphID: GraphID())
        let unknown = try GraphEncodedValue(codec: "app.future", version: 9, data: Data([0, 255, 34]))
        let original = try GraphRecord(id: id, type: "unknown.type", properties: [
            "name": .string("Ada"), "obsolete": .integer(1), "unrecognized": .encoded(unknown)
        ], tags: ["old", "keep"], groups: ["one"], createdDate: Date(timeIntervalSince1970: 100))
        let patch = try GraphRecordPatch(id: id, properties: ["name": .set(.string("Grace")), "obsolete": .remove],
                                         addingTags: ["new"], removingTags: ["old"], addingGroups: ["two"])
        let updated = try patch.applying(to: original)
        #expect(updated.properties["name"] == .string("Grace"))
        #expect(updated.properties["obsolete"] == nil)
        #expect(updated.properties["unrecognized"] == .encoded(unknown))
        #expect(updated.tags == ["keep", "new"])
        #expect(updated.groups == ["one", "two"])
        #expect(updated.type == original.type)
        #expect(updated.createdDate == original.createdDate)
        #expect(original.properties["name"] == .string("Ada"))
    }

    @Test func patchesRejectWrongIdentityKindAndConflictingChanges() throws {
        let id = GraphNodeID(graphID: GraphID())
        let record = try GraphRecord(id: id, type: "record")
        #expect(throws: GraphModelError.self) {
            try GraphRecordPatch(id: .init(graphID: id.graphID)).applying(to: record)
        }
        #expect(throws: GraphModelError.self) {
            try GraphRecordPatch(id: id, addingTags: ["same"], removingTags: ["same"])
        }
        #expect(throws: GraphModelError.self) {
            try GraphRecordPatch(id: id, endpoints: .action(subjects: [], objects: [])).applying(to: record)
        }
        #expect(throws: GraphModelError.self) {
            try GraphRecordPatch(id: id, endpoints: .relationship(subject: .init(graphID: GraphID()), object: nil))
        }
    }

    @Test func scalarAndContainerConversionsAreStrict() throws {
        let values: [GraphValue] = [.integer(.min), .integer(.max), .unsignedInteger(.max), .boolean(true),
                                    .floatingPoint(1.5), .decimal(Decimal(string: "1.23456789")!),
                                    .data(Data([0, 255])), .date(Date(timeIntervalSince1970: 100)),
                                    .url(URL(string: "https://example.com")!), .uuid(UUID())]
        #expect(try Int64(graphValue: values[0]) == .min)
        #expect(try UInt64(graphValue: values[2]) == .max)
        #expect(throws: GraphModelError.self) { try Bool(graphValue: .integer(1)) }
        #expect(throws: GraphModelError.self) { try Double(graphValue: .integer(1)) }
        let nested: [String: [Int?]] = ["values": [1, nil, 3]]
        #expect(try [String: [Int?]](graphValue: nested.graphValue) == nested)
        for value in values {
            let record = try GraphRecord(id: .init(graphID: GraphID()), type: "record", properties: ["value": value])
            #expect(record.properties["value"] == value)
        }
    }

    @Test func valuesCrossTaskAndMainActorBoundaries() async throws {
        let person = Person(id: GraphNodeID(graphID: GraphID()), name: "Ada")
        let record = try await Task.detached { try GraphRecord(person) }.value
        let name = try await MainActor.run { try record.decoded(as: Person.self).name }
        #expect(name == "Ada")
    }

    @Test func modelMappingCannotSilentlyChangeIdentity() throws {
        struct IncorrectModel: GraphModel {
            static let graphType = "record"
            static let graphKind: GraphNodeKind = .entity
            let id: GraphNodeID
            let record: GraphRecord
            init(graphRecord: GraphRecord) {
                record = graphRecord
                id = GraphNodeID(graphID: graphRecord.id.graphID)
            }
            func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
        }
        let record = try GraphRecord(id: .init(graphID: GraphID()), type: "record")
        #expect(throws: GraphModelError.self) { try record.decoded(as: IncorrectModel.self) }
        #expect(throws: GraphModelError.self) { try GraphRecord(IncorrectModel(graphRecord: record)) }
    }
}
