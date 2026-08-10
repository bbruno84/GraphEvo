import Foundation
import GraphEvo

private enum ConsumerFixtureError: LocalizedError {
    case graphOpeningFailed(GraphStoreOpeningError)
    case saveFailed(Error?)
    case assertionFailed(String)
    case readinessTimeout

    var errorDescription: String? {
        switch self {
        case .graphOpeningFailed(let error):
            return "GraphEvo failed to open the consumer fixture store: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "GraphEvo failed to save the consumer fixture store: \(error?.localizedDescription ?? "unknown error")"
        case .assertionFailed(let message):
            return "Package consumer assertion failed: \(message)"
        case .readinessTimeout:
            return "GraphEvo did not report store readiness before the timeout"
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ConsumerFixtureError.assertionFailed(message)
    }
}

private func makeReadyGraph(configuration: GraphStoreConfiguration) throws -> Graph {
    let graph = Graph(configuration: configuration, migrationEnabled: false)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Graph, GraphStoreOpeningError>?

    graph.whenReady { readiness in
        result = readiness
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + 10) == .success else {
        throw ConsumerFixtureError.readinessTimeout
    }

    switch result {
    case .success(let readyGraph):
        return readyGraph
    case .failure(let error):
        throw ConsumerFixtureError.graphOpeningFailed(error)
    case .none:
        throw ConsumerFixtureError.readinessTimeout
    }
}

private func save(_ graph: Graph) throws {
    var result: (Bool, Error?)?
    graph.sync { success, error in
        result = (success, error)
    }

    guard result?.0 == true else {
        throw ConsumerFixtureError.saveFailed(result?.1)
    }
}

private func runConsumerScenario() throws {
    let storeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GraphEvo-PackageConsumer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    do {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ConsumerFixture"
        configuration.location = storeDirectory
        let graph = try makeReadyGraph(configuration: configuration)

        let entity = Entity("ConsumerRecord", graph: graph)
        entity[dynamicMember: "name"] = "Ada"
        try save(graph)

        let fetchedAfterCreate = Search<Entity>(graph: graph)
            .where(.type("ConsumerRecord"))
            .sync()
        try require(fetchedAfterCreate.count == 1, "the created entity should be returned by Search")
        try require(
            fetchedAfterCreate[0][dynamicMember: "name"] as? String == "Ada",
            "the created entity should expose its property value"
        )

        fetchedAfterCreate[0][dynamicMember: "name"] = "Grace"
        try save(graph)

        let fetchedAfterUpdate = Search<Entity>(graph: graph)
            .where(.type("ConsumerRecord"))
            .sync()
        try require(fetchedAfterUpdate.count == 1, "the updated entity should remain searchable")
        try require(
            fetchedAfterUpdate[0][dynamicMember: "name"] as? String == "Grace",
            "the updated property value should be persisted"
        )

        fetchedAfterUpdate[0].delete()
        try save(graph)

        let fetchedAfterDelete = Search<Entity>(graph: graph)
            .where(.type("ConsumerRecord"))
            .sync()
        try require(fetchedAfterDelete.isEmpty, "the deleted entity should no longer be searchable")
    }
}

do {
    try runConsumerScenario()
    print("GraphEvo package consumer fixture passed")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
