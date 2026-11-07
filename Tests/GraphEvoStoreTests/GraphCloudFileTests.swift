import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

@available(iOS 17, macOS 14, *)
private actor FileBus {
    let root: URL
    var records: [String: GraphCloudIncoming] = [:]
    var conflict: GraphCloudIncoming?
    init(root: URL) { self.root = root }
    func conflictOnce(_ value: GraphCloudIncoming) { conflict = value }
    func inject(_ value: GraphCloudIncoming) { records[value.recordName!] = value }
    func fetch(_ zones: [GraphCloudZone]) -> [GraphCloudIncoming] { records.values.filter { zones.contains($0.zone) } }

    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        let provider = GraphCloudNativeOutbox()
        try await provider.begin(batch)
        do {
            let zone = CKRecordZone.ID(zoneName: batch.zone.name, ownerName: batch.zone.owner)
            let offered = try #require(try await provider.next(.init(scope: .zoneIDs([zone]))))
            var saved: [GraphCloudIncoming] = [], failures: [GraphCloudRecordFailure] = []
            for record in offered.recordsToSave {
                if let conflict, conflict.recordName == record.recordID.recordName {
                    self.conflict = nil
                    failures.append(.init(recordName: record.recordID.recordName,
                        code: CKError.Code.serverRecordChanged.rawValue, serverRecord: conflict))
                    continue
                }
                if let asset = record["asset"] as? CKAsset, let source = asset.fileURL {
                    let destination = root.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: source, to: destination)
                    record["asset"] = CKAsset(fileURL: destination)
                }
                let incoming = try GraphCloudRecordCodec.archive(record, scope: batch.zone.scope)
                saved.append(incoming)
                records[record.recordID.recordName] = incoming
            }
            for id in offered.recordIDsToDelete {
                records[id.recordName] = .init(kind: .recordDeleted, zone: batch.zone,
                    recordName: id.recordName, recordType: GraphCloudNodeCodec.recordType)
            }
            try await provider.finish()
            return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved,
                         deletedNames: offered.recordIDsToDelete.map(\.recordName), failures: failures)
        } catch { try? await provider.finish(); throw error }
    }

    nonisolated var adapter: GraphCloudAdapter {
        GraphCloudAdapter(account: { _ in "file-account" }, make: { [self] _, _, _, receive in
            GraphCloudDriver(fetch: { zones in await receive(.incoming(self.fetch(zones))) }, cancel: {},
                send: { batch in await receive(.sent(try self.send(batch))) })
        })
    }
}

@Suite(.timeLimit(.minutes(3))) struct GraphCloudFileTests {
    @available(iOS 17, macOS 14, *)
    private struct Fixture {
        let root: URL
        let config: GraphCloudConfiguration
        let manager: GraphContextManager
        let graph: GraphStore
        let binding: GraphCloudTransportBinding
        func close() async throws {
            try await graph.close()
            try await manager.stopCloudSession(config)
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudFile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @available(iOS 17, macOS 14, *)
    private func fixture(_ root: URL, bus: FileBus, id: GraphID, container: String,
                         scope: GraphCloudScope = .private, schema: StoreSchema = GraphRuntimeSchema.localFiles,
                         existing: Bool = false) async throws -> Fixture {
        let manager = GraphContextManager(registry: StoreRegistry(), schema: schema, adapter: GraphCoordinatorFactory.adapter)
        let store = root.appendingPathComponent("Graph.sqlite")
        let graph = try await existing ? manager.openGraph(id: id, at: store) : manager.createGraph(id: id, at: store)
        var config = GraphCloudConfiguration(containerIdentifier: container, environment: .development,
                                              directory: root.appendingPathComponent("Cloud"))
        config.supportsFiles = schema.identifier == GraphFileDisk.schemaIdentifier
        _ = try await manager.startCloudSession(config, adapter: bus.adapter)
        let route = GraphCloudBinding(zone: .init(scope: scope, owner: "owner", name: "file-zone"), graphID: id)
        try await manager.bindCloudZone(route.zone, to: id, configuration: config)
        return Fixture(root: root, config: config, manager: manager, graph: graph,
            binding: .init(identity: .init(container: container, environment: .development, account: "file-account"), route: route))
    }

    @available(iOS 17, macOS 14, *)
    @Test func frozenFileSurvivesReplacementReclaimRestartAndFreshReplica() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base), id = GraphID(), container = "iCloud.file." + UUID().uuidString
        let senderRoot = base.appendingPathComponent("Sender"), peerRoot = base.appendingPathComponent("Peer")
        let sender = try await fixture(senderRoot, bus: bus, id: id, container: container)
        let source = base.appendingPathComponent("Large.bin")
        try Data().write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 25 * 1024 * 1024)
        try writer.close()
        let file = try await sender.graph.importFile(from: source)
        let owner = sender.graph.makeNodeID(), edge = sender.graph.makeNodeID()
        try await sender.graph.transaction {
            try $0.insert(GraphRecord(id: owner, type: "document"))
            try $0.insert(GraphRecord(id: edge, type: "document.file", endpoints: .relationship(subject: owner, object: file.id)))
            _ = try $0.patch(GraphRecordPatch(id: file.id, addingTags: ["retained"], addingGroups: ["documents"]))
        }
        let frozen = try await sender.graph.prepareTransport(sender.binding)
        let item = try #require(frozen.items.first { $0.change.id == file.id })
        #expect(item.assetReference?.isFile == true)
        #expect(item.assetReference?.byteCount == 25 * 1024 * 1024)
        #expect(try JSONEncoder().encode(frozen).count < 100_000)
        let backupRoot = base.appendingPathComponent("Backup")
        _ = try await sender.graph.copyLocalFileGraph(into: backupRoot)
        try Data("replacement".utf8).write(to: source)
        let replacement = try await sender.graph.replaceFile(file, from: source)
        #expect(try await sender.graph.reclaimFiles() == 1)
        try FileManager.default.removeItem(at: source)
        try await sender.close()

        let backup = try await fixture(backupRoot, bus: bus, id: id, container: container, existing: true)
        #expect(try await backup.graph.file(file.id) == file)
        #expect(try await backup.graph.prepareTransport(backup.binding) == frozen)
        try await backup.close()
        let reopened = try await fixture(senderRoot, bus: bus, id: id, container: container, existing: true)
        let recovered = try await reopened.graph.prepareTransport(reopened.binding)
        #expect(recovered == frozen)
        let first = try await reopened.manager.sendCloudChanges(for: id, configuration: reopened.config)
        #expect(first.failures.isEmpty)
        let second = try await reopened.manager.sendCloudChanges(for: id, configuration: reopened.config)
        #expect(second.failures.isEmpty)
        try await reopened.close()
        let peer = try await fixture(peerRoot, bus: bus, id: id, container: container)
        _ = try await peer.manager.fetchCloudChanges(.private, configuration: peer.config)
        try await peer.close()
        let peerReopened = try await fixture(peerRoot, bus: bus, id: id, container: container, existing: true)
        _ = try await peerReopened.manager.applyCloudInbox(for: id, configuration: peerReopened.config)
        #expect(try await peerReopened.graph.file(file.id) == replacement)
        #expect(try await peerReopened.graph.withFileURL(file.id) { try Data(contentsOf: $0) } == Data("replacement".utf8))
        let record = try await peerReopened.graph.read { try $0.record(for: file.id) }
        #expect(record?.file == replacement)
        #expect(record?.tags == ["retained"])
        #expect(record?.groups == ["documents"])
        #expect(try await peerReopened.graph.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: owner, object: file.id))
        try await peerReopened.close()
        let deleting = try await fixture(senderRoot, bus: bus, id: id, container: container, existing: true)
        try await deleting.graph.deleteFile(file.id)
        _ = try await deleting.manager.sendCloudChanges(for: id, configuration: deleting.config)
        try await deleting.close()
        let observing = try await fixture(peerRoot, bus: bus, id: id, container: container, existing: true)
        try await observing.manager.fetchCloudChanges(.private, configuration: observing.config)
        _ = try await observing.manager.applyCloudInbox(for: id, configuration: observing.config)
        #expect(try await observing.graph.file(file.id) == nil)
        try await observing.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func graphDescriptorRequiresFileCapableReaderAndOversizeFileIsRefusedBeforeCopy() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "zone"), graphID: GraphID())
        let descriptor = GraphCloudGraphDescriptor.encode(route, supportsFiles: true)
        #expect(throws: GraphCloudDiscoveryError.unsupportedDescriptor) {
            try GraphCloudGraphDescriptor.decode(descriptor, zone: route.zone)
        }
        #expect(try GraphCloudGraphDescriptor.decode(descriptor, zone: route.zone, supportsFiles: true) == route.graphID)
        let source = base.appendingPathComponent("TooLarge")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: GraphCloudAsset.maximumNativeByteCount + 1)
        try handle.close()
        let spool = try GraphCloudAssetSpool(root: base.appendingPathComponent("GraphEvoCloudAssets"))
        #expect(throws: GraphCloudError.assetSizeLimitExceeded) {
            try spool.stageFileBlocking(from: source, role: .incoming, namespace: UUID(),
                identity: .init(container: "iCloud.file", environment: .development, account: "account"),
                binding: route, recordName: "node.fixture")
        }
    }
    @available(iOS 17, macOS 14, *)
    @Test func corruptIncomingFileRetainsInboxAndPreviousRevisionUntilRecovered() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base), id = GraphID(), container = "iCloud.file." + UUID().uuidString
        let sender = try await fixture(base.appendingPathComponent("Sender"), bus: bus, id: id, container: container)
        let source = base.appendingPathComponent("source")
        try Data("previous".utf8).write(to: source)
        let original = try await sender.graph.importFile(from: source)
        _ = try await sender.manager.sendCloudChanges(for: id, configuration: sender.config)
        try await sender.close()
        let peer = try await fixture(base.appendingPathComponent("Peer"), bus: bus, id: id, container: container)
        try await peer.manager.fetchCloudChanges(.private, configuration: peer.config)
        _ = try await peer.manager.applyCloudInbox(for: id, configuration: peer.config)
        let replacementBytes = Data("replacement".utf8)
        let replacementSource = base.appendingPathComponent("remote")
        try replacementBytes.write(to: replacementSource)
        let replacement = try GraphFile(id: original.id, name: "remote.bin", contentType: "public.data",
            byteCount: Int64(replacementBytes.count),
            sha256: SHA256.hash(data: replacementBytes).map { String(format: "%02x", $0) }.joined(), revision: UUID())
        let record = try GraphRecord(id: original.id, type: GraphFile.nodeType, endpoints: .file, file: replacement)
        let native = try GraphCloudNodeCodec.encode(record, binding: peer.binding.route)
        native["asset"] = CKAsset(fileURL: replacementSource)
        let remote = try GraphCloudRecordCodec.archive(native, scope: .private)
        #expect(throws: GraphCloudError.invalidState) { try JSONEncoder().encode(remote) }
        await bus.inject(remote)
        try await peer.manager.fetchCloudChanges(.private, configuration: peer.config)
        let session = try await peer.manager.cloud(peer.config)
        let inbox = try await session.incoming(for: peer.binding.route.zone, limit: 100)
        let reference = try #require(inbox.compactMap { $0.change.assetReference }.first)
        let retained = peer.config.directory.appendingPathComponent("GraphEvoCloudAssets")
            .appendingPathComponent(reference.namespace.uuidString).appendingPathComponent(reference.file.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retained.path)
        let tamper = try FileHandle(forWritingTo: retained)
        try tamper.write(contentsOf: Data([0xFF]))
        try tamper.close()
        await #expect(throws: GraphFileError.corruptContent) {
            try await peer.manager.applyCloudInbox(for: id, configuration: peer.config)
        }
        #expect(try await peer.graph.file(original.id) == original)
        #expect(try await session.incoming(for: peer.binding.route.zone, limit: 100).count == inbox.count)
        try replacementBytes.write(to: retained)
        _ = try await peer.manager.applyCloudInbox(for: id, configuration: peer.config)
        #expect(try await peer.graph.file(original.id) == replacement)
        #expect(try await peer.graph.withFileURL(original.id) { try Data(contentsOf: $0) } == replacementBytes)
        #expect(!FileManager.default.fileExists(atPath: retained.path))
        try await peer.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func serverConflictImportsFileAndTagGroupRemovalKeepsItsPhysicalKind() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base), id = GraphID()
        let fixture = try await fixture(base.appendingPathComponent("Store"), bus: bus, id: id,
                                        container: "iCloud.file." + UUID().uuidString)
        let source = base.appendingPathComponent("local")
        try Data("local".utf8).write(to: source)
        let file = try await fixture.graph.importFile(from: source)
        try await fixture.graph.transaction {
            _ = try $0.patch(GraphRecordPatch(id: file.id, addingTags: ["old"], addingGroups: ["old"]))
        }
        _ = try await fixture.manager.sendCloudChanges(for: id, configuration: fixture.config)
        try await fixture.graph.transaction {
            _ = try $0.patch(GraphRecordPatch(id: file.id, removingTags: ["old"], removingGroups: ["old"]))
        }
        let attempt = try await fixture.graph.prepareTransport(fixture.binding)
        #expect(attempt.items.first?.change.nativeKind == "ManagedGraphFile")
        let remoteSource = base.appendingPathComponent("remote")
        let bytes = Data("server".utf8)
        try bytes.write(to: remoteSource)
        let remoteMetadata = try GraphFile(id: file.id, name: "remote", contentType: "public.data",
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            revision: UUID())
        let native = try GraphCloudNodeCodec.encode(
            GraphRecord(id: file.id, type: GraphFile.nodeType, endpoints: .file, tags: ["server"], file: remoteMetadata),
            binding: fixture.binding.route, modifiedAt: Date())
        native["asset"] = CKAsset(fileURL: remoteSource)
        await bus.conflictOnce(try GraphCloudRecordCodec.archive(native, scope: .private))
        try await fixture.graph.setConflictPolicy(.cloudWins)
        let report = try await fixture.manager.sendCloudChanges(for: id, configuration: fixture.config)
        #expect(report.resolvedConflicts == 1)
        #expect(try await fixture.graph.file(file.id) == remoteMetadata)
        #expect(try await fixture.graph.withFileURL(file.id) { try Data(contentsOf: $0) } == bytes)
        #expect(try await fixture.graph.read { try $0.record(for: file.id)?.tags } == ["server"])
        try await fixture.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func publicFileContextSelectsCapableCloudConfiguration() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base)
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.localFiles,
            adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID())
        let context = GraphContext(manager: manager, adapter: bus.adapter)
        let graph = try await context.createGraph(id: GraphID(), at: base.appendingPathComponent("Graph.sqlite"))
        let config = try GraphCloudConnectionConfiguration(containerIdentifier: "iCloud.file." + UUID().uuidString,
            environment: .development, directory: base.appendingPathComponent("Cloud"))
        let connection = try await context.connectCloud(using: config)
        let observation = try await connection.observeState()
        for try await event in observation {
            if case .ready = event { break }
            if case .failed = event { Issue.record("File-capable connection failed"); break }
        }
        let native = try await connection.sharingConfiguration()
        #expect(native.supportsFiles)
        try await connection.bindPrivateGraph(graph, zoneName: "files")
        try await connection.close()
        try await graph.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func sharedScopeImportsFileWhileReadOnlyParticipantCannotReplaceIt() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base), id = GraphID(), container = "iCloud.file." + UUID().uuidString
        let sender = try await fixture(base.appendingPathComponent("Sender"), bus: bus, id: id,
                                       container: container, scope: .shared)
        let source = base.appendingPathComponent("source")
        try Data("shared file".utf8).write(to: source)
        let file = try await sender.graph.importFile(from: source)
        _ = try await sender.manager.sendCloudChanges(for: id, configuration: sender.config)
        try await sender.close()
        let participant = try await fixture(base.appendingPathComponent("Participant"), bus: bus, id: id,
                                             container: container, scope: .shared)
        _ = try await participant.graph.participantAccess(.init(binding: participant.binding.route, account: "file-account",
            permission: .readOnly, accepted: true, identity: participant.binding.identity, generation: UUID()))
        try await participant.manager.fetchCloudChanges(.shared, configuration: participant.config)
        _ = try await participant.manager.applyCloudInbox(for: id, configuration: participant.config)
        #expect(try await participant.graph.file(file.id) == file)
        #expect(try await participant.graph.withFileURL(file.id) { try Data(contentsOf: $0) } == Data("shared file".utf8))
        do {
            _ = try await participant.graph.replaceFile(file, from: source)
            Issue.record("A read-only participant replaced a file.")
        } catch GraphStoreError.permissionDenied { }
        #expect(try await participant.graph.file(file.id) == file)
        try await participant.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test func migratedLocalS04GraphCanPublishItsExistingRecords() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = FileBus(root: base), id = GraphID()
        let originalContext = GraphContext()
        let source = base.appendingPathComponent("S04.sqlite")
        let original = try await originalContext.createGraph(id: id, at: source)
        let node = original.makeNodeID()
        try await original.transaction { try $0.insert(GraphRecord(id: node, type: "existing")) }
        #expect(try await original.collectSyncChanges() == 1)
        try await original.close()
        let target = base.appendingPathComponent("Migrated")
        _ = try await GraphContext.migrateClosedS04Store(from: source, into: target)
        let migrated = try await fixture(target, bus: bus, id: id, container: "iCloud.file." + UUID().uuidString, existing: true)
        let batch = try await migrated.graph.prepareTransport(migrated.binding)
        #expect(batch.items.map(\.change.id) == [node])
        try await migrated.close()
    }

}
