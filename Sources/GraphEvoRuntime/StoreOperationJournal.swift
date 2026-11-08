import Foundation

/// Small durable operation evidence survives native destruction beside the SQLite.
/// Updates join its existing Apple coordination grant. It contains no sandbox URL or application payload.
package enum StoreOperationJournal {
    package static func update(_ configuration: StoreConfiguration,
        _ transform: @escaping @Sendable (Data?) throws -> Data
    ) async throws -> Data {
        let resolved = try ResolvedStore(configuration)
        guard configuration.exclusiveGraphID != nil, configuration.workspaceID == nil else {
            throw StoreRuntimeError.resourceReserved
        }
        let anchor = try SQLiteStoreCoordination.directory(resolved)
        let identity = try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration)
        guard let journal = journalURL(resolved) else { throw StoreRuntimeError.resourceReserved }
        return try await CoordinatedFiles.run([.write(anchor)]) {
            guard try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration) == identity else { throw StoreRuntimeError.storeReplaced(anchor) }
            var previous: Data?
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: journal.path)) == nil else { throw StoreRuntimeError.resourceReserved }
            if FileManager.default.fileExists(atPath: journal.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                      let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= 16 * 1024 else {
                    throw StoreRuntimeError.resourceReserved
                }
                previous = try Data(contentsOf: journal)
            }
            let next = try transform(previous)
            guard next.count <= 16 * 1024 else { throw StoreRuntimeError.resourceReserved }
            if !next.isEmpty && next != previous { try next.write(to: journal, options: .atomic) }
            return next
        }
    }
    private static func journalURL(_ resolved: ResolvedStore) -> URL? {
        guard resolved.configuration.exclusiveGraphID != nil, let url = resolved.url else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".graphevo-deletion-v1.json")
    }
    static func readUnderGrant(_ resolved: ResolvedStore) throws -> Data? {
        guard let journal = journalURL(resolved) else { return nil }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: journal.path)) == nil else { throw StoreRuntimeError.resourceReserved }
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        let values = try journal.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false, values.linkCount == 1,
              let size = values.fileSize, size > 0, size <= 16 * 1024 else { throw StoreRuntimeError.resourceReserved }
        let data = try Data(contentsOf: journal)
        return data.isEmpty ? nil : data
    }
    package static func read(_ configuration: StoreConfiguration) async throws -> Data? {
        // Empty return data represents absence; an existing empty file is corrupt.
        let value = try await update(configuration) { $0 ?? Data() }
        return value.isEmpty ? nil : value
    }
}
