import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

actor DeletionFault {
    var calls = 0
    var zoneCreates = 0
    var offline = false
    var ambiguous = false
    func configure(offline: Bool = false, ambiguous: Bool = false) { self.offline = offline; self.ambiguous = ambiguous }
    func publish(_ server: ActivationServer, route: GraphCloudBinding, files: Bool, mayCreate: Bool) async throws {
        let existing = try await server.descriptors(route.zone.name)
        if mayCreate { zoneCreates += 1 }
        else if !existing.contains(where: { $0.zone == route.zone }) { throw CKError(.zoneNotFound) }
        try await server.publishDescriptor(route, files: files)
    }
    func remove(_ server: ActivationServer, route: GraphCloudBinding) async throws {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        await server.eraseZone(route.zone)
        if ambiguous { ambiguous = false; throw URLError(.timedOut) }
    }
}
extension ActivationServer {
    func eraseZone(_ zone: GraphCloudZone) { records = records.filter { $0.value.zone != zone }; authorities.removeValue(forKey: zone.name) }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct GraphDeletionTests {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphDeletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func manager(registry: StoreRegistry = StoreRegistry()) -> GraphContextManager {
        GraphContextManager(registry: registry, schema: GraphRuntimeSchema.attachmentFiles,
            adapter: GraphCoordinatorFactory.makeAdapter(files: true))
    }
    @Test func localDeletionPreservesAdjacentGraphAndDurableCompletion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GraphContext.localFiles(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let graph = try await context.createGraph(id: id, at: url)
        let other = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("B.sqlite"))
        let note = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: note, type: "Note", properties: ["title": .string("Keep")])) }
        let edge = graph.makeNodeID()
        let file = root.appendingPathComponent("input.txt"); try Data("file".utf8).write(to: file)
        _ = try await graph.importFile(from: file, name: "input", contentType: "public.text") { scope, file in
            try scope.insert(GraphRecord(id: edge, type: "NoteFile", endpoints: .relationship(subject: note, object: file.id)))
        }
        let result = try await context.deleteGraph(graph)
        #expect(result.phase == .completed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await context.graphDeletionStatus(id: id, at: url) == result)
        #expect(try await other.validateIntegrity() == 0)
        try await other.close(); try await graph.close()
        let restarted = GraphContext.localFiles()
        #expect(try await restarted.resumeGraphDeletion(id: id, at: url) == result)
        await #expect(throws: (any Error).self) { try await restarted.createGraph(id: id, at: url) }
    }
    @Test(arguments: [false, true])
    func cloudFailureRemainsPendingAndResumesWithoutTouchingAdjacentZone(ambiguous: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = ActivationServer(), fault = DeletionFault(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.deletion", environment: .development,
            directory: root.appendingPathComponent("session")); config.supportsFiles = true
        var cloudAdapter = server.privateAdapter(root: root.appendingPathComponent("server"))
        cloudAdapter.deletion = .init(remove: { _, route, _ in try await fault.remove(server, route: route) })
        let first = manager(), graph = try await first.createGraph(id: id, at: url)
        _ = try await first.startCloudSession(config, adapter: cloudAdapter)
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "Delete")
        try await first.bindCloudZone(zone, to: id, configuration: config)
        let other = GraphCloudBinding(zone: .init(scope: .private, owner: CKCurrentUserDefaultName, name: "Keep"), graphID: GraphID())
        try await server.publishDescriptor(other, files: true)
        await fault.configure(offline: !ambiguous, ambiguous: ambiguous)
        await #expect(throws: (any Error).self) { try await first.deleteGraph(id, configuration: config) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let intent = try #require(try await GraphDeletionIntent.read(first.graphStoreConfiguration(id, at: url)))
        #expect(intent.phase == .prepared)
        await #expect(throws: (any Error).self) { try await graph.validateIntegrity() }
        try await graph.close(); try await first.stopCloudSession(config)
        await fault.configure()
        let second = manager()
        _ = try await second.startCloudSession(config, adapter: cloudAdapter)
        let result = try await second.resumeGraphDeletion(id, at: url, configuration: config)
        #expect(result.id == intent.operationID && result.phase == .completed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await second.cloud(config).discoverPrivateGraphs(prefix: nil).graphs.map(\.id) == [other.graphID])
        try await second.stopCloudSession(config)
    }
    @Test func localDeletionRefusesCloudBoundDataBeforeWritingIntent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = manager(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let graph = try await owner.createGraph(id: id, at: url)
        let server = ActivationServer()
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.bound", environment: .development, directory: root.appendingPathComponent("session"))
        config.supportsFiles = true
        _ = try await owner.startCloudSession(config, adapter: server.privateAdapter(root: root.appendingPathComponent("server")))
        try await owner.bindCloudZone(.init(scope: .private, owner: CKCurrentUserDefaultName, name: "Bound"), to: id, configuration: config)
        await #expect(throws: (any Error).self) { try await owner.deleteGraph(id, configuration: nil) }
        #expect(try await GraphDeletionIntent.read(owner.graphStoreConfiguration(id, at: url)) == nil)
        try await graph.close(); try await owner.stopCloudSession(config)
    }
    @Test func livePresenterDefersDestructionAndAllowsNormalDetach() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let resolved = try ResolvedStore(first.graphStoreConfiguration(id, at: url))
        let peer = AppGroupStorePresenter(directory: try SQLiteStoreCoordination.directory(resolved))
        try await AppGroupStoreAccess(presenter: peer).run {
            try AppGroupOwnerClaims.publish(peer.generation, for: resolved, creating: false)
        }
        peer.register(); defer { peer.unregister() }
        await #expect(throws: (any Error).self) { try await first.deleteGraph(id, configuration: nil) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await graph.close()
        // The registered presenter, not a bare registration, models a live peer.
        try await AppGroupStoreAccess(presenter: peer).run { try AppGroupOwnerClaims.remove(peer.generation, for: resolved) }
        peer.unregister()
        let result = try await manager().resumeGraphDeletion(id, at: url, configuration: nil)
        #expect(result.phase == .completed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func nativeIntentSurvivesGapBeforeExternalJournalPublication() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let owner = try await #require(first.entries[id]).opening.value
        let intent = GraphDeletionIntent(operationID: UUID(), graphID: id, storeID: try await owner.storeIdentity(), source: try GraphDeletionSource(url), binding: nil, phase: .prepared)
        try await owner.blockSharingData(); _ = try await owner.deletionIntent(intent)
        try await graph.close()
        let result = try await manager().resumeGraphDeletion(id, at: url, configuration: nil)
        #expect(result.id == intent.operationID && result.phase == .completed)
    }
    @Test func nativeReplacementRefusesDeletionAndRemainsUsable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let owner = try await #require(first.entries[id]).opening.value
        let intent = GraphDeletionIntent(operationID: UUID(), graphID: id, storeID: try await owner.storeIdentity(), source: try GraphDeletionSource(url), binding: nil, phase: .prepared)
        _ = try await owner.deletionIntent(intent); try await intent.persist(first.graphStoreConfiguration(id, at: url))
        try await graph.close()
        let replacementURL = root.appendingPathComponent("Replacement.sqlite"), other = manager()
        let replacement = try await other.createGraph(id: id, at: replacementURL)
        let note = replacement.makeNodeID()
        try await replacement.transaction { try $0.insert(GraphRecord(id: note, type: "Keep")) }
        try await replacement.close()
        // Both fixtures are closed; this copies only the independent replacement into the terminal test path.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacementURL, to: url)
        let originalBytes = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await manager().resumeGraphDeletion(id, at: url, configuration: nil) }
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test func pendingCloudDeletionCannotExecuteUnderAnotherAccount() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager(), server = ActivationServer(), fault = DeletionFault()
        let graph = try await first.createGraph(id: id, at: url)
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.identity", environment: .development, directory: root.appendingPathComponent("A-session"))
        config.supportsFiles = true
        var adapter = server.privateAdapter(root: root.appendingPathComponent("server"))
        adapter.deletion = .init(remove: { _, route, _ in try await fault.remove(server, route: route) })
        _ = try await first.startCloudSession(config, adapter: adapter)
        try await first.bindCloudZone(.init(scope: .private, owner: CKCurrentUserDefaultName, name: "A-zone"), to: id, configuration: config)
        await fault.configure(offline: true)
        await #expect(throws: (any Error).self) { try await first.deleteGraph(id, configuration: config) }
        let calls = await fault.calls
        try await graph.close(); try await first.stopCloudSession(config)
        var otherConfig = GraphCloudConfiguration(containerIdentifier: config.containerIdentifier, environment: .development, directory: root.appendingPathComponent("B-session"))
        otherConfig.supportsFiles = true
        let wrong = GraphCloudAdapter(deletion: adapter.deletion, privateGraphs: adapter.privateGraphs, activation: adapter.activation,
            account: { _ in "different-synthetic-account" }, make: adapter.make)
        let second = manager(); _ = try await second.startCloudSession(otherConfig, adapter: wrong)
        await #expect(throws: GraphCloudError.accountChanged) { try await second.resumeGraphDeletion(id, at: url, configuration: otherConfig) }
        #expect(await fault.calls == calls)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await second.stopCloudSession(otherConfig)
        await fault.configure()
        let recovered = manager(); _ = try await recovered.startCloudSession(config, adapter: adapter)
        #expect(try await recovered.resumeGraphDeletion(id, at: url, configuration: config).phase == .completed)
        try await recovered.stopCloudSession(config)
    }
    @Test func returningPrivateReplicaCannotCreateDeletedZoneAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = ActivationServer(), fault = DeletionFault(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.stale", environment: .development, directory: root.appendingPathComponent("session")); config.supportsFiles = true
        var adapter = server.privateAdapter(root: root.appendingPathComponent("server"))
        adapter.privateGraphs = .init(list: { _, prefix in try await server.descriptors(prefix) },
            publish: { config, route, mayCreate in try await fault.publish(server, route: route, files: config.supportsFiles, mayCreate: mayCreate) })
        adapter.deletion = .init(remove: { _, route, _ in try await fault.remove(server, route: route) })
        let first = manager(), graph = try await first.createGraph(id: id, at: url)
        _ = try await first.startCloudSession(config, adapter: adapter)
        let zone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "Deleted")
        try await first.bindCloudZone(zone, to: id, configuration: config)
        try await graph.close(); try await first.stopCloudSession(config)
        // The server deletion represents a command completed by another replica.
        await server.eraseZone(zone)
        let second = manager(), reopened = try await second.openGraph(id: id, at: url)
        _ = try await second.startCloudSession(config, adapter: adapter)
        await #expect(throws: (any Error).self) { try await second.bindCloudZone(zone, to: id, configuration: config) }
        #expect(await fault.zoneCreates == 1)
        #expect(try await server.descriptors(zone.name).isEmpty)
        try await reopened.close(); try await second.stopCloudSession(config)
    }

    @Test func failedInitialPublicationCanBeDeletedWithoutRecreatingItsZone() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = ActivationServer(), owner = manager(), fault = DeletionFault(), id = GraphID(), url = root.appendingPathComponent("A.sqlite")
        let graph = try await owner.createGraph(id: id, at: url)
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.initial", environment: .development, directory: root.appendingPathComponent("session")); config.supportsFiles = true
        var adapter = server.privateAdapter(root: root.appendingPathComponent("server"))
        adapter.privateGraphs = .init(list: { _, prefix in try await server.descriptors(prefix) },
            publish: { _, _, _ in throw URLError(.timedOut) })
        adapter.deletion = .init(remove: { _, route, _ in try await fault.remove(server, route: route) })
        _ = try await owner.startCloudSession(config, adapter: adapter)
        await #expect(throws: (any Error).self) {
            try await owner.bindCloudZone(.init(scope: .private, owner: CKCurrentUserDefaultName, name: "Initial"), to: id, configuration: config)
        }
        #expect(try await owner.deleteGraph(id, configuration: config).phase == .completed)
        #expect(await fault.calls == 1)
        try await graph.close(); try await owner.stopCloudSession(config)
    }

    @Test func pendingDeletionResumesAfterQuiescentContainerMove() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original"), relocated = root.appendingPathComponent("Relocated")
        let id = GraphID(), url = source.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let owner = try await #require(first.entries[id]).opening.value
        let intent = GraphDeletionIntent(operationID: UUID(), graphID: id, storeID: try await owner.storeIdentity(),
            source: try GraphDeletionSource(url), binding: nil, phase: .prepared)
        _ = try await owner.deletionIntent(intent); try await intent.persist(first.graphStoreConfiguration(id, at: url))
        try await graph.close()
        try FileManager.default.moveItem(at: source, to: relocated)
        let result = try await manager().resumeGraphDeletion(id, at: relocated.appendingPathComponent("A.sqlite"), configuration: nil)
        #expect(result.id == intent.operationID && result.phase == .completed)
    }

    @Test(arguments: [false, true])
    func corruptOrSymlinkedJournalRefusesOpeningAndPreservesNativeStore(symlink: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        try await graph.close()
        let original = try Data(contentsOf: url)
        let journal = root.appendingPathComponent(".A.sqlite.graphevo-deletion-v1.json")
        if symlink { try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: root.appendingPathComponent("Missing")) }
        else { try Data().write(to: journal) }
        await #expect(throws: (any Error).self) { try await manager().openGraph(id: id, at: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func recoveryOpeningRequiresExistingDeletionIntent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let configuration = first.graphStoreConfiguration(id, at: url)
        try await graph.close()
        let original = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) {
            try await StoreRegistry().open(configuration, schema: GraphRuntimeSchema.attachmentFiles,
                mode: .graphDeletionRecovery(storeID: UUID().uuidString, operationID: UUID()))
        }
        #expect(try Data(contentsOf: url) == original)
        let reopened = try await manager().openGraph(id: id, at: url)
        try await reopened.close()
    }

    @Test func abandonedOrdinaryRegistrationRecoversOnlyDuringExactDeletion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let resolved = try ResolvedStore(first.graphStoreConfiguration(id, at: url))
        let peer = AppGroupStorePresenter(directory: try SQLiteStoreCoordination.directory(resolved))
        try await AppGroupStoreAccess(presenter: peer).run { try AppGroupOwnerClaims.publish(peer.generation, for: resolved, creating: false) }
        try await graph.close()
        let resumed = manager(), reopened = try await resumed.openGraph(id: id, at: url)
        // Normal opening keeps unresolved registrations; only terminal intent admits recovery.
        let registration = peer.presentedItemURL!.appendingPathComponent(peer.generation.uuidString)
        #expect(FileManager.default.fileExists(atPath: registration.path))
        #expect(try await resumed.deleteGraph(id, configuration: nil).phase == .completed)
        #expect(!FileManager.default.fileExists(atPath: registration.path))
        try await reopened.close()
    }
    @Test(arguments: [false, true])
    func foreignOrRetiringRegistrationsRemainUnresolved(retiring: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = GraphID(), url = root.appendingPathComponent("A.sqlite"), first = manager()
        let graph = try await first.createGraph(id: id, at: url)
        let config = StoreConfiguration(location: .sqlite(url), exclusiveGraphID: retiring ? id.rawValue : UUID())
        let resolved = try ResolvedStore(config)
        let peer = AppGroupStorePresenter(directory: try SQLiteStoreCoordination.directory(resolved))
        try await AppGroupStoreAccess(presenter: peer).run {
            try AppGroupOwnerClaims.publish(peer.generation, for: resolved, creating: false)
            if retiring { try AppGroupOwnerClaims.markRetiring(peer.generation, for: resolved) }
        }
        await #expect(throws: (any Error).self) { try await first.deleteGraph(id, configuration: nil) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: peer.presentedItemURL!.appendingPathComponent(peer.generation.uuidString).path))
        try await graph.close()
        // Remove only this synthetic fixture's claim, never an unverified production owner.
        try await AppGroupStoreAccess(presenter: peer).run { try AppGroupOwnerClaims.remove(peer.generation, for: resolved) }
        #expect(try await manager().resumeGraphDeletion(id, at: url, configuration: nil).phase == .completed)
    }

    func completedSharedDeletionFixture() async throws -> (URL, GraphCloudConfiguration, GraphCloudAdapter, GraphCloudZone, GraphCloudZone) {
        let root = try root(), server = ActivationServer(), fault = DeletionFault()
        var config = GraphCloudConfiguration(containerIdentifier: "synthetic.shared-deletion", environment: .development,
            directory: root.appendingPathComponent("session")); config.supportsFiles = true
        var adapter = server.privateAdapter(root: root.appendingPathComponent("server"))
        adapter.deletion = .init(remove: { _, route, _ in try await fault.remove(server, route: route) })
        let context = manager(), deletedID = GraphID(), neighborID = GraphID()
        let graph = try await context.createGraph(id: deletedID, at: root.appendingPathComponent("Deleted.sqlite"))
        let neighbor = try await context.createGraph(id: neighborID, at: root.appendingPathComponent("Neighbor.sqlite"))
        let deletedZone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "Deleted")
        let neighborZone = GraphCloudZone(scope: .private, owner: CKCurrentUserDefaultName, name: "Neighbor")
        _ = try await context.startCloudSession(config, adapter: adapter)
        try await context.bindCloudZone(deletedZone, to: deletedID, configuration: config)
        try await context.bindCloudZone(neighborZone, to: neighborID, configuration: config)
        try await context.stopCloudSession(config)
        let url = config.directory.appendingPathComponent("session.json")
        var document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: url))
        // Inject durable share-attempt bookkeeping, not a native CKShare certificate.
        document.shareAttempts = [deletedZone, neighborZone]
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
        _ = try await context.startCloudSession(config, adapter: adapter)
        #expect(try await context.deleteGraph(deletedID, configuration: config).phase == .completed)
        document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: url))
        #expect(document.shareAttempts == [neighborZone])
        try await graph.close(); try await neighbor.close(); try await context.stopCloudSession(config)
        return (root, config, adapter, deletedZone, neighborZone)
    }
    @Test func ownerDeletionRemovesOnlyItsShareAttemptAndSessionReopens() async throws {
        let (root, config, adapter, _, neighborZone) = try await completedSharedDeletionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        #expect(try await session.routes(in: .private).map(\.zone) == [neighborZone])
        try await session.stop()
    }
    @Test func completedDeletionRecoversOrphanAttemptWithoutResettingOtherState() async throws {
        let (root, config, adapter, deletedZone, neighborZone) = try await completedSharedDeletionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = config.directory.appendingPathComponent("session.json")
        var document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: url))
        document.shareAttempts.append(deletedZone)
        document.states[GraphCloudScope.private.rawValue] = Data("Opaque engine checkpoint".utf8)
        let states = document.states, client = document.clientID
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
        let session = try await GraphCloudSession.open(config, adapter: adapter)
        let recovered = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: url))
        #expect(recovered.shareAttempts == [neighborZone])
        #expect(recovered.states == states && recovered.clientID == client)
        #expect(recovered.deletions.count == 1 && recovered.deletions[0].phase == .completed)
        #expect(try await session.routes(in: .private).map(\.zone) == [neighborZone])
        try await session.stop()
        let reopened = try await GraphCloudSession.open(config, adapter: adapter)
        try await reopened.stop()
    }
    @Test(arguments: ["unfinished", "foreign-zone", "duplicate", "other-corruption"])
    func unprovenOrInvalidOrphanRecoveryPreservesDocument(reason: String) async throws {
        let (root, config, adapter, deletedZone, _) = try await completedSharedDeletionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = config.directory.appendingPathComponent("session.json")
        var document = try JSONDecoder().decode(GraphCloudDocument.self, from: Data(contentsOf: url))
        document.shareAttempts.append(deletedZone)
        switch reason {
        case "unfinished": document.deletions[0].phase = .remoteDeleted
        case "foreign-zone": document.shareAttempts.append(.init(scope: .private, owner: CKCurrentUserDefaultName, name: "Unproved"))
        case "duplicate": document.shareAttempts.append(deletedZone)
        default: document.states["Unknown scope"] = Data([1])
        }
        let original = try JSONEncoder().encode(document)
        try original.write(to: url, options: .atomic)
        await #expect(throws: GraphCloudError.invalidState) { try await GraphCloudSession.open(config, adapter: adapter) }
        #expect(try Data(contentsOf: url) == original)
    }

}
