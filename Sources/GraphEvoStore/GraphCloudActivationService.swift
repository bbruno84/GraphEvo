import CloudKit
import Darwin
import Foundation
import GraphEvoModel

/// A complete zone cut keeps record envelopes on disk and only indexes names in memory.
struct GraphCloudActivationInventory: Sendable {
    private final class Directory: Sendable {
        let url: URL

        // The session directory lease and private scope gate exclude another inventory worker.
        init(sessionDirectory: URL) throws {
            let root = sessionDirectory.appendingPathComponent("GraphEvoActivationInventory", isDirectory: true)
            let created = Darwin.mkdir(root.path, 0o700)
            guard created == 0 || errno == EEXIST else { throw GraphCloudError.persistence }
            try Self.checkPrivateDirectory(root)
            for orphan in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: orphan.lastPathComponent)?.uuidString == orphan.lastPathComponent else {
                    throw GraphCloudError.invalidState
                }
                try Self.checkPrivateDirectory(orphan)
                try FileManager.default.removeItem(at: orphan)
            }
            url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }

        private static func checkPrivateDirectory(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR,
                  value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw GraphCloudError.invalidState }
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }
    private let directory: Directory
    private var files: [String: URL] = [:]
    var names: [String] { files.keys.sorted() }
    var isEmpty: Bool { files.isEmpty }
    var count: Int { files.count }

    init(sessionDirectory: URL) throws { directory = try Directory(sessionDirectory: sessionDirectory) }

    mutating func store(_ value: GraphCloudIncoming) throws {
        guard let name = value.recordName else { throw GraphCloudActivationError.invalidState }
        let file = files[name] ?? directory.url.appendingPathComponent(UUID().uuidString)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        files[name] = file
    }

    mutating func remove(_ name: String) throws {
        guard let file = files.removeValue(forKey: name) else { return }
        try FileManager.default.removeItem(at: file)
    }

    func record(_ name: String) throws -> GraphCloudIncoming {
        guard let file = files[name] else { throw GraphCloudActivationError.invalidState }
        return try JSONDecoder().decode(GraphCloudIncoming.self, from: Data(contentsOf: file))
    }
}

/// Direct control and verification requests use the existing session scope gate, never another engine.
struct GraphCloudActivationService: Sendable {
    let ensureZone: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> Void
    let fetch: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> GraphCloudAuthorityRemote?
    let save: @Sendable (GraphCloudConfiguration, GraphCloudBinding, GraphCloudAuthority, GraphCloudAuthorityRemote?) async throws -> GraphCloudAuthorityRemote
    let inventory: @Sendable (GraphCloudConfiguration, GraphCloudSessionIdentity, GraphCloudBinding, GraphCloudActivationLimits) async throws -> GraphCloudActivationInventory

    static let live = Self(ensureZone: { config, binding in
        guard binding.zone.scope == .private else { throw GraphCloudActivationError.invalidRequest }
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        _ = try await database.save(CKRecordZone(zoneID: GraphCloudAuthorityCodec.id(binding).zoneID))
    }, fetch: { config, binding in
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        do { return try GraphCloudAuthorityCodec.decode(await database.record(for: GraphCloudAuthorityCodec.id(binding)), binding: binding) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }, save: { config, binding, value, base in
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let record = try GraphCloudAuthorityCodec.encode(value, binding: binding, base: base)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw GraphCloudActivationError.invalidState }
        return try GraphCloudAuthorityCodec.decode(saved.get(), binding: binding)
    }, inventory: { config, identity, binding, limits in
        try limits.validate()
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let spool = try GraphCloudAssetSpool(root: config.directory.appendingPathComponent("GraphEvoCloudAssets"))
        let namespace = UUID()
        let zoneID = GraphCloudAuthorityCodec.id(binding).zoneID
        var token: CKServerChangeToken?
        var current = try GraphCloudActivationInventory(sessionDirectory: config.directory)
        var consulted = 0
        repeat {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, resultsLimit: 100)
            consulted += page.modificationResultsByID.count + page.deletions.count
            guard consulted <= 100_000 else { throw GraphCloudActivationError.limitExceeded }
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard id.zoneID == zoneID, record.recordID == id else { throw GraphCloudActivationError.invalidState }
                let archived = try GraphCloudRecordCodec.archive(record, scope: .private)
                let value = try GraphCloudRecordCodec.freeze(archived, identity: identity, binding: binding,
                                                              spool: spool, namespace: namespace)
                try current.store(value)
                guard current.count <= limits.maximumRecords + 3 else { throw GraphCloudActivationError.limitExceeded }
            }
            for deletion in page.deletions { try current.remove(deletion.recordID.recordName) }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        return current
    })
}

extension GraphCloudSession {
    func activationControl<Value: Sendable>(_ body: @Sendable (GraphCloudActivationService, GraphCloudSessionIdentity) async throws -> Value) async throws -> Value {
        guard let service = activationService else { throw GraphCloudActivationError.unavailable }
        return try await withScopeControl(.private) { session in
            let identity = try session.identity()
            try await session.verifyLedgerAccount()
            do {
                let result = try await body(service, identity)
                try await session.verifyLedgerAccount()
                await session.pruneUnpublishedAssets()
                return result
            } catch {
                await session.pruneUnpublishedAssets()
                throw error
            }
        }
    }
}
