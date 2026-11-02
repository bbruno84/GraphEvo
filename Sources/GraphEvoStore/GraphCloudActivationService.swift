import CloudKit
import Foundation
import GraphEvoModel

/// Direct control and verification requests use the existing session scope gate, never another engine.
struct GraphCloudActivationService: Sendable {
    let ensureZone: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> Void
    let fetch: @Sendable (GraphCloudConfiguration, GraphCloudBinding) async throws -> GraphCloudAuthorityRemote?
    let save: @Sendable (GraphCloudConfiguration, GraphCloudBinding, GraphCloudAuthority, GraphCloudAuthorityRemote?) async throws -> GraphCloudAuthorityRemote
    let inventory: @Sendable (GraphCloudConfiguration, GraphCloudBinding, GraphCloudActivationLimits) async throws -> [GraphCloudIncoming]

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
    }, inventory: { config, binding, limits in
        try limits.validate()
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let zoneID = GraphCloudAuthorityCodec.id(binding).zoneID
        var token: CKServerChangeToken?
        var current: [String: GraphCloudIncoming] = [:]
        var consulted = 0, bytes = 0
        repeat {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, resultsLimit: 100)
            consulted += page.modificationResultsByID.count + page.deletions.count
            guard consulted <= 100_000 else { throw GraphCloudActivationError.limitExceeded }
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard id.zoneID == zoneID, record.recordID == id else { throw GraphCloudActivationError.invalidState }
                let value = try GraphCloudRecordCodec.archive(record, scope: .private)
                let count = value.recordArchive?.count ?? 0
                // Portable archives include assets and secure-archive overhead; use separate bounded headroom.
                guard count <= limits.maximumPayloadBytes + 4 * 1024 * 1024 - bytes else { throw GraphCloudActivationError.limitExceeded }
                bytes += count
                current[id.recordName] = value
                guard current.count <= limits.maximumRecords + 1 else { throw GraphCloudActivationError.limitExceeded }
            }
            for deletion in page.deletions { current.removeValue(forKey: deletion.recordID.recordName) }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        return current.values.sorted { ($0.recordName ?? "") < ($1.recordName ?? "") }
    })
}

extension GraphCloudSession {
    func activationControl<Value: Sendable>(_ body: @Sendable (GraphCloudActivationService, GraphCloudSessionIdentity) async throws -> Value) async throws -> Value {
        guard let service = activationService else { throw GraphCloudActivationError.unavailable }
        return try await withScopeControl(.private) { session in
            let identity = try session.identity()
            try await session.verifyLedgerAccount()
            return try await body(service, identity)
        }
    }
}
