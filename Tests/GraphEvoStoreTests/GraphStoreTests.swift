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
        try GraphRecord(id: id, type: Self.graphType, properties: ["name": name.graphValue, "nickname": nickname.graphValue])
    }
}

private struct Link: GraphModel {
    static let graphType = "link.v1"
    static let graphKind: GraphNodeKind = .relationship
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

private struct Event: GraphModel {
    static let graphType = "event.v1"
    static let graphKind: GraphNodeKind = .action
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

private func fixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphStore-A3-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(1))) struct GraphStoreTests {
    @Test func publicTypedCRUDRetainsIdentityThroughReopenAndMainActorTransfer() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let store = try await GraphStore.open(at: url)
        let graphID = store.id
        let person = Person(id: store.makeNodeID(), name: "Ada")
        #expect(try await store.insert(person) == person.id)
        let read = try #require(try await store.fetch(person.id, as: Person.self))
        #expect(read.nickname == nil)
        let name = await MainActor.run { read.name }
        #expect(name == "Ada")
        let updated = try await store.patch(GraphRecordPatch(id: person.id, properties: ["name": .set("Grace".graphValue)]), as: Person.self)
        #expect(updated.name == "Grace")
        try await store.close()
        let reopened = try await GraphStore.open(at: url)
        #expect(reopened.id == graphID)
        #expect(try await reopened.fetchAll(Person.self).map(\.id) == [person.id])
        #expect(try await reopened.fetch(person.id, as: Person.self)?.name == "Grace")
        try await reopened.delete(person.id)
        #expect(try await reopened.fetch(person.id, as: Person.self) == nil)
        try await reopened.close()
    }

    @Test func concurrentCompatiblePublicHandlesShareIdentityAndWrites() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.sqlite")
        let handles = try await withThrowingTaskGroup(of: GraphStore.self) { group in
            for _ in 0..<8 { group.addTask { try await GraphStore.open(at: url) } }
            var result: [GraphStore] = []
            for try await store in group { result.append(store) }
            return result
        }
        #expect(Set(handles.map(\.id)).count == 1)
        let person = Person(id: handles[0].makeNodeID(), name: "Ada")
        try await handles[0].insert(person)
        try await handles[0].close()
        #expect(try await handles[1].fetch(person.id, as: Person.self)?.name == "Ada")
        for store in handles.dropFirst() { try await store.close() }
    }

    @Test func transactionRollsBackAndReadScopeHasNoMutationAPI() async throws {
        struct BodyError: Error {}
        let store = try await GraphStore.inMemory()
        let person = Person(id: store.makeNodeID(), name: "Ada")
        await #expect(throws: BodyError.self) {
            try await store.transaction { scope in _ = try scope.insert(person); throw BodyError() }
        }
        #expect(try await store.fetchAll(Person.self).isEmpty)
        let id = try await store.transaction { scope in try scope.insert(person) }
        let name = try await store.read { try $0.fetch(id, as: Person.self)?.name }
        #expect(name == "Ada")
        try await store.close()
        await #expect(throws: GraphStoreError.self) { try await store.fetch(id, as: Person.self) }
    }

    @Test func invalidTypedPatchCaughtInsideBodyDoesNotChangeTheRecord() async throws {
        let store = try await GraphStore.inMemory()
        let person = Person(id: store.makeNodeID(), name: "Ada")
        try await store.insert(person)
        let patch = try GraphRecordPatch(id: person.id, properties: ["name": .set(.integer(1))])
        try await store.transaction { scope throws -> Void in
            #expect(throws: GraphModelError.self) { try scope.patch(patch, as: Person.self) }
        }
        #expect(try await store.fetch(person.id, as: Person.self)?.name == "Ada")
        try await store.close()
    }

    @Test func foreignAndDuplicateIdentitiesAndUnresolvedEndpointsAreRejected() async throws {
        let store = try await GraphStore.inMemory(), other = try await GraphStore.inMemory()
        let person = Person(id: store.makeNodeID(), name: "Ada")
        try await store.insert(person)
        await #expect(throws: GraphStoreError.self) { try await store.insert(person) }
        await #expect(throws: GraphStoreError.self) { try await other.insert(person) }
        await #expect(throws: GraphStoreError.self) { try await other.fetch(person.id, as: Person.self) }
        let invalidEdge = try GraphRecord(id: store.makeNodeID(), type: Link.graphType,
            endpoints: .relationship(subject: person.id, object: store.makeNodeID()))
        await #expect(throws: GraphStoreError.self) {
            try await store.transaction { try $0.insert(invalidEdge) }
        }
        #expect(try await store.fetchAll(Link.self).isEmpty)
        try await store.close(); try await other.close()
    }

    @Test func cyclesEndpointsAndDeletionPreserveOtherEntitiesAndActions() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Graph.sqlite")
        let store = try await GraphStore.open(at: url)
        let a = Person(id: store.makeNodeID(), name: "A"), b = Person(id: store.makeNodeID(), name: "B")
        let first = try GraphRecord(id: store.makeNodeID(), type: Link.graphType,
                                   endpoints: .relationship(subject: a.id, object: b.id))
        let reverse = try GraphRecord(id: store.makeNodeID(), type: Link.graphType,
                                     endpoints: .relationship(subject: b.id, object: a.id))
        let event = try GraphRecord(id: store.makeNodeID(), type: Event.graphType,
                                   endpoints: .action(subjects: [a.id, b.id], objects: [a.id]))
        try await store.transaction { scope throws -> Void in
            try scope.insert(a); try scope.insert(b)
            try scope.insert(first); try scope.insert(reverse); try scope.insert(event)
        }
        try await store.close()
        let reopened = try await GraphStore.open(at: url)
        #expect(try await reopened.fetch(first.id, as: Link.self)?.record.endpoints == first.endpoints)
        let detached = try GraphRecordPatch(id: first.id, endpoints: .relationship(subject: nil, object: b.id))
        let changed = try await reopened.patch(detached, as: Link.self)
        #expect(changed.record.endpoints == .relationship(subject: nil, object: b.id))
        try await reopened.delete(a.id)
        #expect(try await reopened.fetchAll(Person.self).map(\.id) == [b.id])
        #expect(try await reopened.fetchAll(Link.self).map(\.id) == [first.id])
        #expect(try await reopened.fetch(event.id, as: Event.self)?.record.endpoints == .action(subjects: [b.id], objects: []))
        try await reopened.delete(b.id)
        #expect(try await reopened.fetchAll(Link.self).isEmpty)
        #expect(try await reopened.fetch(event.id, as: Event.self)?.record.endpoints == .action(subjects: [], objects: []))
        try await reopened.close()
    }

    @Test func versionedPropertiesPreserveNullUUIDOpaqueValuesAndUnknownFields() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Graph.sqlite")
        let store = try await GraphStore.open(at: url)
        let person = Person(id: store.makeNodeID(), name: "Ada")
        let opaque = try GraphEncodedValue(codec: "app.future", version: 27, data: Data([0, 255, 128]))
        let extras: [String: GraphValue] = [
            "uuid": .uuid(UUID()), "opaque": .encoded(opaque), "null": .null,
            "max": .unsignedInteger(.max), "min": .integer(.min),
            "decimal": .decimal(Decimal(string: "123456.7890123456789")!),
            "date": .date(Date(timeIntervalSince1970: 1_234_567.125)),
            "nested": .object(["array": .array([.null, .boolean(true), .integer(1)])])
        ]
        try await store.transaction { scope throws -> Void in
            try scope.insert(person)
            _ = try scope.patch(GraphRecordPatch(id: person.id, properties: extras.mapValues { .set($0) }))
        }
        try await store.close()
        let reopened = try await GraphStore.open(at: url)
        _ = try await reopened.patch(GraphRecordPatch(id: person.id, properties: ["name": .set("Grace".graphValue)]), as: Person.self)
        let saved = try #require(try await reopened.read { try $0.record(for: person.id) })
        for (key, value) in extras { #expect(saved.properties[key] == value, "Property: \(key)") }
        #expect(saved.properties["nickname"] == .null)
        try await reopened.close()
    }

    @Test func movingTheClosedStoreDoesNotChangeLogicalIdentity() async throws {
        let parent = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let before = parent.appendingPathComponent("before"), after = parent.appendingPathComponent("after")
        let store = try await GraphStore.open(at: before.appendingPathComponent("Main.sqlite"))
        let person = Person(id: store.makeNodeID(), name: "Ada")
        try await store.insert(person)
        let graphID = store.id
        try await store.close()
        try FileManager.default.moveItem(at: before, to: after)
        let moved = try await GraphStore.open(at: after.appendingPathComponent("Main.sqlite"))
        #expect(moved.id == graphID)
        #expect(try await moved.fetch(person.id, as: Person.self)?.id == person.id)
        try await moved.close()
    }

    @Test @MainActor func UIStateLoadsDetachedModelsFromThePublicGateway() async throws {
        @MainActor final class ListState {
            var people: [Person] = []
            func reload(_ store: GraphStore) async throws { people = try await store.fetchAll(Person.self) }
        }
        let store = try await GraphStore.inMemory()
        let person = Person(id: store.makeNodeID(), name: "Ada")
        try await store.insert(person)
        let state = ListState()
        try await state.reload(store)
        #expect(state.people.map(\.name) == ["Ada"])
        state.people.removeAll()
        #expect(try await store.fetchAll(Person.self).count == 1)
        try await store.close()
    }

    @Test func rejectedValueEncodingAndReservedNamesLeaveNoPartialInsert() async throws {
        let store = try await GraphStore.inMemory()
        let record = try GraphRecord(id: store.makeNodeID(), type: "record", properties: ["invalid": .floatingPoint(.nan)])
        let reserved = try GraphRecord(id: store.makeNodeID(), type: "record", properties: ["__graphevo_v2.nodeID": .string("wrong")])
        try await store.transaction { scope throws -> Void in
            #expect(throws: (any Error).self) { try scope.insert(record) }
            #expect(throws: GraphStoreError.self) { try scope.insert(reserved) }
            #expect(try scope.record(for: record.id) == nil)
            #expect(try scope.record(for: reserved.id) == nil)
        }
        try await store.close()
    }
}
