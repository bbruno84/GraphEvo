import CoreData
import CryptoKit
import Darwin
import Foundation
import GraphEvoModel
import GraphEvoRuntime

package enum GraphBackupError: Error { case busy, invalidReason, invalidBackup, invalidDestination, limitExceeded, retained }
package struct GraphBackupArtifact: Sendable {
    package let name: String
    package let data: Data
    package init(name: String, data: Data) { self.name = name; self.data = data }
}
package struct GraphBackupLimits: Sendable {
    package var maximumFiles = 100_000
    package var maximumBytes: UInt64 = 64 * 1024 * 1024 * 1024
    package var maximumPackageBytes: UInt64 = 65 * 1024 * 1024 * 1024
    package init() {}
}
package struct GraphBackupFile: Codable, Equatable, Sendable {
    package let path: String
    package let bytes: UInt64
    package let sha256: String
}
package struct GraphBackupManifest: Codable, Equatable, Sendable {
    package let format: Int
    package let id: UUID
    package let graphID: GraphID
    package let nativeStoreID: String
    package let schemaIdentifier: String
    package let createdAt: Date
    package let reason: String?
    package let storePath: String
    package let files: [GraphBackupFile]
}
package struct GraphBackup: Sendable {
    package let url: URL
    package let manifest: GraphBackupManifest
}
package struct GraphRestoredBackup: Sendable {
    package let directory: URL
    package let manifest: GraphBackupManifest
    package var storeURL: URL { directory.appendingPathComponent(manifest.storePath) }
}

/// Graph-specific recovery evidence, never an instruction to rewind shared engine/session state.
struct GraphCloudBackupSnapshot: Codable, Sendable {
    let format: Int
    let capturedAt: Date
    let identity: GraphCloudSessionIdentity
    let binding: GraphCloudBinding?
    let membership: GraphCloudMembership?
    let inbox: [GraphCloudInboxEntry]
    let receipts: [GraphCloudSentReceipt]
    var ledger: GraphLedgerReplica? = nil
}

/// One service for verified immutable bundles. Restore materializes an empty local destination;
/// activating or replacing a synchronized graph belongs to the migration executor.
package actor GraphBackupManager {
    typealias Validator = @Sendable (URL, GraphID) async throws -> String
    private let validateNative: Validator
    private let schemaIdentifier: String
    private let limits: GraphBackupLimits
    private struct Intent: Codable { let format: Int; let id: UUID; let backupID: UUID }
    private struct Retention: Codable { let format: Int; let backupID: UUID; var owners: Set<UUID> }

    init(schemaIdentifier: String, limits: GraphBackupLimits = .init(), validate: @escaping Validator) {
        self.schemaIdentifier = schemaIdentifier; self.limits = limits; validateNative = validate
    }

    func create(for graphID: GraphID, storeID: String, schema: String, in root: URL,
                reason: String?, artifacts: [GraphBackupArtifact],
                copy: @Sendable (URL) async throws -> Void) async throws -> GraphBackup {
        if let reason {
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.utf8.count <= 4096 else { throw GraphBackupError.invalidReason }
        }
        guard schema == schemaIdentifier, Set(artifacts.map(\.name)).count == artifacts.count,
              artifacts.allSatisfy({ Self.component($0.name) }) else { throw GraphBackupError.invalidBackup }
        let root = try Self.directory(root), lease = try BackupRootLease(root)
        defer { lease.release() }
        let id = UUID(), stage = root.appendingPathComponent(".stage-" + id.uuidString)
        let destination = root.appendingPathComponent(id.uuidString).appendingPathExtension(GraphBackupPackage.fileExtension)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try JSONEncoder().encode(Intent(format: 1, id: id, backupID: id)).write(to: stage.appendingPathComponent("intent.json"), options: .atomic)
        let payload = stage.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let store = payload.appendingPathComponent("Graph.sqlite")
        try await copy(store)
        try Task.checkCancellation()
        if !artifacts.isEmpty {
            let directory = stage.appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for artifact in artifacts {
                try artifact.data.write(to: directory.appendingPathComponent(artifact.name), options: .withoutOverwriting)
            }
        }
        let files = try inventory(stage)
        let manifest = GraphBackupManifest(format: 1, id: id, graphID: graphID, nativeStoreID: storeID,
            schemaIdentifier: schema, createdAt: Date(), reason: reason, storePath: "payload/Graph.sqlite", files: files)
        let archive = stage.appendingPathComponent("Archive.geb")
        let limits = limits
        try await GraphBackupPackage.perform { try GraphBackupPackage.pack(stage, manifest: manifest, to: archive, limits: limits) }
        try await validate(archive, manifest: manifest)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: archive, to: destination)
        return GraphBackup(url: destination, manifest: manifest)
    }

    package func list(in root: URL) throws -> [GraphBackup] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let root = try Self.directory(root), lease = try BackupRootLease(root)
        defer { lease.release() }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") &&
                ($0.pathExtension.lowercased() == GraphBackupPackage.fileExtension ||
                 FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)) }
            .map { GraphBackup(url: $0, manifest: try readManifest($0)) }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    package func verify(at directory: URL) async throws -> GraphBackup {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let lease = try BackupRootLease(directory.deletingLastPathComponent()); defer { lease.release() }
        let manifest = try readManifest(directory)
        try await validate(directory, manifest: manifest)
        return GraphBackup(url: directory, manifest: manifest)
    }

    /// No existing file, graph, cloud cursor or session is replaced by this operation.
    package func restore(at backup: URL, to destination: URL) async throws -> GraphRestoredBackup {
        let backup = backup.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else { throw GraphBackupError.invalidDestination }
        // Validate containment before directory creation can alter the immutable source.
        let candidate = try Self.creationLocation(destination.deletingLastPathComponent())
        guard candidate.path != backup.path, !candidate.path.hasPrefix(backup.path + "/") else { throw GraphBackupError.invalidDestination }
        let parent = try Self.directory(candidate)
        guard parent != backup, !parent.path.hasPrefix(backup.path + "/") else { throw GraphBackupError.invalidDestination }
        let sourceRoot = backup.deletingLastPathComponent(), first = try BackupRootLease(sourceRoot)
        defer { first.release() }
        let second = parent.path == sourceRoot.path ? nil : try BackupRootLease(parent)
        defer { second?.release() }
        let manifest = try readManifest(backup)
        try await validate(backup, manifest: manifest)
        let id = UUID(), stage = parent.appendingPathComponent(".stage-" + id.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }
        try JSONEncoder().encode(Intent(format: 1, id: id, backupID: manifest.id)).write(to: stage.appendingPathComponent("intent.json"), options: .atomic)
        if try Self.isPackage(backup) {
            let limits = limits
            _ = try await GraphBackupPackage.perform { try GraphBackupPackage.unpack(backup, to: stage, limits: limits) }
        } else {
            for name in ["payload", "artifacts", "manifest.json"] {
                let source = backup.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent(name)) }
            }
        }
        try await validate(stage, manifest: manifest)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        published = true
        return GraphRestoredBackup(directory: destination, manifest: manifest)
    }

    /// Export reuses a completed package; it never takes another live graph snapshot.
    package func export(at source: URL, to destination: URL) async throws -> GraphBackup {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, destination.query == nil, destination.fragment == nil,
              destination.pathExtension.lowercased() == GraphBackupPackage.fileExtension,
              !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else { throw GraphBackupError.invalidDestination }
        let candidate = try Self.creationLocation(destination.deletingLastPathComponent())
        guard candidate.path != source.path, !candidate.path.hasPrefix(source.path + "/") else { throw GraphBackupError.invalidDestination }
        let parent = try Self.directory(candidate), sourceRoot = source.deletingLastPathComponent()
        let first = try BackupRootLease(sourceRoot); defer { first.release() }
        let second = parent.path == sourceRoot.path ? nil : try BackupRootLease(parent); defer { second?.release() }
        let manifest = try readManifest(source)
        try await validate(source, manifest: manifest)
        let id = UUID(), stage = parent.appendingPathComponent(".stage-" + id.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try JSONEncoder().encode(Intent(format: 1, id: id, backupID: manifest.id)).write(to: stage.appendingPathComponent("intent.json"), options: .atomic)
        let archive = stage.appendingPathComponent("Archive.geb"), limits = limits
        let packaged = try Self.isPackage(source)
        try await GraphBackupPackage.perform {
            if packaged { try GraphBackupPackage.copy(source, to: archive, maximumBytes: limits.maximumPackageBytes) }
            else { try GraphBackupPackage.pack(source, manifest: manifest, to: archive, limits: limits) }
        }
        try await validate(archive, manifest: manifest)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: archive, to: destination)
        return GraphBackup(url: destination, manifest: manifest)
    }

    /// Import a package into the local backup collection, without activating any graph/cloud state.
    package func importBackup(at source: URL, in root: URL) async throws -> GraphBackup {
        let manifest = try readManifest(source)
        // Export validates the complete destination before creating its parent collection.
        return try await export(at: source, to: root.appendingPathComponent(manifest.id.uuidString).appendingPathExtension(GraphBackupPackage.fileExtension))
    }

    package func retain(at directory: URL, owner: UUID = UUID()) throws -> StoreReservation {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let lease = try BackupRootLease(directory.deletingLastPathComponent()); defer { lease.release() }
        let manifest = try readManifest(directory)
        guard !directory.lastPathComponent.hasPrefix(".") else { throw GraphBackupError.invalidBackup }
        var retention = try readRetention(directory, id: manifest.id)
        guard retention.owners.count < 1024, retention.owners.insert(owner).inserted else { throw GraphBackupError.retained }
        try writeRetention(retention, directory: directory)
        return StoreReservation(id: owner) { try? await self.releaseRetention(at: directory, owner: owner) }
    }
    package func retentionOwners(at directory: URL) throws -> Set<UUID> {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let lease = try BackupRootLease(directory.deletingLastPathComponent()); defer { lease.release() }
        return try readRetention(directory, id: readManifest(directory).id).owners
    }
    package func releaseRetention(at directory: URL, owner: UUID) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let lease = try BackupRootLease(directory.deletingLastPathComponent()); defer { lease.release() }
        let manifest = try readManifest(directory)
        var retention = try readRetention(directory, id: manifest.id)
        if retention.owners.remove(owner) != nil { try writeRetention(retention, directory: directory) }
    }
    package func remove(at directory: URL) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let lease = try BackupRootLease(directory.deletingLastPathComponent()); defer { lease.release() }
        let manifest = try readManifest(directory)
        guard try readRetention(directory, id: manifest.id).owners.isEmpty else { throw GraphBackupError.retained }
        try FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: retentionURL(directory, id: manifest.id))
    }
    private func retentionURL(_ directory: URL, id: UUID) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(".retention-" + id.uuidString + ".json")
    }
    private func readRetention(_ directory: URL, id: UUID) throws -> Retention {
        let url = retentionURL(directory, id: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw GraphBackupError.invalidBackup }
            return Retention(format: 1, backupID: id, owners: [])
        }
        let value = try JSONDecoder().decode(Retention.self, from: Self.smallData(url, maximum: 128 * 1024))
        guard value.format == 1, value.backupID == id, value.owners.count <= 1024 else { throw GraphBackupError.invalidBackup }
        return value
    }
    private func writeRetention(_ value: Retention, directory: URL) throws {
        try JSONEncoder().encode(value).write(to: retentionURL(directory, id: value.backupID), options: .atomic)
    }

    /// Recover only explicitly owned incomplete stages; final backups are never touched.
    package func discardIncomplete(in root: URL) throws -> Int {
        let root = try Self.directory(root), lease = try BackupRootLease(root); defer { lease.release() }
        var removed = 0
        for stage in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where stage.lastPathComponent.hasPrefix(".stage-") {
            guard try Self.attributes(stage)[.type] as? FileAttributeType == .typeDirectory else { throw GraphBackupError.invalidBackup }
            if try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty,
               UUID(uuidString: String(stage.lastPathComponent.dropFirst(7))) != nil {
                try FileManager.default.removeItem(at: stage); removed += 1; continue
            }
            let data = try Self.smallData(stage.appendingPathComponent("intent.json"), maximum: 1024)
            let intent = try JSONDecoder().decode(Intent.self, from: data)
            guard intent.format == 1, stage.lastPathComponent == ".stage-" + intent.id.uuidString else { throw GraphBackupError.invalidBackup }
            try FileManager.default.removeItem(at: stage); removed += 1
        }
        return removed
    }

    private func readManifest(_ directory: URL) throws -> GraphBackupManifest {
        if try Self.isPackage(directory) {
            let manifest = try GraphBackupPackage.header(at: directory, limits: limits).manifest
            try checkManifest(manifest)
            return manifest
        }
        guard try Self.attributes(directory)[.type] as? FileAttributeType == .typeDirectory else { throw GraphBackupError.invalidBackup }
        let manifest = try JSONDecoder().decode(GraphBackupManifest.self,
            from: Self.smallData(directory.appendingPathComponent("manifest.json"), maximum: 4 * 1024 * 1024))
        try checkManifest(manifest)
        let intent = try JSONDecoder().decode(Intent.self, from: Self.smallData(directory.appendingPathComponent("intent.json"), maximum: 1024))
        guard intent.format == 1, intent.backupID == manifest.id else { throw GraphBackupError.invalidBackup }
        return manifest
    }
    private func checkManifest(_ manifest: GraphBackupManifest) throws {
        guard manifest.format == 1, manifest.storePath == "payload/Graph.sqlite", !manifest.nativeStoreID.isEmpty,
              manifest.schemaIdentifier == schemaIdentifier, manifest.files.count <= limits.maximumFiles,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.contains(where: { $0.path == manifest.storePath }),
              manifest.files.allSatisfy({ Self.relative($0.path) && $0.sha256.count == 64 }) else { throw GraphBackupError.invalidBackup }
    }
    private func validate(_ directory: URL, manifest: GraphBackupManifest) async throws {
        if try Self.isPackage(directory) {
            let limits = limits, native = validateNative
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackupVerify-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            var detached = true
            defer { if detached { try? FileManager.default.removeItem(at: scratch) } }
            let before = try await GraphBackupPackage.perform { try Self.digest(directory) }
            let decoded = try await GraphBackupPackage.perform { try GraphBackupPackage.unpack(directory, to: scratch, limits: limits) }
            guard decoded == manifest, try inventory(scratch) == manifest.files else { throw GraphBackupError.invalidBackup }
            do {
                guard try await native(scratch.appendingPathComponent(manifest.storePath), manifest.graphID) == manifest.nativeStoreID else { throw GraphBackupError.invalidBackup }
            } catch {
                if case StoreRuntimeError.shutdownFailed = error { detached = false }
                throw error
            }
            guard try await GraphBackupPackage.perform({ try Self.digest(directory) }) == before else { throw GraphBackupError.invalidBackup }
            return
        }
        guard try inventory(directory) == manifest.files else { throw GraphBackupError.invalidBackup }
        // Native validation uses a disposable copy: read-only SQLite can still create/change sidecars.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackupVerify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        var detached = true
        defer { if detached { try? FileManager.default.removeItem(at: scratch) } }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("payload"), to: scratch.appendingPathComponent("payload"))
        do {
            guard try await validateNative(scratch.appendingPathComponent(manifest.storePath), manifest.graphID) == manifest.nativeStoreID else { throw GraphBackupError.invalidBackup }
        } catch {
            if case StoreRuntimeError.shutdownFailed = error { detached = false }
            throw error
        }
        guard try inventory(directory) == manifest.files else { throw GraphBackupError.invalidBackup }
    }
    private func inventory(_ directory: URL) throws -> [GraphBackupFile] {
        var files: [GraphBackupFile] = [], bytes: UInt64 = 0, visited = 0
        func walk(_ current: URL, path: String) throws {
            try Task.checkCancellation()
            visited += 1
            guard visited <= limits.maximumFiles, path.split(separator: "/").count <= 64 else { throw GraphBackupError.limitExceeded }
            let attributes = try Self.attributes(current)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                for child in try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) {
                    try walk(child, path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent)
                }
            case .typeRegular:
                guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1, Self.relative(path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      size <= limits.maximumBytes - min(bytes, limits.maximumBytes), files.count < limits.maximumFiles else { throw GraphBackupError.limitExceeded }
                bytes += size
                files.append(GraphBackupFile(path: path, bytes: size, sha256: try Self.digest(current)))
            default: throw GraphBackupError.invalidBackup
            }
        }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if ["manifest.json", "intent.json"].contains(child.lastPathComponent) { continue }
            guard ["payload", "artifacts"].contains(child.lastPathComponent) else { throw GraphBackupError.invalidBackup }
            try walk(child, path: child.lastPathComponent)
        }
        return files.sorted { $0.path < $1.path }
    }
    private static func isPackage(_ url: URL) throws -> Bool {
        try attributes(url)[.type] as? FileAttributeType == .typeRegular
    }
    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] { try FileManager.default.attributesOfItem(atPath: url.path) }
    private static func smallData(_ url: URL, maximum: UInt64) throws -> Data {
        let a = try attributes(url)
        guard a[.type] as? FileAttributeType == .typeRegular, (a[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (a[.size] as? NSNumber)?.uint64Value, size <= maximum else { throw GraphBackupError.invalidBackup }
        return try Data(contentsOf: url)
    }
    private static func directory(_ url: URL) throws -> URL {
        guard url.isFileURL, url.query == nil, url.fragment == nil else { throw GraphBackupError.invalidDestination }
        let result = url.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        guard try attributes(result)[.type] as? FileAttributeType == .typeDirectory else { throw GraphBackupError.invalidDestination }
        return result
    }
    /// Resolve the existing ancestor before appending missing components: Foundation cannot
    /// resolve an intermediate symlink when the complete requested path does not exist.
    private static func creationLocation(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/",
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw GraphBackupError.invalidDestination
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for name in missing.reversed() { result.appendPathComponent(name) }
        return result
    }
    private static func component(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0") && value.utf8.count <= 255
    }
    private static func relative(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > 1 && ["payload", "artifacts"].contains(String(parts[0])) && parts.allSatisfy { component(String($0)) }
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A stable root lock prevents another service/process from deleting an active stage or bundle.
private final class BackupRootLease: @unchecked Sendable {
    private var descriptor: Int32
    init(_ root: URL) throws {
        descriptor = Darwin.open(root.appendingPathComponent(".graphevo-backups.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GraphBackupError.invalidDestination }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); descriptor = -1; throw GraphBackupError.busy }
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { release() }
}
