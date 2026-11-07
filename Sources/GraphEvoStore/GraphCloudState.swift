import Foundation
import Darwin
import GraphEvoModel

public enum GraphCloudScope: String, Codable, Sendable { case `private`, shared }
public enum GraphCloudEnvironment: String, Codable, Sendable { case development, production }
package enum GraphCloudError: Error, Equatable {
    case attachmentTimeout, graphPaused
    case ownershipConflict, directoryBusy, invalidConfiguration, invalidState, accountUnavailable, accountChanged
    case persistence, inboxLimit, unsupportedAsset, unexpectedUpload, stopped, stopping, busy, zoneUnavailable, transportUnavailable
    case assetSizeLimitExceeded
}

package struct GraphCloudConfiguration: Equatable, Sendable {
    package let containerIdentifier: String
    package let environment: GraphCloudEnvironment
    package let directory: URL
    package let maximumEvents: Int
    package let maximumBytes: Int
    package var supportsFiles = false
    package let allowsSessionUpgradeFromV8: Bool
    package init(containerIdentifier: String, environment: GraphCloudEnvironment, directory: URL,
                 maximumEvents: Int = 4096, maximumBytes: Int = 32 * 1024 * 1024, allowsSessionUpgradeFromV8: Bool = false) {
        self.containerIdentifier = containerIdentifier; self.environment = environment
        self.directory = Self.canonicalDirectory(directory)
        self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
        self.allowsSessionUpgradeFromV8 = allowsSessionUpgradeFromV8
    }
    /// Resolve existing parents even when the session directory has not been created.
    private static func canonicalDirectory(_ directory: URL) -> URL {
        var ancestor = directory.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    var namespace: String { environment.rawValue + ":" + containerIdentifier }
}

package struct GraphCloudZone: Codable, Hashable, Sendable {
    package let scope: GraphCloudScope
    package let owner: String
    package let name: String
    package init(scope: GraphCloudScope, owner: String, name: String) {
        self.scope = scope; self.owner = owner; self.name = name
    }
}

package struct GraphCloudBinding: Codable, Equatable, Sendable {
    package let zone: GraphCloudZone
    package let graphID: GraphID
    package init(zone: GraphCloudZone, graphID: GraphID) { self.zone = zone; self.graphID = graphID }
}

/// Secure CKRecord archives are retained before explicit CF01 conversion and graph application.
package struct GraphCloudIncoming: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case zoneChanged, zoneDeleted, recordChanged, recordDeleted }
    /// SDK staging is consumed by freeze before any durable document is encoded.
    package var transientAssetURL: URL? = nil
    private enum CodingKeys: String, CodingKey {
        case kind, zone, recordName, recordType, recordArchive, assetReference, deletionReason
    }
    package let kind: Kind
    package let zone: GraphCloudZone
    package let recordName: String?
    package let recordType: String?
    package let recordArchive: Data?
    package let assetReference: GraphCloudAssetReference?
    package let deletionReason: String?
    package init(kind: Kind, zone: GraphCloudZone, recordName: String? = nil, recordType: String? = nil,
                 recordArchive: Data? = nil, assetReference: GraphCloudAssetReference? = nil,
                 deletionReason: String? = nil, transientAssetURL: URL? = nil) {
        self.transientAssetURL = transientAssetURL
        self.kind = kind; self.zone = zone; self.recordName = recordName; self.recordType = recordType
        self.recordArchive = recordArchive; self.assetReference = assetReference; self.deletionReason = deletionReason
    }
    package func encode(to encoder: Encoder) throws {
        guard transientAssetURL == nil else { throw GraphCloudError.invalidState }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(zone, forKey: .zone)
        try values.encodeIfPresent(recordName, forKey: .recordName)
        try values.encodeIfPresent(recordType, forKey: .recordType)
        try values.encodeIfPresent(recordArchive, forKey: .recordArchive)
        try values.encodeIfPresent(assetReference, forKey: .assetReference)
        try values.encodeIfPresent(deletionReason, forKey: .deletionReason)
    }

    var valid: Bool {
        guard !zone.owner.isEmpty, !zone.name.isEmpty else { return false }
        switch kind {
        case .zoneChanged, .zoneDeleted: return recordName == nil && recordType == nil && recordArchive == nil && assetReference == nil
        case .recordChanged: return recordName?.isEmpty == false && recordType?.isEmpty == false && recordArchive != nil
        case .recordDeleted: return recordName?.isEmpty == false && recordType?.isEmpty == false && recordArchive == nil && assetReference == nil
        }
    }
}

package struct GraphCloudInboxEntry: Codable, Equatable, Sendable {
    package let id: UUID
    package let change: GraphCloudIncoming
    var membershipGeneration: UUID? = nil
}

package struct GraphCloudStatus: Sendable {
    package let scopes: Set<GraphCloudScope>
    package let inboxCount: Int
    package let failure: GraphCloudError?
    package let stopped: Bool
    package let outgoingReceiptCount: Int
}

struct GraphCloudDocument: Codable, Sendable {
    var format = 10
    var accountResetRequired: Bool? = nil
    var clientID = UUID()
    let container: String
    let environment: GraphCloudEnvironment
    let account: String
    var states: [String: Data] = [:]
    var bindings: [GraphCloudBinding] = []
    var memberships: [GraphCloudMembership] = []
    var joins: [GraphCloudJoinIntent]? = nil
    var shareAttempts: [GraphCloudZone] = []
    var inbox: [GraphCloudInboxEntry] = []
    var sent: [GraphCloudSentReceipt] = []
    var ledgers: [GraphLedgerReplica] = []
    var activations: [GraphCloudActivationRoute] = []
    var eventCount: Int { (joins?.count ?? 0) + activations.count + ledgers.count + memberships.count + shareAttempts.count + inbox.count + sent.reduce(0) { $0 + $1.saved.count + $1.deletedNames.count + $1.failures.count } }
    var assetReferences: [GraphCloudAssetReference] {
        inbox.compactMap { $0.change.assetReference }
        + sent.flatMap { $0.saved.compactMap(\.assetReference)
            + $0.failures.compactMap { $0.serverRecord?.assetReference } }
    }
}

/// A process-wide claim spans startup/account verification and failed cleanup.
actor GraphCloudOwnership {
    static let shared = GraphCloudOwnership()
    private struct Claim { let owner: UUID; var sessions: Int; var pinned: Bool }
    private var claims: [String: Claim] = [:]
    private var directories: [String: (key: String, owner: UUID)] = [:]
    func reserve(_ key: String, owner: UUID, directory: URL) throws {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard claims[key] == nil,
              directories[path] == nil else { throw GraphCloudError.ownershipConflict }
        claims[key] = Claim(owner: owner, sessions: 0, pinned: true)
        directories[path] = (key, owner)
    }
    func unreserve(_ key: String, owner: UUID) {
        guard var claim = claims[key], claim.owner == owner else { return }
        claim.pinned = false
        claims[key] = claim
        releaseIfIdle(key)
    }
    func acquire(_ key: String, owner: UUID) throws {
        if var claim = claims[key] {
            guard claim.owner == owner, claim.sessions == 0 else { throw GraphCloudError.ownershipConflict }
            claim.sessions += 1; claims[key] = claim
        } else { claims[key] = Claim(owner: owner, sessions: 1, pinned: false) }
    }
    func release(_ key: String, owner: UUID) {
        guard var claim = claims[key], claim.owner == owner else { return }
        claim.sessions = max(0, claim.sessions - 1); claims[key] = claim
        releaseIfIdle(key)
    }
    private func releaseIfIdle(_ key: String) {
        guard let claim = claims[key], !claim.pinned, claim.sessions == 0 else { return }
        claims.removeValue(forKey: key)
        directories = directories.filter { $0.value.key != key || $0.value.owner != claim.owner }
    }
}

/// OS lock lifetime is the session lifetime; the lock file is never unlinked.
final class GraphCloudDirectoryLease: @unchecked Sendable {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw GraphCloudError.persistence }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let contended = errno == EWOULDBLOCK
            Darwin.close(descriptor)
            throw contended ? GraphCloudError.directoryBusy : GraphCloudError.persistence
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

/// Entire document replacement keeps both database checkpoints and the inbox in one publication.
struct GraphCloudDisk: Sendable {
    let read: @Sendable (URL) throws -> Data?
    let write: @Sendable (URL, Data) throws -> Void
    static let live = GraphCloudDisk(read: { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }, write: { url, data in try data.write(to: url, options: .atomic) })
}
