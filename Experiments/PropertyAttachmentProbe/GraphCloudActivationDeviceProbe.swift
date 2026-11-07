import CloudKit
import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime
import GraphEvoStore

@available(iOS 17, macOS 14, *)
public actor GraphCloudActivationDeviceProbe {
    private struct Failure: Error {}
    private struct Settings: Codable, Sendable, Equatable { let names: [String]; let revision: Int }
    private struct Fixture: Codable { let owner: GraphNodeID; let file: GraphFile; let revision: Int }
    private struct Item: GraphModel {
        static let graphType = "ValueProbe.Item"
        static let graphKind: GraphNodeKind = .entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) { record = graphRecord }
        func graphRecord(in graphID: GraphID) -> GraphRecord { record }
    }
    private var context: GraphContext?
    private var connection: GraphCloudConnection?
    private var graph: GraphStore?
    public init() {}
    private static func config(_ value: GraphCloudConnectionConfiguration) -> GraphCloudConfiguration {
        var config = GraphCloudConfiguration(containerIdentifier: value.containerIdentifier, environment: value.environment, directory: value.directory)
        config.supportsFiles = true
        return config
    }
    private static func send(_ context: GraphContext, graph: GraphStore, config: GraphCloudConnectionConfiguration) async throws {
        for _ in 0..<40 {
            let report = try await context.manager.sendCloudChanges(for: graph.id, configuration: Self.config(config))
            let pending = try await graph.collectSyncChanges()
            if report.transportError == nil && report.failures.isEmpty && pending == 0 { return }
            try await Task.sleep(for: .seconds(max(2, min(report.retryAfter ?? 2, 15))))
        }
        throw Failure()
    }
    @MainActor private static func seedLegacy(_ url: URL) throws -> String {
        var config = GraphStoreConfiguration(); config.location = url; config.disablesCloudKit = true
        let legacy = Graph(configuration: config, migrationEnabled: false)
        guard legacy.isReady else { throw Failure() }
        let item = Entity(Item.graphType, graph: legacy)
        item[dynamicMember: "large"] = Data(repeating: 91, count: 5 * 1024 * 1024 + 1)
        item[dynamicMember: "names"] = ["Ada", "Grace"]
        item[dynamicMember: "status"] = 1
        let oldID = item.id
        var failure: Error?
        legacy.sync { success, error in if !success { failure = error ?? Failure() } }
        if let failure { throw failure }
        let container = try legacy.persistentContainer.unwrap()
        legacy.managedObjectContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        try releaseDetachedLegacyGateway(container.persistentStoreCoordinator)
        return oldID
    }
    private static func verify(_ graph: GraphStore, fixture: Fixture) async throws {
        let record = try await graph.read { try $0.record(for: fixture.owner) }.unwrap()
        guard record.properties["names"] == ["Ada", "Grace"].graphValue,
              try record.attachmentData(for: "large") == Data(repeating: 91, count: 5 * 1024 * 1024 + 1),
              try record.attachmentValue(for: "settings", as: Settings.self) == Settings(names: ["Ada", "Grace"], revision: fixture.revision),
              try record.attachmentData(for: "small") == Data(repeating: UInt8(fixture.revision), count: fixture.revision == 1 ? 2 * 1024 * 1024 : 1024),
              try await graph.file(fixture.file.id) == fixture.file else { throw Failure() }
        let query = GraphQuery<Item>(budget: try GraphQueryBudget(maximumCandidates: 100, maximumPropertyBytes: 4096))
        guard try await graph.count(query).value == 1,
              try await graph.project(query, properties: ["names"]).rows.count == 1 else { throw Failure() }
        do { _ = try await graph.query(query); throw Failure() } catch is GraphQueryError {}
        let digest = try await graph.withFileURL(fixture.file.id) { url in
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        guard digest == fixture.file.sha256 else { throw Failure() }
    }
    private func closeWhenRequested(_ root: URL, stage: String) async {
        do {
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent(stage + ".close.request").path) { try await Task.sleep(for: .seconds(1)) }
            try await connection?.close(); try await graph?.close()
            graph = nil; connection = nil; context = nil
            try Data("closed".utf8).write(to: root.appendingPathComponent(stage + ".closed"), options: .withoutOverwriting)
        } catch { try? Data("failed".utf8).write(to: root.appendingPathComponent(stage + ".close.failed")) }
    }
    public func execute(stage: String, run: UUID, replica: String, directory: URL, container: String) async throws -> [String] {
        let root = directory.appendingPathComponent(run.uuidString).appendingPathComponent(replica)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(stage + ".started"), options: .withoutOverwriting)
        func phase(_ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent("phase.txt"), options: .atomic) }
        func write<T: Encodable>(_ value: T, _ name: String) throws { try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic) }
        func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name))) }
        let account = try await CKContainer(identifier: container).userRecordID().recordName
        if stage == "account" { try write(account, "account.private.json"); return ["Private account fixture retained."] }
        let context = GraphContext.localFiles(), graphID = GraphID(rawValue: run), store = root.appendingPathComponent("Store/Graph.sqlite")
        let config = try GraphCloudConnectionConfiguration(containerIdentifier: container, environment: .development, directory: root.appendingPathComponent("Cloud"))
        let connection = try await context.connectCloud(using: config)
        for _ in 0..<90 { if try await connection.state == .ready { break }; try await Task.sleep(for: .seconds(1)) }
        guard try await connection.state == .ready else { throw Failure() }
        self.context = context; self.connection = connection
        let graph: GraphStore
        var fixture: Fixture
        if stage == "seed" {
            try phase("migrate v1 binary into S07 attachment")
            let oldID = try await Self.seedLegacy(root.appendingPathComponent("V1.sqlite"))
            let result = try await context.openGraph(convertingLocalV1: .init(sourceURL: root.appendingPathComponent("V1.sqlite"), destinationURL: store,
                graphID: graphID, operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "S07 physical value contract"))
            graph = try result.opening.get()
            let owner = try result.conversion.receipt.nodeIDs[oldID].unwrap()
            try await graph.transaction { try $0.patch(GraphRecordPatch(id: owner, attachments: ["small": .set(.init(data: Data(repeating: 1, count: 2 * 1024 * 1024))), "settings": .set(try .init(codable: Settings(names: ["Ada", "Grace"], revision: 1)))])) }
            do {
                try await graph.transaction { try $0.patch(GraphRecordPatch(id: owner, properties: ["status": .set(.integer(999))], attachments: ["oversize": .set(.init(data: Data(count: 2 * 1024 * 1024 + 1)))])) }
                throw Failure()
            } catch is GraphAttachmentError {}
            guard try await graph.read({ try $0.record(for: owner)?.properties["status"] }) == .integer(1) else { throw Failure() }
            let input = root.appendingPathComponent("file.bin"); try Data(repeating: 17, count: 256 * 1024).write(to: input)
            let file = try await graph.importFile(from: input)
            fixture = Fixture(owner: owner, file: file, revision: 1)
            try phase("prepare authoritative migration publication")
            _ = try await connection.prepareActivation(for: graphID, activationID: UUID(), zoneName: "GE2-Values-" + run.uuidString,
                declaration: .init(sourceSelection: "Controlled local v1 fixture", completeness: "Complete one-node source and new fields", stoppedWriters: "Source coordinator detached", returningClients: "No legacy writers"))
            var published = false
            for _ in 0..<30 {
                let result = try await connection.advanceActivation(for: graphID)
                if result.status.phase == .published { published = true; break }
                try await Task.sleep(for: .seconds(2))
            }
            guard published else { throw Failure() }
            try phase("publish exact-limit and migrated attachments")
            try await Self.send(context, graph: graph, config: config)
            let sharing = try await connection.prepareSharing(for: graph, title: "GraphEvo value contract")
            try await sharing.close()
            let recipient = try read(String.self, "recipient.private.json")
            guard account != recipient else { throw Failure() }
            let invitation = try await context.manager.inviteCloudParticipant(recipient, to: graphID, configuration: Self.config(config))
            try write(invitation, "invitation.private.json")
        } else {
            fixture = try read(Fixture.self, "fixture.json")
            if replica == "peer" {
                let join: GraphCloudJoin
                if stage == "join" {
                    let invitation = try read(GraphCloudInvitation.self, "invitation.private.json")
                    join = try await connection.acceptInvitation(at: invitation.url)
                    for _ in 0..<30 { if try await join.state.phase == .ready { break }; try await join.retry(); try await Task.sleep(for: .seconds(1)) }
                } else {
                    join = try await connection.pendingInvitations().first.unwrap()
                    for _ in 0..<30 { if try await join.state.phase == .ready { break }; try await join.retry(); try await Task.sleep(for: .seconds(1)) }
                }
                graph = try await connection.openReplica(for: join, at: store)
            } else {
                graph = try await context.openGraph(id: graphID, at: store)
                try await connection.bindPrivateGraph(graph, zoneName: "GE2-Values-" + run.uuidString)
            }
            try phase("verify independent replica")
            for attempt in 0..<45 {
                try await context.manager.fetchCloudChanges(replica == "owner" ? .private : .shared, configuration: Self.config(config))
                _ = try await context.manager.applyCloudInbox(for: graphID, configuration: Self.config(config))
                do { try await Self.verify(graph, fixture: fixture); break }
                catch { if attempt == 44 { throw error }; try await Task.sleep(for: .seconds(2)) }
            }
            if stage == "join" || stage == "peer-exchange" || stage == "owner-exchange" {
                let revision = fixture.revision + 1
                try await graph.transaction { try $0.patch(GraphRecordPatch(id: fixture.owner, properties: ["status": .set(.integer(Int64(revision)))], attachments: ["small": .set(.init(data: Data(repeating: UInt8(revision), count: 1024))), "settings": .set(try .init(codable: Settings(names: ["Ada", "Grace"], revision: revision)))])) }
                fixture = Fixture(owner: fixture.owner, file: fixture.file, revision: revision)
                try phase("publish replacement and preserve migrated oversize")
                try await Self.send(context, graph: graph, config: config)
            }
        }
        self.graph = graph
        try await Self.verify(graph, fixture: fixture)
        try write(fixture, "fixture.json")
        Task { await self.closeWhenRequested(root, stage: stage) }
        return ["Exact bytes, fixed Codable codec, collection properties and File verified.", "Ordinary 2 MiB admission and over-limit refusal verified on owner.", "Migrated 5 MiB attachment retained; query projections exclude bodies.", "Revision " + String(fixture.revision) + " verified in " + replica + " scope."]
    }
}
private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw NSError(domain: "ValueProbe.Missing", code: 1) }; return value
    }
}
