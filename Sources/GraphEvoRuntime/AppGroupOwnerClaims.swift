import Foundation

/// Generation registrations belong to the store location. The stable writer
/// fence protects every lookup, publication and removal.
enum AppGroupOwnerClaims {
    private struct Claim: Codable, Equatable {
        let graph: UUID?
        let generation: UUID
        let workspace: UUID?
        var retiring: Bool? = nil
    }

    private static func directory(for resolved: ResolvedStore) throws -> URL {
        try SQLiteStoreCoordination.directory(resolved, create: false)
            .appendingPathComponent(".owners-v1", isDirectory: true)
    }

    private static func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw StoreRuntimeError.resourceReserved
        }
    }

    static func checkCreationArtifacts(_ resolved: ResolvedStore) throws {
        guard let url = resolved.url else { throw StoreRuntimeError.resourceReserved }
        let files = FileManager.default
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            let exists = files.fileExists(atPath: sidecar.path)
            let symlink = (try? files.destinationOfSymbolicLink(atPath: sidecar.path)) != nil
            guard !exists, !symlink else { throw StoreRuntimeError.resourceReserved }
        }
    }

    static func publish(_ generation: UUID, for resolved: ResolvedStore, creating: Bool) throws {
        let directory = try directory(for: resolved)
        let graph = resolved.configuration.exclusiveGraphID
        let files = FileManager.default
        if creating { try checkCreationArtifacts(resolved) }
        if creating || resolved.configuration.appGroup == nil {
            do { try files.createDirectory(at: directory, withIntermediateDirectories: false) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { }
        }
        try verifyDirectory(directory)
        if creating || resolved.configuration.workspaceID != nil,
           !(try files.contentsOfDirectory(atPath: directory.path)).isEmpty {
            throw StoreRuntimeError.resourceReserved
        }
        if resolved.configuration.appGroup == nil {
            for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard try read(entry).retiring != true else { throw StoreRuntimeError.resourceReserved }
            }
        }
        let entry = directory.appendingPathComponent(generation.uuidString)
        try JSONEncoder().encode(Claim(graph: graph, generation: generation, workspace: resolved.configuration.workspaceID)).write(to: entry, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: entry)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func remove(_ generation: UUID, for resolved: ResolvedStore, anchor: URL? = nil) throws {
        let directory = try anchor?.appendingPathComponent(".owners-v1", isDirectory: true) ?? directory(for: resolved)
        try verifyDirectory(directory)
        let entry = directory.appendingPathComponent(generation.uuidString)
        try verify(entry, generation: generation, for: resolved)
        try FileManager.default.removeItem(at: entry)
    }

    static func markRetiring(_ generation: UUID, for resolved: ResolvedStore) throws {
        let directory = try directory(for: resolved)
        let entry = directory.appendingPathComponent(generation.uuidString)
        var claim = try verify(entry, generation: generation, for: resolved)
        claim.retiring = true
        try JSONEncoder().encode(claim).write(to: entry, options: .atomic)
        let handle = try FileHandle(forWritingTo: entry)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func recoverOffline(_ generation: UUID, for resolved: ResolvedStore) throws {
        let directory = try directory(for: resolved)
        try verifyDirectory(directory)
        if resolved.configuration.workspaceID != nil {
            try requireSoleClaim(generation, for: resolved)
        }
        let entry = directory.appendingPathComponent(generation.uuidString)
        let claim = try read(entry)
        guard claim.generation == generation, claim.workspace == resolved.configuration.workspaceID,
              claim.retiring != true,
              claim.graph == resolved.configuration.exclusiveGraphID ||
                (claim.graph == nil && claim.workspace == nil) else {
            throw StoreRuntimeError.resourceReserved
        }
        try FileManager.default.removeItem(at: entry)
    }

    static func requireNoClaims(for resolved: ResolvedStore, allowMissing: Bool = false) throws {
        let directory = try directory(for: resolved)
        if allowMissing, !FileManager.default.fileExists(atPath: directory.path),
           (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil { return }
        try verifyDirectory(directory)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw StoreRuntimeError.resourceReserved
        }
    }

    static func requireSoleClaim(_ generation: UUID, for resolved: ResolvedStore) throws {
        let directory = try directory(for: resolved)
        try verifyDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count == 1, let entry = entries.first else { throw StoreRuntimeError.resourceReserved }
        _ = try verify(entry, generation: generation, for: resolved)
    }

    @discardableResult
    private static func verify(_ entry: URL, generation: UUID, for resolved: ResolvedStore) throws -> Claim {
        let claim = try read(entry)
        guard entry.lastPathComponent == generation.uuidString,
              claim.generation == generation, claim.graph == resolved.configuration.exclusiveGraphID,
              claim.workspace == resolved.configuration.workspaceID else { throw StoreRuntimeError.resourceReserved }
        return claim
    }

    private static func read(_ entry: URL) throws -> Claim {
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false, values.linkCount == 1,
              let size = values.fileSize, size <= 256,
              let claim = try? JSONDecoder().decode(Claim.self, from: Data(contentsOf: entry)) else {
            throw StoreRuntimeError.resourceReserved
        }
        return claim
    }
}
