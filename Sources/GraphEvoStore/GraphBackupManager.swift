import CoreData
import CryptoKit
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
    private let validateMigrationSource: Validator?
    private let migrationSourceSchemaIdentifier: String?
    private let schemaIdentifier: String
    private let limits: GraphBackupLimits
    private struct Intent: Codable { let format: Int; let id: UUID; let backupID: UUID }
    private struct Retention: Codable { let format: Int; let backupID: UUID; var owners: Set<UUID> }

    init(schemaIdentifier: String, limits: GraphBackupLimits = .init(), migrationSourceSchemaIdentifier: String? = nil, validateMigrationSource: Validator? = nil, validate: @escaping Validator) {
        self.schemaIdentifier = schemaIdentifier; self.limits = limits; validateNative = validate
        self.migrationSourceSchemaIdentifier = migrationSourceSchemaIdentifier; self.validateMigrationSource = validateMigrationSource
    }

    func create(for graphID: GraphID, storeID: String, schema: String, in root: URL,
                reason: String?, artifacts: [GraphBackupArtifact], backupID: UUID? = nil, retentionOwner: UUID? = nil, immutableArtifact: String = "__graphevo_publication.json",
                copy: @Sendable (URL) async throws -> Void) async throws -> GraphBackup {
        if let reason {
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.utf8.count <= 4096 else { throw GraphBackupError.invalidReason }
        }
        guard accepts(schema), Set(artifacts.map(\.name)).count == artifacts.count,
              artifacts.allSatisfy({ Self.component($0.name) }) else { throw GraphBackupError.invalidBackup }
        let root = try Self.directory(root)
        let id = backupID ?? UUID()
        let destination = root.appendingPathComponent(id.uuidString).appendingPathExtension(GraphBackupPackage.fileExtension)
        let manifest = try await withStage(in: root) { stage in
            let alreadyExists = try await Self.catalog([.read(root)]) {
                FileManager.default.fileExists(atPath: destination.path)
            }
            if alreadyExists { return nil as GraphBackupManifest? }
            let payload = stage.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            try await copy(payload.appendingPathComponent("Graph.sqlite"))
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
            let archive = stage.appendingPathComponent("Archive.geb"), limits = limits
            try await GraphBackupPackage.perform { try GraphBackupPackage.pack(stage, manifest: manifest, to: archive, limits: limits) }
            try await validate(archive, manifest: manifest)
            return try await Self.catalog([.write(root)]) {
                if FileManager.default.fileExists(atPath: destination.path) { return nil }
                if let retentionOwner { try self.pin(destination, id: id, owner: retentionOwner) }
                try Self.publish(archive, to: destination)
                return manifest
            }
        }
        if let manifest { return GraphBackup(url: destination, manifest: manifest) }
        guard backupID != nil else { throw GraphBackupError.invalidDestination }
        return try await withStage(in: root) { stage in
            let archive = stage.appendingPathComponent("Archive.geb")
            let (manifest, identity) = try await snapshot(destination, to: archive)
            guard manifest.id == id, manifest.graphID == graphID, manifest.nativeStoreID == storeID,
                  manifest.schemaIdentifier == schema, manifest.reason == reason,
                  let intent = artifacts.first(where: { $0.name == immutableArtifact }),
                  manifest.files.contains(where: { $0.path == "artifacts/" + intent.name &&
                    $0.sha256 == SHA256.hash(data: intent.data).map { String(format: "%02x", $0) }.joined() }) else {
                throw GraphBackupError.invalidBackup
            }
            try await validate(archive, manifest: manifest)
            return try await Self.catalog([.write(root)]) {
                guard try FileIdentity(destination) == identity else { throw GraphBackupError.invalidBackup }
                if let retentionOwner { try self.pin(destination, id: id, owner: retentionOwner) }
                return GraphBackup(url: destination, manifest: manifest)
            }
        }
    }

    package func list(in root: URL) async throws -> [GraphBackup] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let root = try Self.directory(root)
        return try await Self.catalog([.read(root)]) {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") &&
                    ($0.pathExtension.lowercased() == GraphBackupPackage.fileExtension ||
                     FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)) }
                .map { GraphBackup(url: $0, manifest: try self.readManifest($0)) }
                .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
        }
    }

    package func verify(at directory: URL) async throws -> GraphBackup {
        let source = directory.standardizedFileURL.resolvingSymlinksInPath()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GraphBackupSnapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("Archive.geb")
        let (manifest, identity) = try await snapshot(source, to: archive)
        try await validate(archive, manifest: manifest)
        return try await Self.catalog([.read(source.deletingLastPathComponent())]) {
            guard try FileIdentity(source) == identity else { throw GraphBackupError.invalidBackup }
            return GraphBackup(url: source, manifest: manifest)
        }
    }

    /// Materializes and verifies a private snapshot before publishing an empty destination.
    package func restore(at backup: URL, to destination: URL) async throws -> GraphRestoredBackup {
        let backup = backup.standardizedFileURL.resolvingSymlinksInPath()
        let target = try Self.destination(destination, outside: backup)
        return try await withStage(in: target.deletingLastPathComponent()) { stage in
            let archive = stage.appendingPathComponent("Archive.geb")
            let (manifest, _) = try await snapshot(backup, to: archive)
            let restored = stage.appendingPathComponent("Restored")
            try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
            let limits = limits
            let decoded = try await GraphBackupPackage.perform { try GraphBackupPackage.unpack(archive, to: restored, limits: limits) }
            guard decoded == manifest else { throw GraphBackupError.invalidBackup }
            try JSONEncoder().encode(Intent(format: 1, id: UUID(), backupID: manifest.id))
                .write(to: restored.appendingPathComponent("intent.json"), options: .atomic)
            try await validate(restored, manifest: manifest)
            return try await Self.catalog([.write(target.deletingLastPathComponent())]) {
                try Self.publish(restored, to: target)
                return GraphRestoredBackup(directory: target, manifest: manifest)
            }
        }
    }

    package func export(at source: URL, to destination: URL) async throws -> GraphBackup {
        try await export(at: source, to: destination, expectedBackupID: nil)
    }

    private func export(at source: URL, to destination: URL, expectedBackupID: UUID?) async throws -> GraphBackup {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.pathExtension.lowercased() == GraphBackupPackage.fileExtension else { throw GraphBackupError.invalidDestination }
        let target = try Self.destination(destination, outside: source)
        return try await withStage(in: target.deletingLastPathComponent()) { stage in
            let archive = stage.appendingPathComponent("Archive.geb")
            let (manifest, _) = try await snapshot(source, to: archive)
            guard expectedBackupID == nil || expectedBackupID == manifest.id else { throw GraphBackupError.invalidBackup }
            try await validate(archive, manifest: manifest)
            return try await Self.catalog([.write(target.deletingLastPathComponent())]) {
                try Self.publish(archive, to: target)
                return GraphBackup(url: target, manifest: manifest)
            }
        }
    }

    package func importBackup(at source: URL, in root: URL) async throws -> GraphBackup {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let id = try await Self.catalog([.read(source.deletingLastPathComponent())]) { try self.readManifest(source).id }
        return try await export(at: source, to: root.appendingPathComponent(id.uuidString)
            .appendingPathExtension(GraphBackupPackage.fileExtension), expectedBackupID: id)
    }

    package func retain(at directory: URL, owner: UUID = UUID()) async throws -> StoreReservation {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try await Self.catalog([.write(directory.deletingLastPathComponent())]) {
            let manifest = try self.readManifest(directory)
            guard !directory.lastPathComponent.hasPrefix(".") else { throw GraphBackupError.invalidBackup }
            var retention = try self.readRetention(directory, id: manifest.id)
            guard retention.owners.count < 1024, retention.owners.insert(owner).inserted else { throw GraphBackupError.retained }
            try self.writeRetention(retention, directory: directory)
        }
        return StoreReservation(id: owner) { try? await self.releaseRetention(at: directory, owner: owner) }
    }

    package func retentionOwners(at directory: URL) async throws -> Set<UUID> {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        return try await Self.catalog([.read(directory.deletingLastPathComponent())]) {
            try self.readRetention(directory, id: self.readManifest(directory).id).owners
        }
    }

    package func releaseRetention(at directory: URL, owner: UUID) async throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try await Self.catalog([.write(directory.deletingLastPathComponent())]) {
            let manifest = try self.readManifest(directory)
            var retention = try self.readRetention(directory, id: manifest.id)
            if retention.owners.remove(owner) != nil { try self.writeRetention(retention, directory: directory) }
        }
    }

    package func remove(at directory: URL) async throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try await Self.catalog([.write(directory.deletingLastPathComponent())]) {
            let manifest = try self.readManifest(directory)
            guard try self.readRetention(directory, id: manifest.id).owners.isEmpty else { throw GraphBackupError.retained }
            try FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: self.retentionURL(directory, id: manifest.id))
        }
    }

    /// Called under the catalog grant before the package becomes visible.
    private nonisolated func pin(_ directory: URL, id: UUID, owner: UUID) throws {
        var value = try readRetention(directory, id: id)
        guard value.owners.count < 1024 || value.owners.contains(owner) else { throw GraphBackupError.limitExceeded }
        value.owners.insert(owner)
        try writeRetention(value, directory: directory)
    }
    private nonisolated func retentionURL(_ directory: URL, id: UUID) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(".retention-" + id.uuidString + ".json")
    }
    private nonisolated func readRetention(_ directory: URL, id: UUID) throws -> Retention {
        let url = retentionURL(directory, id: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw GraphBackupError.invalidBackup }
            return Retention(format: 1, backupID: id, owners: [])
        }
        let value = try JSONDecoder().decode(Retention.self, from: Self.smallData(url, maximum: 128 * 1024))
        guard value.format == 1, value.backupID == id, value.owners.count <= 1024 else { throw GraphBackupError.invalidBackup }
        return value
    }
    private nonisolated func writeRetention(_ value: Retention, directory: URL) throws {
        try JSONEncoder().encode(value).write(to: retentionURL(directory, id: value.backupID), options: .atomic)
    }

    /// Recover only explicitly owned incomplete stages; final backups are never touched.
    package func discardIncomplete(in root: URL) async throws -> Int {
        let root = try Self.directory(root)
        let stages = try await Self.catalog([.read(root)]) {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".stage-") }
                .compactMap { stage -> (URL, FileIdentity)? in
                    do { return (stage, try FileIdentity(stage)) }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
                }
        }
        var removed = 0
        for (stage, identity) in stages {
            do {
                let didRemove = try await CoordinatedFiles.run([.delete(stage)]) {
                    guard FileManager.default.fileExists(atPath: stage.path),
                          try FileIdentity(stage).sameFile(as: identity) else { return false }
                    guard try Self.attributes(stage)[.type] as? FileAttributeType == .typeDirectory,
                          let id = UUID(uuidString: String(stage.lastPathComponent.dropFirst(7))),
                          stage.lastPathComponent == ".stage-" + id.uuidString else { throw GraphBackupError.invalidBackup }
                    let children = try FileManager.default.contentsOfDirectory(atPath: stage.path)
                    if !children.isEmpty {
                        let data = try Self.smallData(stage.appendingPathComponent("intent.json"), maximum: 1024)
                        let intent = try JSONDecoder().decode(Intent.self, from: data)
                        guard intent.format == 1, intent.id == id else { throw GraphBackupError.invalidBackup }
                    }
                    try FileManager.default.removeItem(at: stage)
                    return true
                }
                if didRemove { removed += 1 }
            } catch is CoordinatedFiles.Denied {
                // An active stage's presenter refused deletion.
            }
        }
        return removed
    }

    private static func catalog<Value: Sendable>(_ accesses: [CoordinatedFiles.Access],
                                                   _ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        do { return try await CoordinatedFiles.run(accesses, body) }
        catch is CoordinatedFiles.Denied { throw GraphBackupError.busy }
    }

    private func withStage<Value: Sendable>(in root: URL, _ operation: (URL) async throws -> Value) async throws -> Value {
        let id = UUID()
        let stage = root.appendingPathComponent(".stage-" + id.uuidString)
        let presenter = BackupStagePresenter(stage)
        let identity = try await Self.catalog([.write(root)]) {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            do {
                try JSONEncoder().encode(Intent(format: 1, id: id, backupID: id))
                    .write(to: stage.appendingPathComponent("intent.json"), options: .atomic)
                let identity = try FileIdentity(stage)
                NSFileCoordinator.addFilePresenter(presenter)
                return identity
            } catch {
                try? FileManager.default.removeItem(at: stage)
                throw error
            }
        }
        let result: Result<Value, any Error>
        do { result = .success(try await operation(stage)) }
        catch { result = .failure(error) }
        // Cleanup must still run when the caller cancels. Keep the presenter
        // registered until the coordinated cleanup ends.
        await Task {
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            _ = try? await CoordinatedFiles.run([.write(root)], presenter: presenter) {
                if (try? FileIdentity(stage).sameFile(as: identity)) == true {
                    try FileManager.default.removeItem(at: stage)
                }
            }
        }.value
        return try result.get()
    }

    private func snapshot(_ source: URL, to archive: URL) async throws -> (GraphBackupManifest, FileIdentity) {
        try await Self.catalog([.read(source.deletingLastPathComponent())]) {
            let identity = try FileIdentity(source)
            let manifest = try self.readManifest(source)
            if try Self.isPackage(source) {
                try GraphBackupPackage.copy(source, to: archive, maximumBytes: self.limits.maximumPackageBytes)
            } else {
                guard try self.inventory(source) == manifest.files else { throw GraphBackupError.invalidBackup }
                try GraphBackupPackage.pack(source, manifest: manifest, to: archive, limits: self.limits)
            }
            return (manifest, identity)
        }
    }

    private static func destination(_ destination: URL, outside source: URL) throws -> URL {
        let requested = destination.standardizedFileURL
        guard requested.isFileURL, requested.query == nil, requested.fragment == nil,
              !FileManager.default.fileExists(atPath: requested.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: requested.path)) == nil else {
            throw GraphBackupError.invalidDestination
        }
        let candidate = try Self.creationLocation(requested.deletingLastPathComponent())
        guard candidate.path != source.path, !candidate.path.hasPrefix(source.path + "/") else {
            throw GraphBackupError.invalidDestination
        }
        let parent = try Self.directory(candidate)
        return parent.appendingPathComponent(requested.lastPathComponent)
    }

    private static func publish(_ stage: URL, to destination: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path),
              (try? files.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw GraphBackupError.invalidDestination
        }
        try files.moveItem(at: stage, to: destination)
    }

    private struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ url: URL) throws {
            let attributes = try GraphBackupManager.attributes(url)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw GraphBackupError.invalidBackup }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }

        func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    private nonisolated func readManifest(_ directory: URL) throws -> GraphBackupManifest {
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
    private nonisolated func checkManifest(_ manifest: GraphBackupManifest) throws {
        guard manifest.format == 1, manifest.storePath == "payload/Graph.sqlite", !manifest.nativeStoreID.isEmpty,
              accepts(manifest.schemaIdentifier), manifest.files.count <= limits.maximumFiles,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.contains(where: { $0.path == manifest.storePath }),
              manifest.files.allSatisfy({ Self.relative($0.path) && $0.sha256.count == 64 }) else { throw GraphBackupError.invalidBackup }
    }
    private nonisolated func accepts(_ schema: String) -> Bool {
        schema == schemaIdentifier || (schema == migrationSourceSchemaIdentifier && validateMigrationSource != nil)
    }
    private func validator(_ schema: String) -> Validator {
        if schema == schemaIdentifier { return validateNative }
        if schema == migrationSourceSchemaIdentifier, let validateMigrationSource { return validateMigrationSource }
        return validateNative
    }
    private func validate(_ directory: URL, manifest: GraphBackupManifest) async throws {
        if try Self.isPackage(directory) {
            let limits = limits, native = validator(manifest.schemaIdentifier)
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
            guard try await validator(manifest.schemaIdentifier)(scratch.appendingPathComponent(manifest.storePath), manifest.graphID) == manifest.nativeStoreID else { throw GraphBackupError.invalidBackup }
        } catch {
            if case StoreRuntimeError.shutdownFailed = error { detached = false }
            throw error
        }
        guard try inventory(directory) == manifest.files else { throw GraphBackupError.invalidBackup }
    }
    private nonisolated func inventory(_ directory: URL) throws -> [GraphBackupFile] {
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

/// The stage's presenter lets Foundation refuse cleanup while preparation is active.
private final class BackupStagePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(_ url: URL) {
        presentedItemURL = url
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(GraphBackupError.busy)
    }
}
