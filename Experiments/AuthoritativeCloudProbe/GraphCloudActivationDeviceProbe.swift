import CloudKit
import CoreData
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

/// Exported into the external signed host only; never part of the normal product.
@available(iOS 17, macOS 14, *)
public actor GraphCloudActivationDeviceProbe {
    private struct Failure: Error {}
    private struct Proof: Codable {
        let sourceDigest: Data
        let nodeIDs: [GraphNodeID]
    }
    private var retainedManager: GraphContextManager?
    private var retainedGraph: GraphStore?
    public init() {}

    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        guard container == "iCloud.com.valerioburiani.GraphCKDemo",
              ["prepare", "seed", "publish", "verify", "recover-peer", "refresh-peer", "verify-account", "update-owner"].contains(stage),
              ["owner", "peer", "fresh", "contender"].contains(replica),
              stage == "verify-account" ||
                (["prepare", "seed"].contains(stage) && ["owner", "contender"].contains(replica)) ||
                (["publish", "verify", "update-owner"].contains(stage) && replica == "owner") ||
                (["recover-peer", "refresh-peer"].contains(stage) && ["peer", "fresh"].contains(replica)) else { throw Failure() }
        let root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        let id = GraphID(rawValue: run), target = root.appendingPathComponent("S04.sqlite"), source = root.appendingPathComponent("Legacy.sqlite")
        let config = GraphCloudConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Cloud"))
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "GE2-MF10-" + run.uuidString)
        let manager = GraphContextManager(schema: GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        retainedManager = manager
        if stage == "verify-account" {
            _ = try await manager.startCloudSession(config)
            let account = try await manager.cloudSharingIdentity(config)
            let digest = Data(SHA256.hash(data: Data((run.uuidString + account).utf8)))
            try digest.write(to: root.appendingPathComponent("account.digest"), options: .withoutOverwriting)
            return ["Read-only salted account comparison retained privately; no graph opened or cloud data changed."]
        }
        if stage == "recover-peer" || stage == "refresh-peer" {
            let graph: GraphStore
            if stage == "recover-peer" {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure() }
                _ = try await manager.startCloudSession(config)
                let recovered = try await manager.openCloudReplica(id: id, at: target, zone: zone, configuration: config)
                graph = try recovered.opening.get()
                guard recovered.status.phase == .published else { throw Failure() }
            } else {
                graph = try await manager.openGraph(id: id, at: target)
                _ = try await manager.startCloudSession(config)
                try await manager.fetchCloudChanges(.private, configuration: config)
                _ = try await manager.applyCloudInbox(for: id, configuration: config)
            }
            retainedGraph = graph
            guard try await graph.validateIntegrity() == 6,
                  try await graph.collectSyncChanges() == 0 else { throw Failure() }
            try await Self.checkCurrentServer(graph: graph, zone: zone, configuration: config)
            return ["A genuinely empty S04 peer recovered complete current IDs, bodies, topology and 2-MiB attachment.",
                    "Full integrity and empty outgoing work verified; owner must remain live on its independent device."]
        }
        let graph: GraphStore
        var operationBytes = run.uuid
        if replica == "contender" { operationBytes.15 ^= 73 }
        let operation = UUID(uuid: operationBytes)
        let proofURL = root.appendingPathComponent("proof.json")
        if stage == "prepare" {
            guard !FileManager.default.fileExists(atPath: target.path), !FileManager.default.fileExists(atPath: source.path) else { throw Failure() }
            try await Self.seed(source)
            let digest = Data(SHA256.hash(data: try Data(contentsOf: source)))
            let converted = try await manager.openGraph(convertingLocalV1: .init(sourceURL: source, destinationURL: target,
                graphID: id, operationID: operation, backupRoot: root.appendingPathComponent("Backups"), reason: "MF10 synthetic local source"))
            graph = try converted.opening.get()
            let ownerID = try requireValue(converted.conversion.receipt.nodeIDs.values.first)
            let attachment = try GraphAttachmentPayload(id: graph.makeNodeID(), ownerID: ownerID, fileName: "proof.bin", contentType: "public.data", data: Data(repeating: 41, count: 2 * 1024 * 1024))
            let attachmentID = try await graph.transaction { try $0.insert(attachment) }
            let proof = Proof(sourceDigest: digest, nodeIDs: Array(converted.conversion.receipt.nodeIDs.values) + [attachmentID])
            try JSONEncoder().encode(proof).write(to: proofURL, options: .withoutOverwriting)
            _ = try await manager.startCloudSession(config)
            let prepared = try await manager.prepareCloudActivation(for: id, activationID: operation, zone: zone, configuration: config,
                declaration: .init(sourceSelection: "Only this synthetic source", completeness: "Five explicitly constructed primitives",
                    stoppedWriters: "Legacy writer detached", returningClients: "No other legacy fixture writers"))
            guard prepared.phase == .prepared, prepared.recordCount == 6 else { throw Failure() }
        } else {
            graph = try await manager.openGraph(id: id, at: target)
            let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: proofURL))
            guard Data(SHA256.hash(data: try Data(contentsOf: source))) == proof.sourceDigest else { throw Failure() }
            _ = try await manager.startCloudSession(config)
            if stage == "seed" || stage == "publish" {
                do { try await graph.transaction { _ in () }; throw Failure() }
                catch GraphStoreError.writesSuspended { }
                let result = try await manager.advanceCloudActivation(for: id, configuration: config)
                if replica == "contender" {
                    guard result.operationError as? GraphCloudActivationError == .authorityConflict, result.status.phase == .conflict else { throw Failure() }
                } else {
                    if let failure = result.operationError { throw failure }
                    guard result.status.phase == (stage == "seed" ? .seeding : .published) else { throw Failure() }
                }
            } else if stage == "update-owner" {
                let invoice = try await graph.read { scope in
                    try scope.withContext { context, _ in
                        let session = try GraphTypedStoreAdapter.Session(context, id, database: true)
                        guard let invoice = session.nodes.first(where: { $0.value.type == "Invoice" })?.key else { throw Failure() }
                        return invoice
                    }
                }
                _ = try await graph.transaction { try $0.patch(.init(id: invoice, properties: ["later": .set(.integer(2))])) }
                let sent = try await manager.sendCloudChanges(for: id, configuration: config)
                guard sent.transportError == nil, sent.failures.isEmpty else { throw Failure() }
                try await Self.checkCurrentServer(graph: graph, zone: zone, configuration: config)
            } else {
                guard try await manager.cloudActivationStatus(for: id)?.phase == .published else { throw Failure() }
                try await Self.checkCurrentServer(graph: graph, zone: zone, configuration: config)
            }
        }
        retainedGraph = graph
        return ["Stage " + stage + " completed on the pinned synthetic conversion.",
                "Source bytes retained; exact activation phase and native admission verified.",
                "Graph owner and manager retained for independent observation; no stage replay or cloud reset."]
    }

    @MainActor private static func seed(_ url: URL) throws {
        let graph = Graph(storeURL: url, migrationEnabled: false)
        guard graph.isReady else { throw Failure() }
        let a = Entity("Invoice", graph: graph), b = Entity("Category", graph: graph)
        a[dynamicMember: "name"] = "Synthetic MF10"; a[dynamicMember: "amount"] = NSDecimalNumber(string: "12.34")
        a[dynamicMember: "binary"] = Data([1,2,3]); a.add(tags: "retained"); a.add(to: "invoices")
        _ = a.is(relationship: "category").of(b); _ = a.will(action: "review").add(objects: b)
        _ = Relationship("optional", graph: graph)
        var failure: Error?
        graph.sync { if !$0 { failure = $1 } }; if let failure { throw failure }
        guard let container = graph.persistentContainer else { throw Failure() }
        graph.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
    }

    private static func checkCurrentServer(graph: GraphStore, zone: GraphCloudZone, configuration: GraphCloudConfiguration) async throws {
        let binding = GraphCloudBinding(zone: zone, graphID: graph.id)
        let database = CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase
        var token: CKServerChangeToken?
        var current: [String: GraphRecord] = [:]
        var authorityObserved = false
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: .init(zoneName: zone.name, ownerName: zone.owner), since: token, resultsLimit: 100)
            for (key, result) in page.modificationResultsByID {
                let record = try result.get().record
                if key.recordName == "graphevo.activation" {
                    guard record.recordType == "GraphEvoActivation", let bytes = record["payload"] as? Data,
                          bytes.count <= 16 * 1024 else { throw Failure() }
                    let authority = try JSONDecoder().decode(GraphCloudAuthority.self, from: bytes)
                    guard authority.published, authority.graphID == graph.id, authority.activationID == graph.id.rawValue,
                          record.recordChangeTag?.isEmpty == false else { throw Failure() }
                    authorityObserved = true
                    continue
                }
                current[key.recordName] = try GraphCloudNodeCodec.decode(record, binding: binding).record
            }
            for value in page.deletions { current.removeValue(forKey: value.recordID.recordName) }
            guard current.count <= 6 else { throw Failure() }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        let remoteRecords = Array(current.values)
        guard authorityObserved, remoteRecords.count == 6, Set(remoteRecords.map(\.id)).count == 6 else { throw Failure() }
        let graphID = graph.id
        try await graph.read { scope in
            let actual = try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graphID, database: true)
                return try session.nodes.map { try session.snapshot($0.value, id: $0.key) }
            }
            guard Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.id, $0) }) else { throw Failure() }
        }
    }
}

private func requireValue<Value>(_ value: Value?) throws -> Value {
    guard let value else { throw CocoaError(.coderValueNotFound) }; return value
}
