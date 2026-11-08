import CoreData
import Foundation

/// Recovery evidence is written only under the existing Apple deletion grant.
/// It binds the operation, native store and owner generation, without absolute URLs.
struct StoreDestructionReceipt: Codable, Sendable {
    struct Artifact: Codable, Sendable {
        let device: UInt64
        let inode: UInt64
    }
    let format: Int
    let operationID: UUID
    let graphID: UUID
    let storeID: String
    let generation: UUID
    let anchorName: String
    var nativeDestroyed: Bool
    var artifacts: [String: Artifact]
    static func url(_ storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("." + storeURL.lastPathComponent + ".graphevo-destruction-v1.json")
    }
    static func read(_ storeURL: URL, graphID: UUID) throws -> Self? {
        let url = url(storeURL)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw StoreRuntimeError.resourceReserved }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= 4096 else { throw StoreRuntimeError.resourceReserved }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let component = value.anchorName.hasPrefix("../") ? String(value.anchorName.dropFirst(3)) : value.anchorName
        guard value.format == 1, value.graphID == graphID,
              value.anchorName == "." || (component.hasPrefix(".graphevo-coordination-")
                && component.count == ".graphevo-coordination-".count + 64
                && component.dropFirst(".graphevo-coordination-".count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else { throw StoreRuntimeError.resourceReserved }
        return value
    }
    func persist(_ storeURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(storeURL), options: .atomic)
    }
    func anchor(for storeURL: URL) -> URL {
        let parent = storeURL.deletingLastPathComponent()
        return anchorName == "." ? parent : parent.appendingPathComponent(anchorName, isDirectory: true).standardizedFileURL
    }
    static func relativeAnchor(_ anchor: URL, storeURL: URL) throws -> String {
        let parent = storeURL.deletingLastPathComponent()
        if anchor == parent { return "." }
        if anchor.deletingLastPathComponent() == parent { return anchor.lastPathComponent }
        guard anchor.deletingLastPathComponent() == parent.deletingLastPathComponent() else { throw StoreRuntimeError.resourceReserved }
        return "../" + anchor.lastPathComponent
    }
    static func capture(_ url: URL) throws -> [String: Artifact] {
        try StoreResources.destructionURLs(url).reduce(into: [:]) { values, item in
            if let value = try StoreResources.destructionArtifact(item) {
                values[item.lastPathComponent] = .init(device: value.identity.device, inode: value.identity.inode)
            }
        }
    }
}

extension StoreRegistry {
    package nonisolated static func validateDestructionSource(_ configuration: StoreConfiguration,
        graphID: UUID, storeID: String, operationID: UUID, device: UInt64, inode: UInt64, completed: Bool
    ) async throws {
        let resolved = try ResolvedStore(configuration)
        guard let url = resolved.url, configuration.exclusiveGraphID == graphID else { throw StoreRuntimeError.resourceReserved }
        let anchor = try SQLiteStoreCoordination.directory(resolved)
        let identity = try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration)
        let previousAnchor = try StoreDestructionReceipt.read(url, graphID: graphID)?.anchor(for: url) ?? anchor
        var accesses: [CoordinatedFiles.Access] = [.write(anchor)]
        if previousAnchor != anchor { accesses.append(.write(previousAnchor)) }
        try await CoordinatedFiles.run(accesses) {
            guard try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration) == identity else { throw StoreRuntimeError.storeReplaced(anchor) }
            let receipt = try StoreDestructionReceipt.read(url, graphID: graphID)
            if let receipt {
                guard receipt.anchor(for: url) == previousAnchor,
                      receipt.operationID == operationID, receipt.storeID == storeID else { throw StoreRuntimeError.resourceReserved }
            }
            if let current = try StoreResources.destructionArtifact(url) {
                if let receipt, receipt.nativeDestroyed, let expected = receipt.artifacts[url.lastPathComponent] {
                    guard current.identity.device == expected.device, current.identity.inode == expected.inode else { throw StoreRuntimeError.storeReplaced(url) }
                } else {
                    guard !completed, current.identity.device == device, current.identity.inode == inode else { throw StoreRuntimeError.storeReplaced(url) }
                }
            } else {
                guard receipt != nil || completed else { throw StoreRuntimeError.missingStore(url) }
            }
        }
    }
    /// Returns true only when exact destruction evidence proves native absence.
    /// Existing native stores are released for a fresh terminal owner after the
    /// abandoned registration has been checked under an exclusive Apple grant.
    package nonisolated static func recoverInterruptedDestruction(_ configuration: StoreConfiguration,
        graphID: UUID, storeID: String, operationID: UUID
    ) async throws -> Bool {
        let resolved = try ResolvedStore(configuration)
        guard configuration.exclusiveGraphID == graphID, configuration.workspaceID == nil,
              let url = resolved.url else { throw StoreRuntimeError.resourceReserved }
        let anchor = try SQLiteStoreCoordination.directory(resolved)
        let identity = try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration)
        let previousAnchor = try StoreDestructionReceipt.read(url, graphID: graphID)?.anchor(for: url) ?? anchor
        var accesses: [CoordinatedFiles.Access] = [.delete(anchor)]
        if previousAnchor != anchor { accesses.append(.delete(previousAnchor)) }
        do {
            return try await CoordinatedFiles.run(accesses) {
                guard try SQLiteStoreCoordination.controlIdentity(anchor, configuration: configuration) == identity else { throw StoreRuntimeError.storeReplaced(anchor) }
                guard let receipt = try StoreDestructionReceipt.read(url, graphID: graphID) else {
                    guard FileManager.default.fileExists(atPath: url.path) else { throw StoreRuntimeError.missingStore(url) }
                    return false
                }
                guard receipt.anchor(for: url) == previousAnchor,
                      receipt.operationID == operationID, receipt.storeID == storeID else { throw StoreRuntimeError.resourceReserved }
                if FileManager.default.fileExists(atPath: url.path), !receipt.nativeDestroyed {
                    try StoreResources.validateDestructionIdentity(url, graphID: graphID, storeID: storeID)
                    try AppGroupOwnerClaims.recoverDestruction(receipt.generation, for: resolved, anchor: previousAnchor)
                    return false
                }
                // The native call may have completed before its response was recorded.
                // Only surviving artifacts from this exact owner's captured inodes qualify.
                let artifacts = StoreResources.destructionURLs(url)
                for item in artifacts {
                    guard let current = try StoreResources.destructionArtifact(item) else { continue }
                    guard let expected = receipt.artifacts[item.lastPathComponent], current.identity.device == expected.device,
                          current.identity.inode == expected.inode else { throw StoreRuntimeError.storeReplaced(item) }
                }
                try AppGroupOwnerClaims.requireDestructionClaim(receipt.generation, for: resolved, anchor: previousAnchor)
                for item in artifacts where FileManager.default.fileExists(atPath: item.path) { try FileManager.default.removeItem(at: item) }
                try AppGroupOwnerClaims.recoverDestruction(receipt.generation, for: resolved, anchor: previousAnchor)
                return true
            }
        } catch is CoordinatedFiles.Denied { throw StoreRuntimeError.resourceReserved }
    }
}
