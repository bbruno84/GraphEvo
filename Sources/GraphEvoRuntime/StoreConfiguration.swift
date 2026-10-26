import CoreData
import Foundation

/// The physical resource selected by a runtime request, independent of graph identity.
package enum StoreLocation: Sendable, Equatable {
    case sqlite(URL)
    case inMemory(UUID)
}

/// The access mode of every lease sharing a native store owner.
package enum StoreAccess: Sendable, Equatable {
    case readWrite
    case readOnly
}

/// Explicit resolved resources; directory, legacy and App Group discovery belong above this layer.
package struct StoreConfiguration: Sendable, Equatable {
    package let location: StoreLocation
    package let access: StoreAccess

    package init(location: StoreLocation, access: StoreAccess = .readWrite) {
        self.location = location
        self.access = access
    }
}

/// Immutable model identity and a factory that creates the queue-owned native model.
/// The factory must construct a fresh native model; cached model hash computation
/// is not a cross-task value boundary. Entity hashes are checked before loading.
package struct StoreSchema: Sendable {
    package let identifier: String
    package let entityVersionHashes: [String: Data]
    let makeModel: @Sendable () -> NSManagedObjectModel

    package init(
        identifier: String,
        entityVersionHashes: [String: Data],
        makeModel: @escaping @Sendable () -> NSManagedObjectModel
    ) {
        self.identifier = identifier
        self.entityVersionHashes = entityVersionHashes
        self.makeModel = makeModel
    }

    func isCompatible(with other: StoreSchema) -> Bool {
        identifier == other.identifier && entityVersionHashes == other.entityVersionHashes
    }
}

enum StoreKey: Hashable, Sendable {
    case sqlite(String)
    case inMemory(UUID)
}

struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ResolvedStore: Sendable {
    let key: StoreKey
    let configuration: StoreConfiguration

    var url: URL? {
        guard case .sqlite(let url) = configuration.location else { return nil }
        return url
    }

    init(_ configuration: StoreConfiguration) throws {
        switch configuration.location {
        case .inMemory(let id):
            guard configuration.access == .readWrite else {
                throw StoreRuntimeError.invalidConfiguration("A new in-memory store must be writable.")
            }
            key = .inMemory(id)
            self.configuration = configuration
        case .sqlite(let url):
            guard url.isFileURL, url.host == nil || url.host == "localhost",
                  url.query == nil, url.fragment == nil,
                  url.pathExtension.caseInsensitiveCompare("sqlite") == .orderedSame else {
                throw StoreRuntimeError.invalidConfiguration("An explicit local SQLite file URL is required.")
            }
            var ancestor = url.standardizedFileURL
            var missing: [String] = []
            let files = FileManager.default
            while !files.fileExists(atPath: ancestor.path) {
                if (try? files.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                    throw StoreRuntimeError.unsupportedFileAlias(url)
                }
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else { break }
                missing.append(ancestor.lastPathComponent)
                ancestor = parent
            }
            var canonical = ancestor.resolvingSymlinksInPath().standardizedFileURL
            for component in missing.reversed() { canonical.appendPathComponent(component) }
            let volume: URLResourceValues
            do { volume = try ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]) }
            catch { throw StoreRuntimeError.loadFailed(canonical, underlying: error) }
            guard let caseSensitive = volume.volumeSupportsCaseSensitiveNames else {
                throw StoreRuntimeError.invalidConfiguration("The volume's filename case policy is unavailable.")
            }
            let path = canonical.path.precomposedStringWithCanonicalMapping
            key = .sqlite(caseSensitive ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")))
            self.configuration = StoreConfiguration(location: .sqlite(canonical), access: configuration.access)
            _ = try fileIdentity()
        }
    }

    /// Reject hard links; SQLite sidecars are path-based and cannot share an alias policy safely.
    func fileIdentity() throws -> FileIdentity? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw StoreRuntimeError.loadFailed(url, underlying: error) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StoreRuntimeError.invalidConfiguration("The SQLite URL must identify a regular file.")
        }
        if ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) > 1 {
            throw StoreRuntimeError.unsupportedFileAlias(url)
        }
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw StoreRuntimeError.invalidConfiguration("The SQLite file identity is unavailable.")
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }
}
