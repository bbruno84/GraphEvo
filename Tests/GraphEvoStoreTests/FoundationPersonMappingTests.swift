import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime

extension FoundationPerson: GraphModel {
    static var graphType: String { "foundation.person" }
    static var graphKind: GraphNodeKind { .entity }
    init(graphRecord: GraphRecord) throws {
        self.init(id: graphRecord.id.rawValue, name: try graphRecord.value(for: "name"))
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType, properties: ["name": name.graphValue])
    }
}

private struct WrongUUIDModel: GraphModel {
    let id: UUID
    let record: GraphRecord
    static var graphType: String { FoundationPerson.graphType }
    static var graphKind: GraphNodeKind { .entity }
    init(id: UUID, record: GraphRecord) { self.id = id; self.record = record }
    init(graphRecord: GraphRecord) { id = UUID(); record = graphRecord }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord { record }
}

@Suite(.timeLimit(.minutes(2))) struct FoundationPersonMappingTests {
    @Test func foundationIdentityPersistsAndIsScopedByStoreWithoutChangingTheDomainModel() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("FoundationMapping-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let manager=GraphContextManager(registry:StoreRegistry(),schema:GraphRuntimeSchema.nativeIdentity,adapter:GraphCoordinatorFactory.adapter)
        let a=GraphID(),b=GraphID(),firstURL=root.appendingPathComponent("A.sqlite"),secondURL=root.appendingPathComponent("B.sqlite")
        let first=try await manager.createGraph(id:a,at:firstURL),second=try await manager.createGraph(id:b,at:secondURL)
        let uuid=UUID(),person=FoundationPerson(id:uuid,name:"Ada"),other=FoundationPerson(id:uuid,name:"Independent")
        let node=try await first.insert(person),otherNode=try await second.insert(other)
        #expect(node == GraphNodeID(graphID:a,rawValue:uuid))
        #expect(otherNode == GraphNodeID(graphID:b,rawValue:uuid))
        #expect(node != otherNode)
        #expect(try await first.fetch(uuid,as:FoundationPerson.self)==person)
        #expect(try await second.read {try $0.fetch(uuid,as:FoundationPerson.self)}==other)
        await #expect(throws:GraphStoreError.self) {try await second.fetch(node,as:FoundationPerson.self)}
        let query=GraphQuery<FoundationPerson>(budget:try GraphQueryBudget(maximumCandidates:128))
        #expect(try await first.query(query).items == [person])
        let observation=try await first.observe(query)
        var states=observation.makeAsyncIterator()
        if case .value(let value)=await states.next() {#expect(value.items == [person])} else {Issue.record("Missing initial UUID model observation")}
        _ = try await first.patch(.init(id:node,properties:["name":.set(.string("Grace"))]),as:FoundationPerson.self)
        var refreshed=false
        while let state=await states.next() {
            if case .value(let value)=state,value.items.first?.name=="Grace" {#expect(value.items.first?.id == uuid);refreshed=true;break}
            if case .failure=state {Issue.record("UUID model observation failed");break}
        }
        #expect(refreshed);observation.cancel()
        try await first.close();try await second.close()
        let reopened=try await manager.openGraph(id:a,at:firstURL)
        #expect(try await reopened.fetch(uuid,as:FoundationPerson.self)?.name == "Grace")
        try await reopened.delete(uuid)
        #expect(try await reopened.fetch(uuid,as:FoundationPerson.self)==nil)
        try await reopened.close()
        let control=try await manager.openGraph(id:b,at:secondURL)
        #expect(try await control.fetch(uuid,as:FoundationPerson.self)==other)
        try await control.close();try FileManager.default.removeItem(at:root)
    }

    @Test func UUIDMappingValidatesBothDirectionsAndUsesExplicitDetachedScope() async throws {
        let person=FoundationPerson(id:UUID(),name:"Ada"),a=GraphID(),b=GraphID()
        let record=try GraphRecord(person,in:a),other=try GraphRecord(person,in:b)
        #expect(record.id.rawValue == person.id && other.id.rawValue == person.id)
        #expect(record.id.graphID == a && other.id.graphID == b)
        #expect(try record.decoded(as:FoundationPerson.self)==person)
        #expect(throws:GraphModelError.self) {try record.decoded(as:WrongUUIDModel.self)}
        #expect(throws:GraphModelError.self) {try GraphRecord(WrongUUIDModel(id:UUID(),record:record),in:a)}
        #expect(throws:GraphModelError.self) {try GraphRecord(WrongUUIDModel(id:person.id,record:other),in:a)}
        let copied=try await Task.detached {try GraphRecord(person,in:a).decoded(as:FoundationPerson.self)}.value
        #expect(copied==person)
        let database=try await GraphDatabase.inMemory(),store=try await database.createGraph()
        await #expect(throws:GraphModelError.self) {try await store.insert(WrongUUIDModel(id:UUID(),record:record))}
        #expect(try await store.fetchAll(FoundationPerson.self).isEmpty)
        try await store.close();try await database.close()
    }
}
