import Combine
import Foundation
import GraphEvo

private struct Profile: GraphModel {
    static let graphType = "example.profile.v1"
    static let graphKind: GraphNodeKind = .entity
    let id: GraphNodeID
    let displayName: String

    init(id: GraphNodeID, displayName: String) { self.id = id; self.displayName = displayName }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id
        displayName = try graphRecord.value(for: "display_name")
    }
    func graphRecord() throws -> GraphRecord {
        try GraphRecord(id: id, type: Self.graphType, properties: ["display_name": displayName.graphValue])
    }
}

private struct VersionedProfile: GraphModel {
    static let graphType = "example.versioned.profile"
    static let graphKind: GraphNodeKind = .entity
    static let graphDataFormat = try! GraphDataFormat(currentVersion: 2, readableVersions: [1, 2])
    let record: GraphRecord
    var id: GraphNodeID { record.id }
    init(graphRecord: GraphRecord) throws { record = graphRecord }
    func graphRecord() throws -> GraphRecord { record }
}

@main struct ModelConsumer {
    static func main() async throws {
        let detached = try GraphRecord(id: GraphNodeID(graphID: GraphID()), type: VersionedProfile.graphType, dataVersion: 2)
        guard try GraphRecord(detached.decoded(as: VersionedProfile.self)) == detached,
              !GraphDataFormat.undeclared.canRead(0) else { throw GraphModelError.invalidValue }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-TypedConsumer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Graph.sqlite")
        let store = try await GraphStore.open(at: url)
        let graphID = store.id
        let profile = Profile(id: store.makeNodeID(), displayName: "Ada")
        try await store.insert(profile)
        let original = try await Task.detached { try await store.fetch(profile.id, as: Profile.self) }.value
        guard original?.displayName == "Ada" else { throw GraphStoreError.missingNode }
        let future = try GraphEncodedValue(codec: "example.future", version: 7, data: Data([0, 255]))
        try await store.transaction { scope in
            _ = try scope.patch(GraphRecordPatch(id: profile.id, properties: ["unknown": .set(.encoded(future))]))
        }
        let patch = try GraphRecordPatch(id: profile.id, properties: ["display_name": .set("Grace".graphValue)])
        let updated = try await store.patch(patch, as: Profile.self)
        let name = await MainActor.run { updated.displayName }
        guard name == "Grace" else { throw GraphModelError.invalidValue }
        let descriptor = GraphQuery<Profile>(budget: try GraphQueryBudget(maximumCandidates: 128))
            .where(.property("display_name", .beginsWith, .string("Gra")))
            .sorted(by: [GraphQuerySort(.property("display_name"))]).limit(1)
        let queryResult = try await store.query(descriptor)
        guard queryResult.items.map(\.displayName) == ["Grace"],
              try await store.count(descriptor).value == 1,
              try await store.project(descriptor, properties: ["display_name"]).rows.count == 1 else { throw GraphModelError.invalidValue }
        let observation = try await store.observe(descriptor)
        var observed = observation.makeAsyncIterator()
        guard case .value(let initial) = await observed.next(), initial.items.first?.displayName == "Grace" else {
            throw GraphModelError.invalidValue
        }
        observation.cancel()
        try await checkCombine(store, query: descriptor)
        try await store.close()
        let reopened = try await GraphStore.open(at: url)
        let retained = try await reopened.read { try $0.record(for: profile.id) }
        guard reopened.id == graphID, retained?.id == profile.id,
              retained?.properties["unknown"] == .encoded(future) else { throw GraphStoreError.corruptIdentity }
        let sourceFile = directory.appendingPathComponent("input.bin")
        try Data([0, 128, 255]).write(to: sourceFile)
        let attachment = try await reopened.importAttachment(from: sourceFile, ownedBy: profile.id)
        guard try await reopened.attachment(attachment.id)?.data == Data([0, 128, 255]) else { throw GraphAttachmentError.incompleteOrInvalidContent }
        try await reopened.delete(profile.id)
        guard try await reopened.attachment(attachment.id) == nil else { throw GraphAttachmentError.incompleteOrInvalidContent }
        guard try await reopened.fetchAll(Profile.self).isEmpty else { throw GraphModelError.invalidValue }
        try await reopened.close()
        let database = try await GraphDatabase.inMemory()
        do {
            _ = try await database.cloudSetupStatus()
            throw GraphModelError.invalidValue
        } catch GraphMirroringError.localDatabase { }
        do {
            _ = try await database.pendingSharedOperations()
            throw GraphModelError.invalidValue
        } catch GraphMirroringError.localDatabase { }
        let first = try await database.createGraph(), control = try await database.createGraph()
        let member = Profile(id: first.makeNodeID(), displayName: "Independent graph")
        try await first.insert(member)
        guard try await control.fetchAll(Profile.self).isEmpty else { throw GraphModelError.invalidValue }
        try await database.close()
        guard try await first.fetch(member.id, as: Profile.self)?.displayName == member.displayName else {
            throw GraphStoreError.missingNode
        }
        try await first.close(); try await control.close()
        let nativeURL = directory.appendingPathComponent("Native.sqlite")
        let native = try await GraphDatabase.open(at: nativeURL, schema: .nativeIdentity)
        guard try await native.graphIDs().isEmpty else { throw GraphModelError.invalidValue }
        let nativeGraph = try await native.createGraph()
        let nativeProfile = Profile(id: nativeGraph.makeNodeID(), displayName: "Grace")
        try await nativeGraph.insert(nativeProfile)
        guard try await native.validateIntegrity(of: nativeGraph.id) == 1 else { throw GraphModelError.invalidValue }
        let nativeQuery = GraphQuery<Profile>(budget: try GraphQueryBudget(maximumCandidates: 128)).where(.id(nativeProfile.id))
        guard try await nativeGraph.query(nativeQuery).items.first?.displayName == "Grace" else { throw GraphModelError.invalidValue }
        try await checkCombine(nativeGraph, query: nativeQuery)
        try await nativeGraph.close(); try await native.close()
        let nativeReopen = try await GraphDatabase.open(at: nativeURL, schema: .nativeIdentity)
        let nativeReader = try await nativeReopen.openGraph(nativeGraph.id)
        guard try await nativeReader.fetch(nativeProfile.id, as: Profile.self)?.displayName == "Grace" else { throw GraphStoreError.missingNode }
        try await nativeReader.close(); try await nativeReopen.close()
        try await checkMirroredOverloadValidation()
        print("GraphEvo Swift 6 typed store, graph catalog and native schema consumer passed")
    }
}

/// Compile and exercise both public schema overloads without native cloud loading or credentials.
private func checkMirroredOverloadValidation() async throws {
    let invalid = URL(string: "https://example.invalid/not-a-local-store.sqlite")!
    for schema in [GraphDatabaseSchema.current, .nativeIdentity] {
        do {
            let database = try await GraphDatabase.openMirrored(at: invalid, containerIdentifier: "iCloud.example.invalid", schema: schema)
            try await database.close()
            throw GraphModelError.invalidValue
        } catch GraphStoreError.persistence(underlying: _) {}
        do {
            let database = try await GraphDatabase.openMirrored(privateStoreAt: invalid, sharedStoreAt: invalid,
                                                               containerIdentifier: "iCloud.example.invalid", schema: schema)
            try await database.close()
            throw GraphModelError.invalidValue
        } catch GraphStoreError.persistence(underlying: _) {}
    }
}

/// Nonisolated consumption avoids inheriting a UI actor into a Combine callback.
private nonisolated func checkCombine(_ store: GraphStore, query: GraphQuery<Profile>) async throws {
    let names = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let token = store.publisher(for: query).sink(receiveCompletion: { _ in names.continuation.finish() }, receiveValue: { state in
        if case .value(let result) = state, let name = result.items.first?.displayName { names.continuation.yield(name) }
    })
    defer { token.cancel(); names.continuation.finish() }
    var iterator = names.stream.makeAsyncIterator()
    guard await iterator.next() == "Grace" else { throw GraphModelError.invalidValue }
}
