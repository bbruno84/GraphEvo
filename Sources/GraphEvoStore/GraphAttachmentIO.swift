import Darwin
import Foundation
import GraphEvoModel

/// Blocking document-provider and file-system work stays outside context/write scopes.
package enum GraphAttachmentIO {
    package static func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let work = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    package static func read(_ source: URL) async throws -> Data {
        try await perform {
            guard source.isFileURL, source.query == nil, source.fragment == nil else { throw GraphAttachmentError.invalidFileURL }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var outcome: Result<Data, any Error>?
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                outcome = Result {
                    guard try coordinated.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw GraphAttachmentError.invalidFileURL
                    }
                    let handle = try FileHandle(forReadingFrom: coordinated)
                    defer { try? handle.close() }
                    var bytes = Data()
                    while true {
                        try Task.checkCancellation()
                        let remaining = GraphAttachmentPayload.maximumByteCount - bytes.count
                        guard let chunk = try handle.read(upToCount: min(256 * 1024, remaining + 1)), !chunk.isEmpty else { break }
                        guard chunk.count <= remaining else {
                            throw GraphAttachmentError.limitExceeded(maxBytes: GraphAttachmentPayload.maximumByteCount)
                        }
                        bytes.append(chunk)
                    }
                    try Task.checkCancellation()
                    return bytes
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw GraphAttachmentError.invalidFileURL }
            return try outcome.get()
        }
    }

    /// Atomic exclusive publication also rejects dangling links and destinations created after preflight.
    package static func publishExclusive(_ temporary: URL, at destination: URL) throws {
        let result = try temporary.withUnsafeFileSystemRepresentation { source in
            guard let source else { throw GraphAttachmentError.invalidFileURL }
            return try destination.withUnsafeFileSystemRepresentation { target in
                guard let target else { throw GraphAttachmentError.invalidFileURL }
                return renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw GraphAttachmentError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    package static func export(_ data: Data, to destination: URL) async throws {
        try await perform {
            guard destination.isFileURL, destination.query == nil, destination.fragment == nil else { throw GraphAttachmentError.invalidFileURL }
            let access = destination.startAccessingSecurityScopedResource()
            let parentAccess = destination.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer {
                if access { destination.stopAccessingSecurityScopedResource() }
                if parentAccess { destination.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
            }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?, outcome: Result<Void, any Error>?
            coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) { target in
                outcome = Result {
                    let files = FileManager.default
                    guard !files.fileExists(atPath: target.path) else { throw GraphAttachmentError.destinationExists }
                    let temporary = target.deletingLastPathComponent().appendingPathComponent(".GraphEvoExport-\(UUID())")
                    defer { try? files.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    try data.write(to: temporary, options: .atomic)
                    try Task.checkCancellation()
                    // Publication refuses an existing destination. The caller owns the resulting file.
                    try publishExclusive(temporary, at: target)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw GraphAttachmentError.invalidFileURL }
            try outcome.get()
        }
    }
}

/// Copies every native artifact without depending on Core Data's external-content filenames.
/// The caller must close all owners and stop external writers before invoking this operation.
public enum GraphStoreBackup {
    public static func copyClosedDirectory(from source: URL, to destination: URL) async throws {
        try await GraphAttachmentIO.perform {
            let accesses = [source, destination, destination.deletingLastPathComponent()].map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, accessed) in accesses where accessed { url.stopAccessingSecurityScopedResource() } }
            guard source.isFileURL, destination.isFileURL, source.query == nil, destination.query == nil,
                  source.fragment == nil, destination.fragment == nil else { throw GraphAttachmentError.invalidFileURL }
            let files = FileManager.default
            guard !files.fileExists(atPath: destination.path),
                  (try? files.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
                throw GraphAttachmentError.destinationExists
            }
            let source = source.standardizedFileURL.resolvingSymlinksInPath()
            let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
            let sourceParts = source.pathComponents.map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
            let destinationParts = destination.pathComponents.map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
            guard !destinationParts.starts(with: sourceParts), !sourceParts.starts(with: destinationParts),
                  try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw GraphAttachmentError.invalidFileURL
            }
            guard !files.fileExists(atPath: destination.path) else { throw GraphAttachmentError.destinationExists }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".GraphEvoBackup-\(UUID())")
            defer { try? files.removeItem(at: temporary) }
            try Task.checkCancellation()
            try files.copyItem(at: source, to: temporary)
            try Task.checkCancellation()
            try GraphAttachmentIO.publishExclusive(temporary, at: destination)
        }
    }
}

extension GraphReadScope {
    public func attachment(_ id: GraphNodeID) throws -> GraphAttachmentContent? {
        guard let record = try record(for: id) else { return nil }
        let payload = try GraphAttachmentPayload(graphRecord: record)
        guard let owner = try self.record(for: payload.ownerID), owner.type != GraphAttachmentPayload.graphType else {
            throw GraphAttachmentError.missingOwner
        }
        return payload.content
    }

    public func attachments(ownedBy ownerID: GraphNodeID) throws -> [GraphAttachmentMetadata] {
        guard let owner = try record(for: ownerID), owner.type != GraphAttachmentPayload.graphType else {
            throw GraphAttachmentError.missingOwner
        }
        return try fetchAll(GraphAttachmentPayload.self).filter { $0.ownerID == ownerID }.map { $0.content.metadata }
    }
}
