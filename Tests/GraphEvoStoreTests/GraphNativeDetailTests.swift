import Foundation
import Testing
@testable import GraphEvo

@Suite struct GraphNativeDetailTests {
    @Test @MainActor func assignedDetailsSurviveDeletionOfTheirStagingFacade() throws {
        var config = GraphStoreConfiguration()
        config.name = "DetailTransfer-\(UUID())"
        config.backend = .inMemory
        let graph = Graph(configuration: config, migrationEnabled: false)
        #expect(graph.isReady)
        let target = Entity("item", graph: graph)
        target[dynamicMember: "unknown"] = "retain"
        let staging = Entity("item", graph: graph)
        staging[dynamicMember: "new"] = Data([0, 255])
        staging.add(tags: "tag"); staging.add(to: "group")
        graph.sync()
        let moved = try target.runtimeMoveDetails(from: staging, propertyNames: ["new"])
        #expect(moved == ["new"])
        staging.delete()
        graph.sync()
        #expect(target[dynamicMember: "unknown"] as? String == "retain")
        #expect(target[dynamicMember: "new"] as? Data == Data([0, 255]))
        #expect(target.tags == ["tag"])
        #expect(target.groups == ["group"])
        #expect(Search<Entity>(graph: graph).where(.type("item")).sync().count == 1)
    }
}
