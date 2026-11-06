import CryptoKit
import Foundation
import GraphEvoModel
import GraphEvoRuntime

public enum GraphFileError: Error {
    case unavailable
    case localOnly
    case invalidMetadata
    case fixedMetadata
    case missingContent
    case corruptContent
    case conflict
}

/// Fixed metadata for a first-class local file node.
public struct GraphFile: Sendable, Equatable, Identifiable {
    package static let nodeType = "GraphEvo.File.v1"
    public let id: GraphNodeID
    public let name: String
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String
    public let revision: UUID

    package init(id: GraphNodeID, name: String, contentType: String, byteCount: Int64, sha256: String, revision: UUID) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              !contentType.isEmpty, !contentType.contains("\0"), byteCount >= 0,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw GraphFileError.invalidMetadata }
        self.id = id
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }
}

package enum GraphFileDisk {
    package static let schemaIdentifier = "GraphEvo.v2.schema.5.local-files"

    package static func root(for store: URL, storeID: UUID) -> URL {
        store.deletingLastPathComponent().appendingPathComponent(
            "." + store.lastPathComponent + ".files-" + storeID.uuidString, isDirectory: true)
    }

    package static func url(for file: GraphFile, in root: URL) -> URL {
        root.appendingPathComponent(file.revision.uuidString)
    }

    package static func requireRegular(_ url: URL, count: Int64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GraphFileError.missingContent }
        guard values.fileSize.map(Int64.init) == count else { throw GraphFileError.corruptContent }
    }

    package static func ensureRoot(_ root: URL) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: root.path) {
            do { try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { }
        }
        try validateRoot(root)
    }

    package static func validateRoot(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw GraphFileError.corruptContent }
    }

    package static func prepare(from source: URL, in root: URL, id: GraphNodeID, name: String, contentType: String,
                                check: () throws -> Void) throws -> (GraphFile, URL) {
        guard source.isFileURL, source.query == nil, source.fragment == nil else { throw GraphFileError.invalidMetadata }
        try ensureRoot(root)
        let revision = UUID()
        let stage = root.appendingPathComponent(revision.uuidString + ".partial")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let metadata = try coordinate(source, writing: false) { input in
                let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GraphFileError.invalidMetadata }
                try Data().write(to: stage, options: .withoutOverwriting)
                let reader = try FileHandle(forReadingFrom: input)
                defer { try? reader.close() }
                let writer = try FileHandle(forWritingTo: stage)
                defer { try? writer.close() }
                var size: Int64 = 0
                var digest = SHA256()
                while true {
                    try check()
                    let count = try autoreleasepool {
                        guard let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty else { return 0 }
                        digest.update(data: chunk)
                        try writer.write(contentsOf: chunk)
                        return chunk.count
                    }
                    guard count != 0 else { break }
                    size += Int64(count)
                }
                try writer.synchronize()
                try writer.close()
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stage.path)
                return try GraphFile(id: id, name: name, contentType: contentType, byteCount: size,
                    sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), revision: revision)
            }
            return (metadata, stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    package static func verify(_ url: URL, file: GraphFile, check: () throws -> Void) throws {
        try requireRegular(url, count: file.byteCount)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while true {
            try check()
            let consumed = try autoreleasepool {
                guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                digest.update(data: chunk)
                return true
            }
            guard consumed else { break }
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw GraphFileError.corruptContent
        }
    }

    package static func coordinate<Value>(_ url: URL, writing: Bool, _ body: (URL) throws -> Value) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        let coordinator = NSFileCoordinator()
        let accessor: (URL) -> Void = { coordinated in
            result = Result {
                guard coordinated.standardizedFileURL.path == url.standardizedFileURL.path else { throw GraphFileError.conflict }
                return try body(coordinated)
            }
        }
        if writing { coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: accessor) }
        if let coordinationError { throw coordinationError }
        guard let result else { throw GraphFileError.conflict }
        return try result.get()
    }
}
