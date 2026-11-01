import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime
@testable import GraphEvoModel

private actor ExportValidationGate {
    private var calls = 0
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func visit() async {
        calls += 1
        if calls == 2 {
            entered = true
            let waiting = waiters; waiters.removeAll(); for waiter in waiting { waiter.resume() }
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func waitForCopiedPackage() async {
        if !entered { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.timeLimit(.minutes(2))) struct GraphBackupPackageTests {
    private func manager() -> GraphContextManager {
        GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
    }
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GraphPackage-" + UUID().uuidString)
    }
    /// Reframe hostile test input, updating header checksums so payload/path validation is exercised.
    private func envelope(_ original: Data, manifest: Data? = nil, payload: Data? = nil) -> Data {
        let oldLength = original[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let json = manifest ?? original.subdata(in: 64..<(64 + Int(oldLength)))
        let body = payload ?? original.subdata(in: (64 + Int(oldLength))..<original.count)
        var data = Data(original.prefix(16))
        for value in [UInt64(json.count), UInt64(body.count)] {
            for byte in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        data.append(Data(SHA256.hash(data: json))); data.append(json); data.append(body)
        return data
    }

    @Test func compressedPackagesExportAndImportWithoutAnotherSnapshot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), id = GraphID(), graph = try await m.createGraph(id: id, at: root.appendingPathComponent("Source.sqlite"))
        let node = graph.makeNodeID(), file = graph.makeNodeID(), data = Data(repeating: 17, count: 2 * 1024 * 1024)
        _ = try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: node, type: "Item", properties: ["value": .integer(1)]))
            return try scope.insert(GraphAttachmentPayload(id: file, ownerID: node, fileName: "large.bin", contentType: "public.data", data: data))
        }
        let backup = try await m.createBackup(for: id, in: root.appendingPathComponent("Backups"), reason: "Before migration")
        #expect(backup.url.pathExtension == "geb")
        let bytes = try Data(contentsOf: backup.url)
        #expect(bytes.count < data.count / 2)
        _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: node, properties: ["value": .set(.integer(2))])) }
        let exported = try await m.backups.export(at: backup.url, to: root.appendingPathComponent("Exports/BeforeMigration.geb"))
        #expect(try Data(contentsOf: exported.url) == bytes)
        let recipient = manager()
        let imported = try await recipient.backups.importBackup(at: exported.url, in: root.appendingPathComponent("Received"))
        #expect(imported.manifest == backup.manifest)
        #expect(try await recipient.backups.list(in: root.appendingPathComponent("Received")).map(\.manifest.id) == [backup.manifest.id])
        let restored = try await recipient.backups.restore(at: imported.url, to: root.appendingPathComponent("Recovered"))
        let recovered = try await recipient.openGraph(id: id, at: restored.storeURL)
        #expect(try await recovered.read { try $0.record(for: node)?.properties["value"] } == .integer(1))
        #expect(try await recovered.attachment(file)?.data == data)
        #expect(try await recovered.collectSyncChanges() == 2)
        #expect(try await m.cloudSynchronizationState(for: id) == .active)
        #expect(try await recipient.backups.retentionOwners(at: imported.url).isEmpty)
        await #expect(throws: (any Error).self) { try await recipient.backups.importBackup(at: exported.url, in: root.appendingPathComponent("Received")) }
        #expect(try Data(contentsOf: imported.url) == bytes)
        try await recovered.close(); try await graph.close()
    }

    @Test func listingReadsOnlyManifestAndSkipsUnrelatedFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backups = root.appendingPathComponent("Backups"), backup = try await m.createBackup(for: graph.id, in: backups)
        var damaged = try Data(contentsOf: backup.url); damaged[damaged.count - 1] ^= 0xff
        try damaged.write(to: backup.url)
        try Data([1]).write(to: backups.appendingPathComponent("notes.txt"))
        #expect(try await m.backups.list(in: backups).map(\.manifest.id) == [backup.manifest.id])
        await #expect(throws: (any Error).self) { try await m.backups.verify(at: backup.url) }
        try await graph.close()
    }

    @Test(arguments: ["magic", "version", "algorithm", "manifest", "manifest-length", "truncated", "extended", "truncated-stream", "trailing-stream", "duplicate-stream"])
    func malformedPackageNeverPublishesRestoreOrImport(kind: String) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        var bytes = try Data(contentsOf: backup.url)
        switch kind {
        case "magic": bytes[0] ^= 1
        case "version": bytes[11] = 99
        case "algorithm": bytes[15] = 99
        case "manifest": bytes[64] ^= 1
        case "manifest-length": bytes.replaceSubrange(16..<24, with: Data(repeating: 0xff, count: 8))
        case "truncated": bytes.removeLast()
        case "extended": bytes.append(1)
        default:
            let length = bytes[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var body = bytes.subdata(in: (64 + Int(length))..<bytes.count)
            if kind == "truncated-stream" { body.removeLast() }
            else if kind == "duplicate-stream" { body.append(body) }
            else { body.append(Data([1,2,3])) }
            bytes = envelope(bytes, payload: body)
        }
        let invalid = root.appendingPathComponent("Invalid.geb"); try bytes.write(to: invalid)
        let destination = root.appendingPathComponent("Refused")
        await #expect(throws: (any Error).self) { try await m.backups.restore(at: invalid, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await #expect(throws: (any Error).self) { try await m.backups.importBackup(at: invalid, in: root.appendingPathComponent("Imported")) }
        #expect(try await m.backups.list(in: root.appendingPathComponent("Imported")).isEmpty)
        _ = try await m.backups.verify(at: backup.url)
        try await graph.close()
    }

    @Test(arguments: ["../outside", "payload/../outside", "payload/link/../../outside", "/payload/file"])
    func hostileManifestPathsAreRefusedBeforeExtraction(path: String) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup.manifest)) as? [String: Any])
        var files = try #require(raw["files"] as? [[String: Any]])
        files[0]["path"] = path; raw["files"] = files
        let malicious = envelope(try Data(contentsOf: backup.url), manifest: try JSONSerialization.data(withJSONObject: raw))
        let source = root.appendingPathComponent("Hostile.geb"); try malicious.write(to: source)
        await #expect(throws: (any Error).self) { try await m.backups.restore(at: source, to: root.appendingPathComponent("Output")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Output").path))
        try await graph.close()
    }

    @Test func extractionLimitsAndOverlappingExportAreRefused() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        var limits = GraphBackupLimits(); limits.maximumBytes = 1
        let bounded = GraphBackupManager(schemaIdentifier: backup.manifest.schemaIdentifier, limits: limits) { _, _ in
            Issue.record("An oversized inventory must be refused before native validation"); return "unexpected"
        }
        await #expect(throws: (any Error).self) { try await bounded.restore(at: backup.url, to: root.appendingPathComponent("Oversized")) }
        await #expect(throws: GraphBackupError.invalidDestination) { try await m.backups.export(at: backup.url, to: backup.url.appendingPathComponent("Child/Export.geb")) }
        let alias = root.appendingPathComponent("BackupAlias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup.url)
        await #expect(throws: GraphBackupError.invalidDestination) { try await m.backups.export(at: backup.url, to: alias.appendingPathComponent("Child/Export.geb")) }
        _ = try await m.backups.verify(at: backup.url)
        try await graph.close()
    }

    @Test func expandedPayloadCannotExceedDeclaredInventory() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup.manifest)) as? [String: Any])
        var files = try #require(raw["files"] as? [[String: Any]])
        for index in files.indices { files[index]["bytes"] = 0 }; raw["files"] = files
        let malicious = envelope(try Data(contentsOf: backup.url), manifest: try JSONSerialization.data(withJSONObject: raw))
        let source = root.appendingPathComponent("Expansion.geb"); try malicious.write(to: source)
        await #expect(throws: GraphBackupError.limitExceeded) { try await m.backups.restore(at: source, to: root.appendingPathComponent("Output")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Output").path))
        _ = try await m.backups.verify(at: backup.url)
        try await graph.close()
    }

    @Test func exportConvertsLegacyDirectoryAndSupportsSameRootDestination() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        let legacy = try await m.backups.restore(at: backup.url, to: root.appendingPathComponent("Legacy"))
        let result = try await m.backups.export(at: legacy.directory, to: root.appendingPathComponent("Legacy.geb"))
        #expect(try await m.backups.verify(at: result.url).manifest == backup.manifest)
        let sibling = try await m.backups.export(at: backup.url, to: backup.url.deletingLastPathComponent().appendingPathComponent("Sibling.geb"))
        #expect(try Data(contentsOf: sibling.url) == Data(contentsOf: backup.url))
        try await graph.close()
    }

    @Test func cancelledExportAfterCopyNeverPublishesOrReleasesSourceRetention() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let backup = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        let owner = UUID(), retention = try await m.backups.retain(at: backup.url, owner: owner)
        let gate = ExportValidationGate(), service = GraphBackupManager(schemaIdentifier: backup.manifest.schemaIdentifier) { _, _ in
            await gate.visit(); return backup.manifest.nativeStoreID
        }
        let destination = root.appendingPathComponent("Exports/Cancelled.geb")
        let operation = Task { try await service.export(at: backup.url, to: destination) }
        await gate.waitForCopiedPackage()
        _ = try await graph.transaction { _ in true }
        operation.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await service.list(in: destination.deletingLastPathComponent()).isEmpty)
        #expect(try await service.discardIncomplete(in: destination.deletingLastPathComponent()) == 0)
        #expect(try await m.backups.retentionOwners(at: backup.url) == [owner])
        _ = try await m.backups.verify(at: backup.url)
        await retention.release(); try await graph.close()
    }

    @Test(arguments: [false, true]) func rejectedLegacyImportCollectionPreservesSource(throughAlias: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let m = manager(), graph = try await m.createGraph(id: GraphID(), at: root.appendingPathComponent("Source.sqlite"))
        let package = try await m.createBackup(for: graph.id, in: root.appendingPathComponent("Backups"))
        let legacy = try await m.backups.restore(at: package.url, to: root.appendingPathComponent("Legacy"))
        let alias = root.appendingPathComponent("Alias")
        if throughAlias { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: legacy.directory) }
        let collection = (throughAlias ? alias : legacy.directory).appendingPathComponent("Nested/Collection")
        let before = try FileManager.default.contentsOfDirectory(atPath: legacy.directory.path).sorted()
        await #expect(throws: GraphBackupError.invalidDestination) { try await m.backups.importBackup(at: legacy.directory, in: collection) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: legacy.directory.path).sorted() == before)
        #expect(!FileManager.default.fileExists(atPath: legacy.directory.appendingPathComponent("Nested").path))
        _ = try await m.backups.verify(at: legacy.directory)
        try await graph.close()
    }
}
