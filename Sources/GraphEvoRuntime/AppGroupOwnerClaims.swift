import Foundation

/// Generation registrations belong to the store location. The stable writer
/// fence protects every lookup, publication and removal.
enum AppGroupOwnerClaims {
    private struct Claim: Codable, Equatable {
        let graph: UUID
        let generation: UUID
    }

    private static func directory(for resolved: ResolvedStore) throws -> URL {
        guard resolved.configuration.appGroup != nil, let store = resolved.url else {
            throw StoreRuntimeError.resourceReserved
        }
        return store.deletingLastPathComponent().appendingPathComponent(".owners-v1", isDirectory: true)
    }

    private static func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw StoreRuntimeError.resourceReserved
        }
    }

    static func publish(_ generation: UUID, for resolved: ResolvedStore, creating: Bool) throws {
        let directory = try directory(for: resolved)
        guard let graph = resolved.configuration.exclusiveGraphID else { throw StoreRuntimeError.resourceReserved }
        let files = FileManager.default
        if creating {
            guard let url = resolved.url else { throw StoreRuntimeError.resourceReserved }
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                let exists = files.fileExists(atPath: sidecar.path)
                let symlink = (try? files.destinationOfSymbolicLink(atPath: sidecar.path)) != nil
                guard !exists, !symlink else { throw StoreRuntimeError.resourceReserved }
            }
            do { try files.createDirectory(at: directory, withIntermediateDirectories: false) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { }
        }
        try verifyDirectory(directory)
        if creating, !(try files.contentsOfDirectory(atPath: directory.path)).isEmpty {
            throw StoreRuntimeError.resourceReserved
        }
        let entry = directory.appendingPathComponent(generation.uuidString)
        try JSONEncoder().encode(Claim(graph: graph, generation: generation)).write(to: entry, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: entry)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func remove(_ generation: UUID, for resolved: ResolvedStore) throws {
        let directory = try directory(for: resolved)
        try verifyDirectory(directory)
        let entry = directory.appendingPathComponent(generation.uuidString)
        try verify(entry, generation: generation, for: resolved)
        try FileManager.default.removeItem(at: entry)
    }

    static func requireSoleClaim(_ generation: UUID, for resolved: ResolvedStore) throws {
        let directory = try directory(for: resolved)
        try verifyDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count == 1, let entry = entries.first else { throw StoreRuntimeError.resourceReserved }
        try verify(entry, generation: generation, for: resolved)
    }

    private static func verify(_ entry: URL, generation: UUID, for resolved: ResolvedStore) throws {
        guard let graph = resolved.configuration.exclusiveGraphID,
              entry.lastPathComponent == generation.uuidString else { throw StoreRuntimeError.resourceReserved }
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false, values.linkCount == 1,
              let size = values.fileSize, size <= 256,
              let claim = try? JSONDecoder().decode(Claim.self, from: Data(contentsOf: entry)),
              claim == Claim(graph: graph, generation: generation) else { throw StoreRuntimeError.resourceReserved }
    }
}
