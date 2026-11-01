import CoreData
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private struct LayoutSnapshot: Sendable {
    let storeID: String
    let fingerprint: String
    let record: GraphRecord
    let value: Int64
}
private struct LayoutIntent: Codable, Sendable, Equatable {
    let format: Int
    let operation: UUID
    let graph: GraphID
    let file: WorkspaceFileIdentity
    let sourceID: String
    let fingerprint: String
}
private struct LayoutReceipt: Codable, Sendable, Equatable {
    let intent: LayoutIntent
    let targetID: String
    let nodeID: GraphNodeID
}
private final class MigrationTestGate: @unchecked Sendable {
    let arrivals = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var armed = true
    private let semaphore = DispatchSemaphore(value: 0)
    func blockOnce() {
        guard lock.withLock({ let value = armed; armed = false; return value }) else { return }
        arrivals.continuation.yield(()); _ = semaphore.wait(timeout: .now() + 10)
    }
    func release() { semaphore.signal() }
}

/// A second typed recipe over an already native source, solely a contract fixture for the common runner.
@Suite(.timeLimit(.minutes(2))) struct GraphStoreMigrationTests {
    private let marker = "__graphevo_v2.syntheticLayoutReceipt"
    private func nativeID(_ context: NSManagedObjectContext) throws -> String {
        guard let coordinator = context.persistentStoreCoordinator, let store = coordinator.persistentStores.first,
              let identity = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String else { throw GraphStoreMigrationError.invalidReceipt }
        return identity
    }
    private func source(legacy: Bool = false) -> GraphStoreMigrationSource {
        .init(schema: GraphRuntimeSchema.nativeIdentity, legacyReadOnly: legacy) { context, id in
            try GraphCoordinatorFactory.adapter.initialize(context, id, false)
            try GraphCoordinatorFactory.validateGraph(context, id: id)
            return try self.nativeID(context)
        }
    }
    private func definition(artifact: String = "__graphevo_layout-v2.json", legacy: Bool = false,
                            badIdentity: Bool = false, wrongReceipt: Bool = false, oversizedIntent: Bool = false,
                            gate: MigrationTestGate? = nil) -> GraphStoreMigrationDefinition<LayoutSnapshot, LayoutIntent, LayoutReceipt> {
        let marker = marker
        @Sendable func read(_ context: NSManagedObjectContext, _ id: GraphID) throws -> LayoutReceipt? {
            let catalog = try GraphNativeIdentityDatabaseAdapter.database.catalog(context)
            if catalog.isEmpty {
                for entity in context.persistentStoreCoordinator!.managedObjectModel.entities {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity.name!); request.fetchLimit = 1
                    guard try context.fetch(request).isEmpty else { throw GraphStoreMigrationError.conflictingDestination }
                }
                return nil
            }
            let root = try GraphTypedStoreAdapter.controlRoot(context, id: id)
            guard let bytes = root[dynamicMember: marker] as? Data,
                  let result = try? JSONDecoder().decode(LayoutReceipt.self, from: bytes), result.intent.format == 1,
                  result.intent.graph == id, result.targetID == (try nativeID(context)) else { throw GraphStoreMigrationError.conflictingDestination }
            return result
        }
        return .init(source: source(legacy: legacy), targetSchemaIdentifier: GraphRuntimeSchema.nativeIdentity.identifier,
            backupArtifactName: artifact, inspect: { context, id, limits in
                try limits.validate()
                let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                guard session.nodes.count == 1, let pair = session.nodes.first,
                      let record = try session.record(pair.key), record.type == "Internal.LayoutFixture",
                      record.endpoints == .entity, record.tags.isEmpty, record.groups.isEmpty,
                      record.createdDate == Date(timeIntervalSince1970: 2000), record.properties.count == 1,
                      case .integer(let value) = record.properties["storage"], value < Int64.max else { throw GraphStoreMigrationError.unsupportedSource }
                let data = try GraphValueCodec.encode(.object(["id": .uuid(record.id.rawValue), "storage": .integer(value)]))
                return LayoutSnapshot(storeID: try self.nativeID(context), fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), record: record, value: value)
            }, sourceState: { .init(storeID: badIdentity ? "wrong-native-owner" : $0.storeID, fingerprint: $0.fingerprint) },
            makeIntent: { .init(format: 1, operation: $0, graph: $1, file: $2, sourceID: $3.storeID, fingerprint: $3.fingerprint) },
            encodeIntent: {
                if oversizedIntent { return Data(repeating: 1, count: 16 * 1024 + 1) }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode($0)
            }, readReceipt: { try read($0, $1) }, validateReceipt: { receipt, intent, snapshot in
                guard receipt.intent == intent, receipt.nodeID == snapshot.record.id else { throw GraphStoreMigrationError.invalidReceipt }
            }, apply: { context, intent, snapshot in
                if let existing = try read(context, intent.graph) {
                    guard existing.intent == intent else { throw GraphStoreMigrationError.conflictingDestination }
                    return existing
                }
                try GraphCoordinatorFactory.adapter.initialize(context, intent.graph, true)
                let session = try GraphTypedStoreAdapter.Session(context, intent.graph, database: true)
                GraphMutationMetadata.begin(context)
                try session.insert(GraphRecord(id: snapshot.record.id, type: snapshot.record.type,
                    properties: ["storage": .integer(snapshot.value + 1)], createdDate: snapshot.record.createdDate))
                try GraphMutationMetadata.finish(context, graphID: intent.graph, clock: { Date(timeIntervalSince1970: 3000) })
                let receipt = LayoutReceipt(intent: intent, targetID: try self.nativeID(context), nodeID: snapshot.record.id)
                let root = try GraphTypedStoreAdapter.controlRoot(context, id: intent.graph)
                root[dynamicMember: marker] = try JSONEncoder().encode(receipt)
                context.transactionAuthor = GraphSyncCheckpointAdapter.localAuthor
                gate?.blockOnce()
                if wrongReceipt { return LayoutReceipt(intent: intent, targetID: receipt.targetID, nodeID: .init(graphID: intent.graph)) }
                return receipt
            })
    }
    private func manager() -> GraphContextManager {
        let base = GraphCoordinatorFactory.adapter
        // Deliberately omit v1Conversion: the common runner and backup wiring must stand on their own.
        let adapter = GraphCoordinatorAdapter(graph: base.graph, sync: base.sync, migrationSource: source(),
            initializePolicy: base.initializePolicy, publication: base.publication, workspace: base.workspace,
            prepareWorkspace: base.prepareWorkspace, validateBackup: base.validateBackup, initialize: base.initialize)
        return .init(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: adapter)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationStructure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func seed(root: URL, name: String = "Source") async throws -> (GraphID, GraphNodeID, URL) {
        let id = GraphID(), source = root.appendingPathComponent(name + ".sqlite")
        // Keep source registration in its own bootstrap owner; never rebind a registered GraphID.
        let seedOwner = self.manager()
        let graph = try await seedOwner.createGraph(id: id, at: source), nodeID = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(GraphRecord(id: nodeID, type: "Internal.LayoutFixture",
            properties: ["storage": .integer(1)], createdDate: Date(timeIntervalSince1970: 2000))) }
        try await graph.close(); return (id, nodeID, source)
    }
    private func request(root: URL, source: URL, graphID: GraphID, target: String = "Target") -> GraphStoreMigrationRequest {
        .init(sourceURL: source, destinationURL: root.appendingPathComponent(target + ".sqlite"), graphID: graphID,
            operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Synthetic native layout migration")
    }
    @Test func nativeSourceRecipeUsesItsOwnTypesAndRecoversWithoutV1OrRepeatedApplication() async throws {
        let root = try directory(), m = manager(), (id, node, sourceURL) = try await seed(root: root)
        let request = request(root: root, source: sourceURL, graphID: id)
        let first = try await m.migrateStore(using: definition(), request: request)
        #expect(!first.cleanupPending && first.receipt.nodeID == node)
        #expect(first.receipt.intent.sourceID != first.receipt.targetID)
        let target = try await m.openGraph(id: id, at: request.destinationURL)
        #expect(try await target.read { try $0.record(for: node)?.properties["storage"] } == .integer(2))
        _ = try await target.transaction { try $0.patch(.init(id: node, properties: ["storage": .set(.integer(3))])) }
        try await target.close()
        let retry = try await manager().migrateStore(using: definition(), request: request)
        #expect(retry.receipt == first.receipt)
        let withoutNewArtifact = try await manager().migrateStore(using: definition(oversizedIntent: true), request: request)
        #expect(withoutNewArtifact.receipt == first.receipt)
        #expect(try await m.backups.list(in: request.backupRoot).count == 1)
        let opened = try await m.openGraph(id: id, at: request.destinationURL)
        #expect(try await opened.read { try $0.record(for: node)?.properties["storage"] } == .integer(3))
        try await opened.close()
        let original = try await manager().openGraph(id: id, at: sourceURL)
        #expect(try await original.read { try $0.record(for: node)?.properties["storage"] } == .integer(1))
        try await original.close()
        #expect(try await m.backups.verify(at: first.backupURL).manifest.nativeStoreID == first.receipt.intent.sourceID)
        try FileManager.default.removeItem(at: root)
    }
    @Test(arguments: ["wrong-source", "identity", "large-intent", "unsafe-artifact"])
    func invalidDefinitionIsRejectedBeforeBackupOrDestination(kind: String) async throws {
        let root = try directory(), m = manager(), (id, _, sourceURL) = try await seed(root: root)
        let request = request(root: root, source: sourceURL, graphID: id)
        let plan = definition(artifact: kind == "unsafe-artifact" ? "../escape.json" : "__graphevo_layout-v2.json",
            legacy: kind == "wrong-source", badIdentity: kind == "identity", oversizedIntent: kind == "large-intent")
        await #expect(throws: GraphStoreMigrationError.self) { try await m.migrateStore(using: plan, request: request) }
        #expect(!FileManager.default.fileExists(atPath: request.backupRoot.path))
        #expect(!FileManager.default.fileExists(atPath: request.destinationURL.path))
        try FileManager.default.removeItem(at: root)
    }
    @Test func invalidReturnedReceiptRollsBackApplicationEffectsAndRetainsOneReusableBackup() async throws {
        let root = try directory(), m = manager(), (id, node, sourceURL) = try await seed(root: root)
        let request = request(root: root, source: sourceURL, graphID: id)
        await #expect(throws: GraphStoreMigrationError.self) { try await m.migrateStore(using: definition(wrongReceipt: true), request: request) }
        let backup = try #require(try await m.backups.list(in: request.backupRoot).first)
        #expect(try await m.backups.retentionOwners(at: backup.url).contains(request.operationID))
        await #expect(throws: (any Error).self) { try await m.openGraph(id: id, at: request.destinationURL) }
        let result = try await m.migrateStore(using: definition(), request: request)
        #expect(result.receipt.nodeID == node && result.backupURL.resolvingSymlinksInPath() == backup.url.resolvingSymlinksInPath())
        #expect(try await m.backups.list(in: request.backupRoot).count == 1)
        #expect(try await m.backups.retentionOwners(at: backup.url).isEmpty)
        try FileManager.default.removeItem(at: root)
    }
    @Test func differentRecipesSharePerGraphAdmissionAndUnrelatedGraphsContinue() async throws {
        let root = try directory(), m = manager(), (id, _, sourceURL) = try await seed(root: root)
        let (otherID, _, otherURL) = try await seed(root: root, name: "OtherSource")
        let firstRequest = request(root: root, source: sourceURL, graphID: id), gate = MigrationTestGate()
        let first = Task { try await m.migrateStore(using: self.definition(gate: gate), request: firstRequest) }
        for await _ in gate.arrivals.stream { break }
        await #expect(throws: GraphStoreMigrationError.self) {
            try await m.migrateStore(using: self.definition(artifact: "__graphevo_another-recipe.json"), request: firstRequest)
        }
        await #expect(throws: (any Error).self) { try await m.openGraph(id: id, at: firstRequest.destinationURL) }
        let secondRequest = request(root: root, source: otherURL, graphID: otherID, target: "OtherTarget")
        let second = try await m.migrateStore(using: definition(), request: secondRequest)
        #expect(second.receipt.intent.graph == otherID)
        gate.release(); _ = try await first.value
        try FileManager.default.removeItem(at: root)
    }
}
