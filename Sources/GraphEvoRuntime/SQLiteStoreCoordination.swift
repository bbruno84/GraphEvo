import CoreData
import CryptoKit
import Darwin
import Foundation

/// A stable Apple coordination target per canonical SQLite location.
package enum SQLiteStoreCoordination {
    @TaskLocal static var held: Set<StoreKey> = []

    static func participates(_ resolved: ResolvedStore) throws -> Bool {
        let configuration = resolved.configuration
        guard let url = resolved.url, !configuration.legacyReadOnly,
              configuration.cloudKitContainerIdentifier == nil, configuration.sharedStoreURL == nil else { return false }
        if configuration.access == .readWrite || configuration.appGroup != nil { return true }
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreRuntimeError.missingStore(url) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: url, options: [NSReadOnlyPersistentStoreOption: true])
        return metadata[StoreNativeContext.historySyncGraphKey] != nil
    }

    static func directory(_ resolved: ResolvedStore, create: Bool = true) throws -> URL {
        guard case .sqlite(let key) = resolved.key, let url = resolved.url else {
            throw StoreRuntimeError.invalidConfiguration("Coordination requires a local SQLite store.")
        }
        if resolved.configuration.appGroup != nil { return url.deletingLastPathComponent() }
        let parent = url.deletingLastPathComponent()
        // A workspace may retire its entire directory. Its anchor lives beside it.
        let owner = parent.appendingPathComponent("owner")
        let attributes = try? FileManager.default.attributesOfItem(atPath: owner.path)
        let isWorkspace = url.lastPathComponent.caseInsensitiveCompare("Graph.sqlite") == .orderedSame
            && attributes?[.type] as? FileAttributeType == .typeRegular
            && (attributes?[.size] as? NSNumber)?.intValue == 36
        let root = isWorkspace ? parent.deletingLastPathComponent() : parent
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(".graphevo-coordination-" + digest, isDirectory: true)
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
        }
        _ = try identity(directory)
        return directory
    }

    /// A schema copy requires a stopped ordinary SQLite source for the entire native migration.
    package static func withStoppedSource<Value: Sendable>(_ url: URL,
        _ body: @escaping @Sendable (URL, CoordinatedFiles.CancellationCheck) throws -> Value
    ) async throws -> Value {
        let configuration = StoreConfiguration(location: .sqlite(url))
        let resolved = try ResolvedStore(configuration)
        guard let source = resolved.url, let file = try resolved.fileIdentity() else {
            throw StoreRuntimeError.missingStore(url)
        }
        let gateway = try StoreGatewayLease.acquire(configuration, owner: UUID())
        defer { gateway.release() }
        let anchor = try directory(resolved)
        let expected = try identity(anchor)
        do {
            return try await CoordinatedFiles.run([.delete(anchor)]) { check in
                guard try identity(anchor) == expected, try resolved.fileIdentity() == file else {
                    throw StoreRuntimeError.storeReplaced(source)
                }
                try AppGroupOwnerClaims.requireNoClaims(for: resolved, allowMissing: true)
                return try body(source, check)
            }
        } catch is CoordinatedFiles.Denied { throw StoreRuntimeError.resourceReserved }
    }

    /// A detached private stage can move or disappear only after its exact
    /// anchor has granted deletion and every native owner has detached.
    package static func withDetachedWorkspace(_ configuration: StoreConfiguration, destination: URL? = nil,
        _ body: @escaping @Sendable () throws -> Void
    ) async throws {
        let resolved = try ResolvedStore(configuration)
        guard configuration.workspaceID != nil, configuration.appGroup == nil else {
            throw StoreRuntimeError.resourceReserved
        }
        let anchor = try directory(resolved)
        let expected = try identity(anchor)
        var access: [CoordinatedFiles.Access] = [.delete(anchor)]
        if let destination { access.append(.write(destination)) }
        do {
            try await CoordinatedFiles.run(access) {
                guard try identity(anchor) == expected else { throw StoreRuntimeError.storeReplaced(anchor) }
                try AppGroupOwnerClaims.requireNoClaims(for: resolved, allowMissing: true)
                try body()
            }
        } catch is CoordinatedFiles.Denied { throw StoreRuntimeError.resourceReserved }
    }

    static func controlIdentity(_ directory: URL, configuration: StoreConfiguration) throws -> FileIdentity {
        if configuration.appGroup == nil { return try identity(directory) }
        // App Group containers use system-managed group permissions. Their existing
        // coordination contract requires a stable owned directory, not mode 0700.
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else { throw StoreRuntimeError.resourceReserved }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func identity(_ directory: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw StoreRuntimeError.invalidConfiguration("The store coordination directory has unsafe ownership or permissions.")
        }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
