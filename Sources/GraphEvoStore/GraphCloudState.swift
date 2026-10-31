import Foundation
import Darwin
import GraphEvoModel

package enum GraphCloudScope: String, Codable, Sendable { case `private`, shared }
package enum GraphCloudEnvironment: String, Codable, Sendable { case development, production }
package enum GraphCloudError: Error, Equatable {
    case attachmentTimeout, graphPaused
    case ownershipConflict, invalidConfiguration, invalidState, accountUnavailable, accountChanged
    case persistence, inboxLimit, unsupportedAsset, unexpectedUpload, stopped, stopping, busy, zoneUnavailable, transportUnavailable
}

package struct GraphCloudConfiguration: Equatable, Sendable {
    package let containerIdentifier: String
    package let environment: GraphCloudEnvironment
    package let directory: URL
    package let maximumEvents: Int
    package let maximumBytes: Int
    package init(containerIdentifier: String, environment: GraphCloudEnvironment, directory: URL,
                 maximumEvents: Int = 4096, maximumBytes: Int = 32 * 1024 * 1024) {
        self.containerIdentifier = containerIdentifier; self.environment = environment
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
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
    package let kind: Kind
    package let zone: GraphCloudZone
    package let recordName: String?
    package let recordType: String?
    package let recordArchive: Data?
    package let deletionReason: String?
    package init(kind: Kind, zone: GraphCloudZone, recordName: String? = nil, recordType: String? = nil,
                 recordArchive: Data? = nil, deletionReason: String? = nil) {
        self.kind = kind; self.zone = zone; self.recordName = recordName; self.recordType = recordType
        self.recordArchive = recordArchive; self.deletionReason = deletionReason
    }
    var valid: Bool {
        guard !zone.owner.isEmpty, !zone.name.isEmpty else { return false }
        switch kind {
        case .zoneChanged, .zoneDeleted: return recordName == nil && recordType == nil && recordArchive == nil
        case .recordChanged: return recordName?.isEmpty == false && recordType?.isEmpty == false && recordArchive != nil
        case .recordDeleted: return recordName?.isEmpty == false && recordType?.isEmpty == false && recordArchive == nil
        }
    }
}

package struct GraphCloudInboxEntry: Codable, Equatable, Sendable {
    package let id: UUID
    package let change: GraphCloudIncoming
}

package struct GraphCloudStatus: Sendable {
    package let scopes: Set<GraphCloudScope>
    package let inboxCount: Int
    package let failure: GraphCloudError?
    package let stopped: Bool
    package let outgoingReceiptCount: Int
}

struct GraphCloudDocument: Codable, Sendable {
    var format = 4
    let container: String
    let environment: GraphCloudEnvironment
    let account: String
    var states: [String: Data] = [:]
    var bindings: [GraphCloudBinding] = []
    var shareAttempts: [GraphCloudZone] = []
    var inbox: [GraphCloudInboxEntry] = []
    var sent: [GraphCloudSentReceipt] = []
    var eventCount: Int { shareAttempts.count + inbox.count + sent.reduce(0) { $0 + $1.saved.count + $1.deletedNames.count + $1.failures.count } }
}

/// A process-wide claim spans startup/account verification and failed cleanup.
actor GraphCloudOwnership {
    static let shared = GraphCloudOwnership()
    private var claims: [String: UUID] = [:]
    func acquire(_ key: String, owner: UUID) throws {
        guard claims[key] == nil else { throw GraphCloudError.ownershipConflict }
        claims[key] = owner
    }
    func release(_ key: String, owner: UUID) {
        if claims[key] == owner { claims.removeValue(forKey: key) }
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
            Darwin.close(descriptor); throw GraphCloudError.ownershipConflict
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
