import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime
@testable import GraphEvo

@Test func concurrentHandlesShareTheCurrentModelOwner() async throws {
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .inMemory(UUID()))
    let schema = graphSchema()
    let handles = try await withThrowingTaskGroup(of: StoreHandle.self) { group in
        for _ in 0..<20 { group.addTask { try await registry.open(configuration, schema: schema) } }
        var handles: [StoreHandle] = []
        for try await handle in group { handles.append(handle) }
        return handles
    }
    var identities = Set<UUID>()
    for handle in handles { identities.insert(try await handle.snapshot().runtimeID) }
    #expect(identities.count == 1)
    let names = try await handles[0].read { context in
        context.persistentStoreCoordinator!.managedObjectModel.entities.compactMap(\.name).sorted()
    }
    #expect(names == Model.makeModel().entities.compactMap(\.name).sorted())
    for handle in handles { try await handle.close() }
}

@Test func closingOneHandlePreservesOtherHandlesAndStaleHandlesStayClosed() async throws {
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .inMemory(UUID()))
    let first = try await registry.open(configuration, schema: graphSchema())
    let second = try await registry.open(configuration, schema: graphSchema())
    let identity = try await second.snapshot().runtimeID
    try await first.close()
    await #expect(throws: StoreRuntimeError.self) { try await first.snapshot() }
    #expect(try await second.snapshot().runtimeID == identity)
    try await second.close()
    let reopened = try await registry.open(configuration, schema: graphSchema())
    #expect(try await reopened.snapshot().runtimeID != identity)
    await #expect(throws: StoreRuntimeError.self) { try await first.snapshot() }
    try await reopened.close()
}

@Test func independentMemoryIdentitiesHaveIndependentOwners() async throws {
    let registry = StoreRegistry()
    let first = try await registry.open(StoreConfiguration(location: .inMemory(UUID())), schema: graphSchema())
    let second = try await registry.open(StoreConfiguration(location: .inMemory(UUID())), schema: graphSchema())
    #expect(try await first.snapshot().runtimeID != second.snapshot().runtimeID)
    try await first.close()
    try await second.close()
}

@Test func modelAndAccessConflictsDoNotInvalidateTheExistingOwner() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = StoreRegistry()
    let url = directory.appendingPathComponent("Main.sqlite")
    let configuration = StoreConfiguration(location: .sqlite(url))
    let owner = try await registry.open(configuration, schema: graphSchema())
    await #expect {
        try await registry.open(configuration, schema: fixtureSchema())
    } throws: { error in
        if case StoreRuntimeError.configurationConflict = error { return true }
        return false
    }
    let schema = StoreSchema(identifier: "GraphEvo.current", entityVersionHashes: fixtureModel().entityVersionHashesByName,
                             makeModel: fixtureModel)
    await #expect { try await registry.open(configuration, schema: schema) } throws: { error in
        if case StoreRuntimeError.configurationConflict = error { return true }
        return false
    }
    await #expect {
        try await registry.open(StoreConfiguration(location: .sqlite(url), access: .readOnly), schema: graphSchema())
    } throws: { error in
        if case StoreRuntimeError.configurationConflict = error { return true }
        return false
    }
    _ = try await owner.snapshot()
    try await owner.close()
}

@Test func sameMemoryIdentityRejectsAnIncompatibleSchema() async throws {
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .inMemory(UUID()))
    let first = try await registry.open(configuration, schema: graphSchema())
    await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: fixtureSchema()) }
    try await first.close()
}

@Test func sqliteReopenRetainsTheStoreAndUsesAPrivateQueue() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Main.SQLITE")
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .sqlite(url))
    let handle = try await registry.open(configuration, schema: graphSchema())
    let first = try await handle.read { context in
        #expect(!Thread.isMainThread)
        let coordinator = context.persistentStoreCoordinator!
        return coordinator.metadata(for: coordinator.persistentStores[0])[NSStoreUUIDKey] as? String
    }
    try await handle.close()
    let reopened = try await registry.open(configuration, schema: graphSchema())
    let second = try await reopened.read { context in
        let coordinator = context.persistentStoreCoordinator!
        return coordinator.metadata(for: coordinator.persistentStores[0])[NSStoreUUIDKey] as? String
    }
    #expect(first != nil && first == second)
    try await reopened.close()
}

@Test func currentV1GraphDataSurvivesRuntimeOpenAndClose() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Existing.sqlite")
    try await createV1Fixture(at: url)
    let registry = StoreRegistry()
    let handle = try await registry.open(StoreConfiguration(location: .sqlite(url)), schema: graphSchema())
    let counts = try await handle.read { context in
        try ["ManagedEntity", "ManagedRelationship", "ManagedAction", "ManagedEntityProperty", "ManagedEntityTag", "ManagedEntityGroup"].map {
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: $0))
        }
    }
    #expect(counts == [2, 1, 1, 2, 1, 1])
    let names = try await handle.read { context in
        let request = NSFetchRequest<NSDictionary>(entityName: "ManagedEntityProperty")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["name", "object"]
        return try context.fetch(request).compactMap { $0["object"] as? String }.sorted()
    }
    #expect(names == ["Ada", "Existing data"])
    try await handle.close()
    let reopened = try await registry.open(StoreConfiguration(location: .sqlite(url)), schema: graphSchema())
    #expect(try await reopened.read { try $0.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ManagedEntity")) } == 2)
    try await reopened.close()
}

@Test func failedOpeningCanBeRetriedWithoutARegisteredFailedOwner() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("Parent")
    try Data("sentinel".utf8).write(to: parent)
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .sqlite(parent.appendingPathComponent("Main.sqlite")))
    await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: graphSchema()) }
    #expect(try Data(contentsOf: parent) == Data("sentinel".utf8))
    try FileManager.default.removeItem(at: parent)
    let handle = try await registry.open(configuration, schema: graphSchema())
    try await handle.close()
}

@Test func incompatibleStoreIsRetainedAndItsOriginalSchemaCanReopenIt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = StoreConfiguration(location: .sqlite(directory.appendingPathComponent("Original.sqlite")))
    let registry = StoreRegistry()
    let original = try await registry.open(configuration, schema: fixtureSchema())
    try await original.close()
    await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: graphSchema()) }
    let reopened = try await registry.open(configuration, schema: fixtureSchema())
    #expect(try await reopened.snapshot().schemaIdentifier == "RuntimeFixture")
    try await reopened.close()
}

@Test func modelFactoryMustMatchItsDeclaredHashes() async throws {
    let registry = StoreRegistry()
    let configuration = StoreConfiguration(location: .inMemory(UUID()))
    let invalid = StoreSchema(identifier: "GraphEvo.current", entityVersionHashes: graphSchema().entityVersionHashes,
                             makeModel: fixtureModel)
    await #expect(throws: StoreRuntimeError.self) { try await registry.open(configuration, schema: invalid) }
    let handle = try await registry.open(configuration, schema: graphSchema())
    try await handle.close()
}
