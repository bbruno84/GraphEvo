import CoreData
import Foundation
import Testing
@testable import GraphEvoRuntime
@testable import GraphEvo

func graphSchema() -> StoreSchema {
    GraphRuntimeSchema.current
}

func fixtureModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = "RuntimeFixture"
    entity.managedObjectClassName = "NSManagedObject"
    let value = NSAttributeDescription()
    value.name = "value"
    value.attributeType = .stringAttributeType
    value.isOptional = true
    entity.properties = [value]
    model.entities = [entity]
    return model
}

func fixtureSchema() -> StoreSchema {
    StoreSchema(identifier: "RuntimeFixture", entityVersionHashes: fixtureModel().entityVersionHashesByName,
                makeModel: fixtureModel)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-v2-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

actor LifecycleGate {
    private var arrivals = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() async {
        arrivals += 1
        let ready = observers.filter { arrivals >= $0.0 }
        observers.removeAll { arrivals >= $0.0 }
        for (_, observer) in ready { observer.resume() }
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }

    func waitForArrivals(_ count: Int = 1) async {
        if arrivals < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }

    func release() {
        released = true
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func count() -> Int { arrivals }
}

/// Builds through the v1 facades, then explicitly detaches the closed fixture.
/// Runtime tests read this graph without creating or editing Managed classes.
@MainActor func createV1Fixture(at url: URL) throws {
    let graph = Graph(storeURL: url, migrationEnabled: false)
    #expect(graph.isReady)
    let author = Entity("Author", graph: graph)
    author[dynamicMember: "name"] = "Ada"
    author.add(tags: "active")
    author.add(to: "authors")
    let note = Entity("Note", graph: graph)
    note[dynamicMember: "title"] = "Existing data"
    author.is(relationship: "writes").of(note)
    author.will(action: "reviews").add(objects: note)
    var saveError: (any Error)?
    graph.sync { success, error in
        if !success { saveError = error ?? CocoaError(.fileWriteUnknown) }
    }
    if let saveError { throw saveError }
    let container = try #require(graph.persistentContainer)
    graph.managedObjectContext.reset()
    for store in container.persistentStoreCoordinator.persistentStores {
        try container.persistentStoreCoordinator.remove(store)
    }
    try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
}
