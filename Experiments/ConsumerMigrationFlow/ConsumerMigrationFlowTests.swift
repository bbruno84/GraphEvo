import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor ConsumerLedgerServer {
    private var value: GraphLedgerRemote?
    private var offline = false
    func setOffline(_ value: Bool) { offline = value }
    func fetch() throws -> GraphLedgerRemote? {
        if offline { throw URLError(.notConnectedToInternet) }
        return value
    }
    func save(_ ledger: GraphLedger, base: GraphLedgerRemote?) throws -> GraphLedgerRemote {
        if offline { throw URLError(.notConnectedToInternet) }
        guard base?.recordArchive == value?.recordArchive else { throw CKError(.serverRecordChanged) }
        let next = GraphLedgerRemote(value: ledger, recordArchive: Data(UUID().uuidString.utf8))
        value = next; return next
    }
    nonisolated var adapter: GraphCloudAdapter {
        .init(ledger: .init(fetch: { _, _ in try await self.fetch() }, save: { _, _, value, base in try await self.save(value, base: base) }),
              account: { _ in "consumer-example-account" }, make: { _, _, _, _ in .init(fetch: { _ in }, cancel: {}) })
    }
}

@Suite(.timeLimit(.minutes(2))) struct ConsumerMigrationFlowTests {
    private struct Fixture {
        let root: URL
        let server: ConsumerLedgerServer
        let ids: ConsumerMigrationIDs
        let config: GraphCloudConfiguration
        let manager: GraphContextManager
        let graph: GraphStore
        let flow: ConsumerMigrationExample
    }
    private func fixture(root: URL? = nil, server: ConsumerLedgerServer = .init(), ids: ConsumerMigrationIDs? = nil) async throws -> Fixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ConsumerMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = ids ?? .init(graph: GraphID())
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity,
            adapter: GraphCoordinatorFactory.adapter)
        let url = root.appendingPathComponent("Source.sqlite"), fresh = !FileManager.default.fileExists(atPath: url.path)
        let graph = try await (fresh ? manager.createGraph(id: ids.graph, at: url) : manager.openGraph(id: ids.graph, at: url))
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.consumer." + ids.graph.rawValue.uuidString,
            environment: .development, directory: root.appendingPathComponent("Engine"))
        _ = try await manager.startCloudSession(config, adapter: server.adapter)
        try await manager.bindCloudZone(.init(scope: .private, owner: "owner", name: "consumer-example"), to: ids.graph, configuration: config)
        if fresh { try await ConsumerMigrationExample.seed(graph, ids: ids) }
        return .init(root: root, server: server, ids: ids, config: config, manager: manager, graph: graph,
            flow: .init(manager: manager, configuration: config, ids: ids, directory: root))
    }
    private func close(_ f: Fixture) async throws {
        try await f.flow.close(); try await f.graph.close(); try await f.manager.stopCloudSession(f.config)
    }
    private func reopen(_ f: Fixture) async throws -> Fixture {
        try await close(f)
        return try await fixture(root: f.root, server: f.server, ids: f.ids)
    }
    @Test(arguments: ["prepared", "transformation", "sealed", "publication", "ledger"])
    func restartAtConsumerBoundariesNeverReplaysTransformationOrDuplicatesBackup(point: String) async throws {
        var f = try await fixture()
        try await f.flow.prepare()
        let invoice = f.ids.node(64)
        await #expect(throws: GraphStoreError.self) { _ = try await f.graph.transaction { try $0.patch(.init(id: invoice, properties: ["forbidden": .set(.boolean(true))])) } }
        #expect(try await f.manager.backups.list(in: f.root.appendingPathComponent("Backups")).isEmpty)
        if point == "transformation" {
            await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.transformAndSeal(fault: .afterTransformation) }
        } else if point != "prepared" {
            #expect(try await f.flow.transformAndSeal())
        }
        if ["publication", "ledger"].contains(point) {
            if point == "publication" {
                await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.publish(fault: .afterPublication) }
                #expect(try await f.flow.journal().receipt == nil)
            } else {
                _ = try await f.flow.publish()
                await #expect(throws: ConsumerMigrationFailure.self) { try await f.flow.completeAfterConsumerVerification(fault: .afterLedgerCompletion) }
            }
        }
        f = try await reopen(f)
        try await f.flow.prepare()
        if !["publication", "ledger"].contains(point) {
            #expect(try await f.flow.transformAndSeal() == (point == "prepared"))
        }
        let result = try await f.flow.publish()
        let journal = try await f.flow.journal()
        try await ConsumerMigrationExample.validate(f.graph, ids: f.ids, operation: journal.operation)
        #expect(try await f.manager.backups.list(in: f.root.appendingPathComponent("Backups")).count == 1)
        #expect(try await f.manager.backups.verify(at: result.backupURL).manifest.id == result.receipt.backupID)
        try await f.flow.completeAfterConsumerVerification()
        let ledger = try await f.manager.reconcileGraphLedger(for: f.ids.graph, configuration: f.config)
        #expect(ledger.ledger?.current?.id == journal.operation && ledger.ledger?.current?.state == .succeeded)
        #expect(try await f.flow.journal().phase == "completed")
        let repeated = try await f.flow.publish()
        #expect(repeated.receipt == result.receipt)
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }
    @Test func consumerValidationRefusesPublicationWithoutBackupAndOriginalRemainsUntouched() async throws {
        let f = try await fixture()
        let invoice = f.ids.node(64)
        _ = try await f.graph.transaction { try $0.patch(.init(id: invoice, properties: ["legacyCents": .set(.string("invalid"))])) }
        await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.transformAndSeal() }
        #expect(try await f.manager.backups.list(in: f.root.appendingPathComponent("Backups")).isEmpty)
        let obsolete = f.ids.node(65)
        #expect(try await f.graph.read { try $0.record(for: invoice)?.properties["legacyCents"] } == .string("invalid"))
        #expect(try await f.graph.read { try $0.record(for: obsolete) } != nil)
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }
    @Test func ledgerNetworkFailureDoesNotFalsifyCommittedPublication() async throws {
        var f = try await fixture()
        _ = try await f.flow.transformAndSeal()
        let receipt = try await f.flow.publish().receipt
        await f.server.setOffline(true)
        await #expect(throws: URLError.self) { try await f.flow.completeAfterConsumerVerification() }
        #expect(try await f.flow.journal().receipt == receipt)
        try await ConsumerMigrationExample.validate(f.graph, ids: f.ids, operation: f.flow.journal().operation)
        await f.server.setOffline(false)
        f = try await reopen(f)
        _ = try await f.flow.publish()
        try await f.flow.completeAfterConsumerVerification()
        #expect(try await f.manager.backups.list(in: f.root.appendingPathComponent("Backups")).count == 1)
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }
    @Test func lostBeginResultRecoversOnlyItsOwnDurableRequest() async throws {
        var f = try await fixture()
        await #expect(throws: ConsumerMigrationFailure.self) { try await f.flow.prepare(fault: .afterBegin) }
        let started = try await f.manager.graphLedger(for: f.ids.graph, configuration: f.config).ledger?.current?.id
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("consumer-migration.json").path))
        f = try await reopen(f)
        _ = try await f.flow.transformAndSeal()
        #expect(try await f.flow.journal().operation == started)
        _ = try await f.flow.publish(); try await f.flow.completeAfterConsumerVerification()
        #expect(try await f.flow.transformAndSeal() == false)
        #expect(try await f.flow.journal().phase == "completed")
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }
    @Test func foreignLedgerOperationIsNotAdoptedAndMalformedConsumerJournalIsRefused() async throws {
        let f = try await fixture()
        _ = try await f.manager.updateGraphLedger(for: f.ids.graph, configuration: f.config,
            mutation: .begin(kind: "other.consumer", phase: "running", information: Data("{}".utf8)))
        _ = try await f.manager.reconcileGraphLedger(for: f.ids.graph, configuration: f.config)
        await #expect(throws: ConsumerMigrationFailure.self) { try await f.flow.prepare() }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Working").path))
        let malformed = ConsumerMigrationJournal(format: 1, graphID: f.ids.graph, operation: UUID(), workspace: nil, phase: "committed", receipt: nil)
        try JSONEncoder().encode(malformed).write(to: f.root.appendingPathComponent("consumer-migration.json"))
        await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.journal() }
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }

    @Test func semanticValidationFailureAfterTransformationCreatesNoOriginalBackup() async throws {
        let f = try await fixture()
        await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.transformAndSeal(fault: .afterTransformation) }
        try await f.flow.close()
        let workspace = try await f.manager.openMigrationWorkspace(for: f.ids.graph, at: f.root.appendingPathComponent("Working"))
        let invoice = f.ids.node(64)
        _ = try await workspace.graph.transaction { try $0.patch(.init(id: invoice, properties: ["amountCents": .set(.integer(-1))])) }
        try await workspace.close()
        await #expect(throws: ConsumerMigrationFailure.self) { _ = try await f.flow.transformAndSeal() }
        #expect(try await f.manager.backups.list(in: f.root.appendingPathComponent("Backups")).isEmpty)
        #expect(try await f.graph.read { try $0.record(for: invoice)?.properties["legacyCents"] } == .string("1234"))
        #expect(try await f.flow.journal().phase == "prepared")
        try await close(f)
        try FileManager.default.removeItem(at: f.root)
    }

}
