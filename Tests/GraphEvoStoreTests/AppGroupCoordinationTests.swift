import CoreData
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoRuntime
@testable import GraphEvoStore

private struct CommitInterruption: Sendable {
    let reached = AsyncCheckpoint()
    let resume = DispatchSemaphore(value: 0)

    func hold() {
        Task { await reached.signal() }
        _ = resume.wait(timeout: .now() + 10)
    }
}

private actor AsyncCheckpoint {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !reached { await withCheckedContinuation { waiters.append($0) } }
    }
    func signal() {
        reached = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite(.timeLimit(.minutes(2))) struct AppGroupCoordinationTests {
    @Test
    @available(iOS 17, macOS 14, *)
    func preparedWriteRejectsACommitByAnIndependentNativeOwner() async throws {
        let directory = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = AppGroupStoreLocation(container: directory)
        let id = GraphID(), context = appGroupContext(group)
        let url = try context.appGroupStoreURL(for: id)
        let graph = try await context.createGraph(id: id, at: url)
        try await graph.close()

        let resolved = try ResolvedStore(.init(location: .sqlite(url), exclusiveGraphID: id.rawValue, appGroup: group))
        let schema = GraphRuntimeSchema.typedProperties
        let owner = UUID(), identity = try resolved.fileIdentity()
        // The shared gateway UUID lets this fixture use two independent
        // coordinators while still executing the real Apple access path.
        let first = try await StoreResources.open(resolved, schema: schema, hooks: .init(), owner: owner,
            nativeMigration: nil, mode: .existing, expectedIdentity: identity)
        let peer = try await StoreResources.open(resolved, schema: schema, hooks: .init(), owner: owner,
            nativeMigration: nil, mode: .existing, expectedIdentity: identity)
        let ready = AsyncCheckpoint(), resume = AsyncCheckpoint()
        let adapter = GraphCoordinatorFactory.adapter.graph
        let stale = GraphNodeID(graphID: id), committed = GraphNodeID(graphID: id)
        let file = directory.appendingPathComponent("staged")
        let preparation = Task {
            try await first.preparedControlTransaction(prepare: {
                try adapter.insert($0, id, .init(id: stale, type: "Stale"))
            }, materialize: { _, _ in
                try Data([1]).write(to: file)
                await ready.signal()
                await resume.wait()
                return file
            }, discard: { url in
                try? FileManager.default.removeItem(at: url)
            }, finish: { _, _ in
                Issue.record("A preparation based on old history reached finalization.")
            })
        }
        await ready.wait()
        do {
            try await peer.transaction { try adapter.insert($0, id, .init(id: committed, type: "Peer")) }
        } catch {
            await resume.signal()
            _ = try? await preparation.value
            throw error
        }
        await resume.signal()
        await #expect {
            try await preparation.value
        } throws: { error in
            if case .resourceReserved? = error as? StoreRuntimeError { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await peer.close()
        try await first.close()
        let reopened = try await context.openGraph(id: id, at: url)
        #expect(try await reopened.read { try $0.record(for: stale) } == nil)
        #expect(try await reopened.read { try $0.record(for: committed)?.type } == "Peer")
        try await reopened.close()
    }

    @Test
    @available(iOS 17, macOS 14, *)
    func dedicatedPathRefusesOrdinaryAndAliasedAdmissionAndSurvivesCleanOpenFault() async throws {
        let container = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: container) }
        let group = AppGroupStoreLocation(container: container)
        let id = GraphID(), context = appGroupContext(group), url = try context.appGroupStoreURL(for: id)
        await #expect(throws: (any Error).self) { try await GraphContext().createGraph(id: id, at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let graph = try await context.createGraph(id: id, at: url)
        let node = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(.init(id: node, type: "Retained")) }
        try await graph.close()

        let alias = container.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url.deletingLastPathComponent())
        let aliased = alias.appendingPathComponent(url.lastPathComponent)
        await #expect(throws: (any Error).self) { try await GraphContext().openGraph(id: id, at: aliased) }
        await #expect(throws: (any Error).self) { try await context.openGraph(id: id, at: aliased) }
        #expect(throws: StoreRuntimeError.self) { try StoreGatewayLease.legacy(at: url) }
        let fault = StoreRegistry(hooks: .init(didLoadStore: { _ in throw StoreRuntimeError.resourceReserved }))
        let configuration = StoreConfiguration(location: .sqlite(url), exclusiveGraphID: id.rawValue, appGroup: group)
        await #expect(throws: StoreRuntimeError.self) {
            try await fault.open(configuration, schema: GraphRuntimeSchema.typedProperties, mode: .existing)
        }
        let owners = url.deletingLastPathComponent().appendingPathComponent(".owners-v1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: owners.path).isEmpty)

        let reopened = try await context.openGraph(id: id, at: url)
        #expect(try await reopened.read { try $0.record(for: node)?.type } == "Retained")
        try await reopened.close()
    }

    @available(iOS 17, macOS 14, *)
    @Test
    func preparedAndNativeCancellationPreserveExactGraphAndAttachments() async throws {
        let container = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: container) }
        let group = AppGroupStoreLocation(container: container)
        let graphID = GraphID(), context = appGroupContext(group)
        let url = try context.appGroupStoreURL(for: graphID)
        let root = url.deletingLastPathComponent()
        let graph = try await context.createGraph(id: graphID, at: url)
        let owner = graph.makeNodeID()
        _ = try await graph.transaction { try $0.insert(.init(id: owner, type: "CancellationOwner")) }
        var assets: [GraphAttachmentMetadata] = []
        for number in 1...2 {
            let input = root.appendingPathComponent("asset-\(number).bin")
            try Data(repeating: UInt8(number), count: 4 * 1024 * 1024).write(to: input)
            assets.append(try await graph.importAttachment(from: input, ownedBy: owner))
            try FileManager.default.removeItem(at: input)
        }
        try await graph.close()

        let configuration = StoreConfiguration(location: .sqlite(url), exclusiveGraphID: graphID.rawValue, appGroup: group)
        let schema = GraphRuntimeSchema.typedProperties
        let adapter = GraphCoordinatorFactory.adapter.graph
        let submitted = AsyncCheckpoint()
        let registry = StoreRegistry(hooks: .init(didSubmitCoordinatedWrite: { Task { await submitted.signal() } }))
        let handle = try await registry.open(configuration, schema: schema, mode: .existing)
        let discarded = GraphNodeID(graphID: graphID), nativeDiscard = GraphNodeID(graphID: graphID)
        let heldGrant = CommitInterruption()
        let competingAccess = Task {
            try await CoordinatedFiles.run([.write(root)]) {
                heldGrant.hold()
            }
        }
        await heldGrant.reached.wait()
        let waitingForApple = Task {
            try await handle.transaction { _ in
                Issue.record("The transaction entered native execution while an independent Apple accessor was held.")
            }
        }
        await submitted.wait()
        waitingForApple.cancel()
        heldGrant.resume.signal()
        try await competingAccess.value
        await #expect(throws: CancellationError.self) { try await waitingForApple.value }

        let fileStarted = AsyncCheckpoint(), releaseFile = AsyncCheckpoint()
        let staging = root.appendingPathComponent("staging.cancel")
        let pendingFile = Task {
            try await handle.preparedControlTransaction(prepare: { native in
                try adapter.insert(native, graphID, GraphRecord(id: discarded, type: "Discarded"))
                return staging
            }, materialize: { staging, check in
                defer { try? FileManager.default.removeItem(at: staging) }
                try Data([1, 2, 3]).write(to: staging)
                await fileStarted.signal()
                await releaseFile.wait()
                try check()
                return true
            }, finish: { _, materialized in
                Issue.record("A cancelled file preparation reached native finalization.")
                return materialized
            })
        }
        await fileStarted.wait()
        pendingFile.cancel()
        await releaseFile.signal()
        await #expect(throws: CancellationError.self) { try await pendingFile.value }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await handle.read { try adapter.fetch($0, graphID, discarded) } == nil)

        let nativeGate = CommitInterruption()
        let unsaved = Task {
            try await handle.transaction { native in
                try adapter.insert(native, graphID, GraphRecord(id: nativeDiscard, type: "Discarded"))
                nativeGate.hold()
            }
        }
        await nativeGate.reached.wait()
        unsaved.cancel()
        nativeGate.resume.signal()
        await #expect(throws: CancellationError.self) { try await unsaved.value }
        try await handle.close()

        let commitGate = CommitInterruption()
        let commitRegistry = StoreRegistry(hooks: .init(afterCommit: { commitGate.hold() }))
        let committing = try await commitRegistry.open(configuration, schema: schema, mode: .existing)
        let committedID = GraphNodeID(graphID: graphID)
        let saving = Task {
            try await committing.transaction { native in
                try adapter.insert(native, graphID, GraphRecord(id: committedID, type: "Committed"))
                return committedID
            }
        }
        await commitGate.reached.wait()
        saving.cancel()
        commitGate.resume.signal()
        #expect(try await saving.value == committedID)
        try await committing.close()

        let fresh = try await appGroupContext(group).openGraph(id: graphID, at: url)
        try await fresh.read { scope throws -> Void in
            #expect(try scope.record(for: owner)?.type == "CancellationOwner")
            #expect(try scope.record(for: discarded) == nil)
            #expect(try scope.record(for: nativeDiscard) == nil)
            #expect(try scope.record(for: committedID)?.type == "Committed")
        }
        let observedAssets = try await fresh.attachments(ownedBy: owner)
        let observedIDs = observedAssets.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let expectedIDs = assets.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        #expect(observedIDs == expectedIDs)
        for (index, asset) in assets.enumerated() {
            let observed = try #require(try await fresh.attachment(asset.id))
            #expect(observed.metadata == asset)
            #expect(observed.data == Data(repeating: UInt8(index + 1), count: 4 * 1024 * 1024))
        }
        try await fresh.close()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!files.contains { $0.hasSuffix(".owners.lock") })
        #expect(!files.contains { $0.hasSuffix(".writer.lock") })
    }
}

@Suite(.timeLimit(.minutes(2))) struct PublicAppGroupTests {
    @Test
    @available(iOS 17, macOS 14, *)
    func secondaryUsesPersistedParticipantWriteRestriction() async throws {
        let root = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = AppGroupStoreLocation(container: root)
        let id = GraphID(), setup = appGroupContext(group)
        let graph = try await setup.createGraph(id: id, at: setup.appGroupStoreURL(for: id))
        let entry = try #require(await setup.manager.entries[id])
        let owner = try await entry.opening.value
        let binding = GraphCloudBinding(zone: .init(scope: .shared, owner: "owner", name: "fixture"), graphID: id)
        _ = try await owner.participantAccess(.init(binding: binding, account: "participant", permission: .readOnly, accepted: true))
        try await graph.close()

        let secondary = appGroupContext(group, role: .secondary, access: .readWrite)
        await #expect {
            _ = try await secondary.transactionAppGroupGraph(id: id) { _ in Issue.record("Read-only replica entered mutation.") }
        } throws: { error in
            if case .permissionDenied? = error as? GraphStoreError { return true }
            return false
        }
        #expect(await secondary.manager.cloudSessions.isEmpty)
    }

    @Test
    @available(iOS 17, macOS 14, *)
    func optedInPrimaryBindsAndRecoversSecondaryHistory() async throws {
        let root = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = AppGroupStoreLocation(container: root)
        let id = GraphID(), node = GraphNodeID(graphID: id)
        let cloud = try GraphCloudConnectionConfiguration(containerIdentifier: "iCloud.LocalAppGroup",
            environment: .development, directory: root.appendingPathComponent("Cloud"))
        let configuration = GraphAppGroupConfiguration(identifier: "fixture", role: .primary, allowsCloudSynchronization: true)
        func primary(account: String) -> GraphContext {
            let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.typedProperties,
                adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group, publicAppGroup: configuration)
            let driver = GraphCloudAdapter(account: { _ in account }, make: { _, _, _, _ in
                GraphCloudDriver(fetch: { _ in }, cancel: {})
            })
            return GraphContext(manager: manager, adapter: driver)
        }
        let original = primary(account: "A")
        let graph = try await original.createAppGroupGraph(id: id)
        let connection = try await original.connectCloud(using: cloud)
        for _ in 0..<200 {
            if try await connection.state == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await connection.bindPrivateGraph(graph, zoneName: "fixture")
        try await connection.close()
        try await graph.close()

        let writer = appGroupContext(group, role: .secondary, access: .readWrite)
        _ = try await writer.transactionAppGroupGraph(id: id) { try $0.insert(.init(id: node, type: "Note")) }

        let different = primary(account: "B")
        let isolated = try await different.openAppGroupGraph(id: id)
        for _ in 0..<200 {
            if try await isolated.cloudAccountState == .isolated(.differentAccount) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await isolated.cloudAccountState == .isolated(.differentAccount))
        await #expect {
            _ = try await isolated.read { try $0.record(for: node) }
        } throws: { error in
            if case .accountIsolated? = error as? GraphStoreError { return true }
            return false
        }
        try await isolated.close()

        let restarted = primary(account: "A")
        let recovered = try await restarted.openAppGroupGraph(id: id)
        for _ in 0..<200 {
            if try await recovered.cloudAccountState == .available { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await recovered.read { try $0.record(for: node)?.id } == node)
        let pending = try await recovered.prepareSyncBatch(maximumRecords: 2)
        #expect(pending.items.map(\.change.id) == [node])
        try await recovered.close()
    }

    @Test
    @available(iOS 17, macOS 14, *)
    func roleAdmissionAndScopedLocalAccess() async throws {
        let root = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = AppGroupStoreLocation(container: root)
        let id = GraphID(), node = GraphNodeID(graphID: id)
        let primary = appGroupContext(group, role: .primary, label: "host")
        let reader = appGroupContext(group, role: .secondary, label: "timeline")
        let writer = appGroupContext(group, role: .secondary, access: .readWrite, label: "action")
        let url = try reader.appGroupStoreURL(for: id)

        await #expect {
            _ = try await reader.readAppGroupGraph(id: id) { _ in Issue.record("Missing store entered the callback.") }
        } throws: { error in
            if case .missingStore? = error as? GraphStoreError { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        await #expect {
            _ = try await reader.createAppGroupGraph(id: id)
        } throws: { error in
            if case .permissionDenied? = error as? GraphStoreError { return true }
            return false
        }
        await #expect {
            _ = try await writer.openAppGroupGraph(id: id)
        } throws: { error in
            if case .permissionDenied? = error as? GraphStoreError { return true }
            return false
        }
        await #expect {
            _ = try await reader.transactionAppGroupGraph(id: id) { _ in Issue.record("Read-only context entered mutation.") }
        } throws: { error in
            if case .readOnly? = error as? GraphStoreError { return true }
            return false
        }
        await #expect {
            _ = try await primary.openGraph(id: id, at: url)
        } throws: { error in
            if case .unsupportedLayout? = error as? GraphStoreError { return true }
            return false
        }

        let graph = try await primary.createAppGroupGraph(id: id)
        try await graph.close()
        let committed = try await writer.transactionAppGroupGraph(id: id) {
            try $0.insert(GraphRecord(id: node, type: "Secondary"))
            return node
        }
        #expect(committed.value == node && !committed.closePending)
        let observed = try await reader.readAppGroupGraph(id: id) { try $0.record(for: node) }
        #expect(observed.value?.type == "Secondary" && !observed.closePending)

        let nativeReader = try await reader.manager.openGraph(id: id, at: url)
        await #expect {
            try await nativeReader.transaction { _ in Issue.record("Native read-only store entered mutation.") }
        } throws: { error in
            if case .readOnly? = error as? GraphStoreError { return true }
            return false
        }
        try await nativeReader.close()
        let renamed = appGroupContext(group, role: .primary, label: "another-host-label")
        let reopened = try await renamed.openAppGroupGraph(id: id)
        #expect(try await reopened.read { try $0.record(for: node)?.type } == "Secondary")
        try await reopened.close()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url.deletingLastPathComponent())
        await #expect(throws: (any Error).self) {
            _ = try await GraphContext().openGraph(id: id, at: alias.appendingPathComponent("Store.sqlite"))
        }
        let session = root.appendingPathComponent("Engine")
        let cloud = try GraphCloudConnectionConfiguration(containerIdentifier: "iCloud.AppGroupFixture",
            environment: .development, directory: session)
        await #expect {
            _ = try await primary.connectCloud(using: cloud)
        } throws: { error in
            if case .unsupportedLayout? = error as? GraphStoreError { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: session.path))

        let generation = UUID()
        let claim = url.deletingLastPathComponent().appendingPathComponent(".owners-v1").appendingPathComponent(generation.uuidString)
        let retiring: [String: Any] = ["graph": id.rawValue.uuidString, "generation": generation.uuidString, "retiring": true]
        try JSONSerialization.data(withJSONObject: retiring).write(to: claim)
        await #expect {
            _ = try await reader.readAppGroupGraph(id: id) { _ in Issue.record("Retiring store entered the callback.") }
        } throws: { error in
            if case .resourceReserved? = error as? GraphStoreError { return true }
            return false
        }
        #expect(FileManager.default.fileExists(atPath: claim.path))
    }

    @Test
    @available(iOS 17, macOS 14, *)
    func accountBoundStoreAllowsSecondaryLocalWriteAndPreservesPrimaryIsolation() async throws {
        let root = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = AppGroupStoreLocation(container: root)
        let id = GraphID(), packageContext = appGroupContext(group)
        let graph = try await packageContext.createGraph(id: id, at: packageContext.appGroupStoreURL(for: id))
        let entry = try #require(await packageContext.manager.entries[id])
        let owner = try await entry.opening.value
        try await owner.claimAccount(.init(container: "iCloud.AppGroupFixture", environment: .development, account: "fixture"))
        try await graph.close()

        let writer = appGroupContext(group, role: .secondary, access: .readWrite)
        let note = GraphNodeID(graphID: id)
        let saved = try await writer.transactionAppGroupGraph(id: id) { mutation in
            try mutation.insert(.init(id: note, type: "OfflineNote", properties: ["value": .integer(7)]))
        }
        #expect(saved.value == note)
        #expect(!saved.closePending)
        #expect(await writer.manager.cloudSessions.isEmpty)
        let localValue = try await writer.transactionAppGroupGraph(id: id) { try $0.record(for: note)?.properties["value"] }
        #expect(localValue.value == .integer(7))
        await #expect {
            _ = try await writer.readAppGroupGraph(id: id) { _ in Issue.record("Account-bound read entered the callback.") }
        } throws: { error in
            if case .accountIsolated? = error as? GraphStoreError { return true }
            return false
        }

        let reader = appGroupContext(group, role: .secondary)
        await #expect {
            _ = try await reader.readAppGroupGraph(id: id) { _ in Issue.record("Account-bound data entered the callback.") }
        } throws: { error in
            if case .accountIsolated? = error as? GraphStoreError { return true }
            return false
        }
        let primary = appGroupContext(group, role: .primary)
        await #expect {
            _ = try await primary.openAppGroupGraph(id: id)
        } throws: { error in
            if case .accountIsolated? = error as? GraphStoreError { return true }
            return false
        }
    }

    @Test
    @available(iOS 17, macOS 14, *)
    func cancellationRollsBackAndFailedDetachDoesNotConcealCommit() async throws {
        let root = try temporaryAppGroup()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = AppGroupStoreLocation(container: root)
        let id = GraphID(), primary = appGroupContext(group, role: .primary)
        let graph = try await primary.createAppGroupGraph(id: id)
        try await graph.close()

        let writer = appGroupContext(group, role: .secondary, access: .readWrite)
        let aborted = GraphNodeID(graphID: id), gate = CommitInterruption()
        let pending = Task {
            try await writer.transactionAppGroupGraph(id: id) {
                try $0.insert(GraphRecord(id: aborted, type: "Aborted"))
                gate.hold()
            }
        }
        await gate.reached.wait()
        pending.cancel()
        gate.resume.signal()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        let fresh = try await primary.openAppGroupGraph(id: id)
        #expect(try await fresh.read { try $0.record(for: aborted) } == nil)
        try await fresh.close()

        let committed = GraphNodeID(graphID: id), afterSave = CommitInterruption()
        let registry = StoreRegistry(hooks: .init(afterCommit: { afterSave.hold() }, beforeDetach: {
            throw StoreRuntimeError.resourceReserved
        }))
        let failing = appGroupContext(group, role: .secondary, access: .readWrite, registry: registry)
        let saving = Task {
            try await failing.transactionAppGroupGraph(id: id) {
                try $0.insert(GraphRecord(id: committed, type: "Committed"))
                return committed
            }
        }
        await afterSave.reached.wait()
        saving.cancel()
        afterSave.resume.signal()
        let result = try await saving.value
        #expect(result.value == committed && result.closePending)
        let owners = group.storeURL(for: id.rawValue).deletingLastPathComponent().appendingPathComponent(".owners-v1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: owners.path).count == 1)
    }
}

private func temporaryAppGroup() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

@available(iOS 17, macOS 14, *)
private func appGroupContext(_ group: AppGroupStoreLocation, role: GraphAppGroupConfiguration.Role? = nil,
                             access: GraphAppGroupConfiguration.SecondaryAccess = .readOnly, label: String? = nil,
                             registry: StoreRegistry = .shared) -> GraphContext {
    let configuration = role.map { GraphAppGroupConfiguration(identifier: "fixture", role: $0, secondaryAccess: access, diagnosticLabel: label) }
    return GraphContext(manager: GraphContextManager(registry: registry, schema: GraphRuntimeSchema.typedProperties,
        adapter: GraphCoordinatorFactory.adapter, contextOwnerID: UUID(), appGroup: group, publicAppGroup: configuration))
}
