import CloudKit
import Foundation
import Testing
import os
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private extension ActivationServer {
    func descriptors(_ prefix: String?) throws -> [GraphPrivateGraphDescriptor] {
        try records.values.filter { value in
            value.recordType == GraphCloudGraphDescriptor.recordType && (prefix.map { value.zone.name.hasPrefix($0) } ?? true)
        }.map { value in .init(zone: value.zone, archive: try #require(value.recordArchive)) }
    }
    func publishDescriptor(_ binding: GraphCloudBinding, files: Bool) throws {
        try injectRecord(GraphCloudGraphDescriptor.encode(binding, supportsFiles: files), route: binding)
    }
    func sendPrivate(_ batch: GraphCloudOutgoingBatch, directory: URL) async throws -> GraphCloudSentReceipt {
        sends += 1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved: [GraphCloudIncoming] = [], deleted: [String] = []
        for item in batch.items {
            guard let archive = item.recordArchive else {
                records.removeValue(forKey: batch.zone.name + item.recordName); deleted.append(item.recordName); continue
            }
            let native = try GraphCloudRecordCodec.restore(archive)
            if let reference = item.assetReference {
                let spool = try GraphCloudAssetSpool(root: #require(batch.assetRoot))
                if reference.isFile == true {
                    let source = try await spool.fileURL(reference, role: .outgoing, identity: reference.identity,
                        binding: reference.binding, recordName: item.recordName, storeID: reference.storeID, epoch: reference.epoch)
                    // The synthetic server owns this copy independently of sender cleanup.
                    let file = directory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: source, to: file)
                    native["asset"] = CKAsset(fileURL: file)
                } else {
                    native["asset"] = try await spool.read(reference, role: .outgoing, identity: reference.identity,
                        binding: reference.binding, recordName: item.recordName, storeID: reference.storeID, epoch: reference.epoch) as CKRecordValue
                }
            }
            let incoming = try GraphCloudRecordCodec.archive(native, scope: .private, portableAsset: true)
            records[batch.zone.name + item.recordName] = incoming; saved.append(incoming)
        }
        return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: [])
    }
    nonisolated func privateAdapter(root: URL) -> GraphCloudAdapter {
        var value = adapter
        value.privateGraphs = .init(list: { _, prefix in try await self.descriptors(prefix) },
            publish: { config, binding in try await self.publishDescriptor(binding, files: config.supportsFiles) })
        let activation = GraphCloudActivationService(ensureZone: service.ensureZone, fetch: service.fetch, save: service.save,
            inventory: { config, identity, binding, _ in
            var inventory = try GraphCloudActivationInventory(sessionDirectory: config.directory)
            let spool = try GraphCloudAssetSpool(root: config.directory.appendingPathComponent("GraphEvoCloudAssets"))
            let namespace = UUID()
            for incoming in try await self.inventory(binding) {
                try inventory.store(GraphCloudRecordCodec.freeze(incoming, identity: identity, binding: binding, spool: spool, namespace: namespace))
            }
            return inventory
        })
        value = GraphCloudAdapter(privateGraphs: value.privateGraphs, activation: activation,
            account: value.account, make: { _, _, _, callback in
                GraphCloudDriver(fetch: { _ in }, cancel: {}, send: { batch in
                    await callback(.sent(try await self.sendPrivate(batch, directory: root)))
                })
            })
        return value
    }
}

private final class PrivateReplicaFault: Sendable {
    private let armed: OSAllocatedUnfairLock<Bool>
    init(_ armed: Bool) { self.armed = OSAllocatedUnfairLock(initialState: armed) }
    func consume() -> Bool { armed.withLock { value in let result = value; value = false; return result } }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct GraphPrivateGraphTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PrivateGraph-" + UUID().uuidString) }
    private func manager() -> GraphContextManager {
        GraphContextManager(schema: GraphRuntimeSchema.attachmentFiles, adapter: GraphCoordinatorFactory.makeAdapter(files: true))
    }
    @Test(arguments: [false, true])
    func ordinaryPrivateGraphRecoversWithoutV1AuthorityOrOutgoingFeedback(interruptBeforeCompletion: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = ActivationServer(), first = manager(), id = GraphID()
        var config = GraphCloudConfiguration(containerIdentifier: "iCloud.private." + UUID().uuidString,
            environment: .development, directory: root.appendingPathComponent("Cloud"))
        config.supportsFiles = true
        let graph = try await first.createGraph(id: id, at: root.appendingPathComponent("Source.sqlite"))
        let note = graph.makeNodeID(), edge = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "Note",
            properties: ["title": .string("Private"), "collection": .array([.integer(7)])],
            attachments: ["cover": .init(data: Data(repeating: 9, count: 1024))])) }
        let source = root.appendingPathComponent("Input.bin"), bytes = Data(repeating: 63, count: 128 * 1024)
        try bytes.write(to: source)
        let file = try await graph.importFile(from: source) { scope, file in
            try scope.insert(GraphRecord(id: edge, type: "NoteFile", endpoints: .relationship(subject: note, object: file.id)))
        }
        _ = try await first.startCloudSession(config, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        let zone = GraphCloudZone(scope: .private, owner: "owner", name: "Notes-" + UUID().uuidString)
        try await first.bindCloudZone(zone, to: id, configuration: config)
        for _ in 0..<8 {
            let sent = try await first.sendCloudChanges(for: id, configuration: config)
            #expect(sent.failures.isEmpty && sent.transportError == nil)
            if try await graph.collectSyncChanges() == 0 { break }
        }
        let expected = try await graph.read { try $0.record(for: note) }
        let sends = await server.sends
        try await graph.close(); try await first.stopCloudSession(config)
        var peerAdapter = GraphCoordinatorFactory.makeAdapter(files: true)
        let nativeReplica = try #require(peerAdapter.privateReplica), fault = PrivateReplicaFault(interruptBeforeCompletion)
        peerAdapter.privateReplica = GraphPrivateReplicaAdapter(read: nativeReplica.read, prepare: nativeReplica.prepare,
            complete: { context, id, operation in
                if fault.consume() { throw URLError(.cancelled) }
                try nativeReplica.complete(context, id, operation)
            }, ids: nativeReplica.ids)
        var peer = GraphContextManager(schema: GraphRuntimeSchema.attachmentFiles, adapter: peerAdapter)
        var peerConfig = GraphCloudConfiguration(containerIdentifier: config.containerIdentifier, environment: .development,
            directory: root.appendingPathComponent("PeerCloud"))
        peerConfig.supportsFiles = true
        _ = try await peer.startCloudSession(peerConfig, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        let session = try await peer.cloud(peerConfig)
        let discovery = try await session.discoverPrivateGraphs(prefix: "Notes-")
        #expect(discovery.issues.isEmpty)
        let reference = try #require(discovery.graphs.first)
        #expect(reference.id == id && reference.supportsFiles)
        let stale = GraphCloudPrivateGraph(supportsFiles: reference.supportsFiles, binding: reference.binding,
            identity: .init(container: config.containerIdentifier, environment: .development, account: "different-account"))
        await #expect(throws: GraphCloudError.accountChanged) {
            _ = try await peer.openPrivateGraph(stale, at: root.appendingPathComponent("WrongAccount.sqlite"), configuration: peerConfig)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("WrongAccount.sqlite").path))
        if interruptBeforeCompletion {
            await #expect(throws: URLError.self) {
                _ = try await peer.openPrivateGraph(reference, at: root.appendingPathComponent("Replica.sqlite"), configuration: peerConfig)
            }
            let blocked = try await peer.openGraph(id: id, at: root.appendingPathComponent("Replica.sqlite"))
            do { _ = try await blocked.read { _ in true }; Issue.record("Incomplete replica admitted a read") }
            catch GraphStoreError.permissionDenied {}
            do { try await blocked.transaction { _ in () }; Issue.record("Incomplete replica admitted a write") }
            catch GraphStoreError.writesSuspended {}
            try await blocked.close(); try await peer.stopCloudSession(peerConfig)
            peer = manager()
            _ = try await peer.startCloudSession(peerConfig, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        }
        let recovered = try await peer.openPrivateGraph(reference, at: root.appendingPathComponent("Replica.sqlite"), configuration: peerConfig)
        #expect(try await recovered.read { try $0.record(for: note) } == expected)
        #expect(try await recovered.read { try $0.record(for: edge)?.endpoints } == .relationship(subject: note, object: file.id))
        #expect(try await recovered.withFileURL(file.id) { try Data(contentsOf: $0) } == bytes)
        #expect(try await recovered.collectSyncChanges() == 0)
        #expect(await server.sends == sends)
        try await recovered.close()
        let reopened = try await peer.openPrivateGraph(reference, at: root.appendingPathComponent("Replica.sqlite"), configuration: peerConfig)
        #expect(try await reopened.read { try $0.record(for: note) } == expected)
        try await reopened.close(); try await peer.stopCloudSession(peerConfig)
    }

    @Test func discoveryReportsUnsupportedDescriptorAndDoesNotInventGraphIDs() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = ActivationServer(), context = manager()
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.discovery." + UUID().uuidString,
            environment: .development, directory: root.appendingPathComponent("Cloud"))
        let good = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "Notes-good"), graphID: GraphID())
        let bad = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "Notes-bad"), graphID: GraphID())
        try await server.publishDescriptor(good, files: false)
        let invalid = GraphCloudGraphDescriptor.encode(bad); invalid["format"] = NSNumber(value: 999)
        try await server.injectRecord(invalid, route: bad)
        _ = try await context.startCloudSession(config, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        let session = try await context.cloud(config)
        let result = try await session.discoverPrivateGraphs(prefix: "Notes-")
        #expect(result.graphs.map(\.id) == [good.graphID])
        #expect(result.issues.map(\.zoneName) == [bad.zone.name])
        #expect(try await session.discoverPrivateGraphs(prefix: "Other-").graphs.isEmpty)
        let duplicate = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "Notes-duplicate"), graphID: good.graphID)
        try await server.publishDescriptor(duplicate, files: false)
        let ambiguous = try await session.discoverPrivateGraphs(prefix: "Notes-")
        #expect(ambiguous.graphs.isEmpty)
        #expect(ambiguous.issues.contains { $0.reason == .invalidDescriptor })
        try await context.stopCloudSession(config)
    }
    @Test func recoveryRefusesPopulatedUnmarkedStoreBeforeAccountClaim() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let context = manager(), server = ActivationServer(), id = GraphID()
        let target = root.appendingPathComponent("Populated.sqlite")
        let graph = try await context.createGraph(id: id, at: target), note = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "Note", properties: ["title": .string("Keep")])) }
        try await graph.close()
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.populated." + UUID().uuidString,
            environment: .development, directory: root.appendingPathComponent("Cloud"))
        let route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "Notes-existing"), graphID: id)
        try await server.publishDescriptor(route, files: false)
        _ = try await context.startCloudSession(config, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        let session = try await context.cloud(config), discovery = try await session.discoverPrivateGraphs(prefix: "Notes-")
        let reference = try #require(discovery.graphs.first)
        await #expect(throws: GraphCloudSharingError.nonemptyReplica) {
            _ = try await context.openPrivateGraph(reference, at: target, configuration: config)
        }
        let preserved = try await context.openGraph(id: id, at: target)
        #expect(try await preserved.read { try $0.record(for: note)?.properties["title"] } == .string("Keep"))
        #expect(try await preserved.cloudAccountState == .localOnly)
        try await preserved.close(); try await context.stopCloudSession(config)
    }

    @Test func sessionFormatTenIsRefusedWithoutRewritingTheDocument() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = GraphCloudConfiguration(containerIdentifier: "iCloud.old-session." + UUID().uuidString,
            environment: .development, directory: root)
        var document = GraphCloudDocument(container: config.containerIdentifier, environment: .development, account: "synthetic-activation-account")
        document.format = 10
        let bytes = try JSONEncoder().encode(document), url = root.appendingPathComponent("session.json")
        try bytes.write(to: url)
        let server = ActivationServer()
        await #expect(throws: GraphCloudError.invalidState) {
            _ = try await GraphCloudSession.open(config, adapter: server.privateAdapter(root: root.appendingPathComponent("Server")))
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

}
