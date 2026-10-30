import CloudKit
import Foundation

@available(iOS 17, macOS 14, *)
extension GraphCloudAdapter {
    static let live = GraphCloudAdapter(account: { identifier in
        guard Bundle.main.bundleURL.pathExtension != "appex" else { throw GraphCloudError.invalidConfiguration }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw GraphCloudError.accountUnavailable }
        return try await container.userRecordID().recordName
    }, make: { config, scope, state, receive in
        let container = CKContainer(identifier: config.containerIdentifier)
        let database = scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        let serialization: CKSyncEngine.State.Serialization?
        do { serialization = try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) } }
        catch { throw GraphCloudError.invalidState }
        let delegate = GraphCloudNativeDelegate(scope: scope, receive: receive)
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: delegate)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        return GraphCloudDriver(fetch: { zones in
            var options = CKSyncEngine.FetchChangesOptions()
            options.scope = .zoneIDs(zones.map { CKRecordZone.ID(zoneName: $0.name, ownerName: $0.owner) })
            try await engine.fetchChanges(options)
        }, cancel: {
            await engine.cancelOperations()
            // Retain the delegate independently of the framework's delegate reference semantics.
            _ = delegate
        })
    })
}

/// Only detached bytes/IDs cross into the session. No graph writes happen in this delegate.
@available(iOS 17, macOS 14, *)
final class GraphCloudNativeDelegate: CKSyncEngineDelegate {
    private let scope: GraphCloudScope
    private let receive: @Sendable (GraphCloudEvent) async -> Void
    init(scope: GraphCloudScope, receive: @escaping @Sendable (GraphCloudEvent) async -> Void) {
        self.scope = scope; self.receive = receive
    }
    private func zone(_ id: CKRecordZone.ID) -> GraphCloudZone {
        GraphCloudZone(scope: scope, owner: id.ownerName, name: id.zoneName)
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                await receive(.state(try JSONEncoder().encode(update.stateSerialization)))
            case .accountChange(let update):
                switch update.changeType {
                case .signIn(let user): await receive(.account(user.recordName))
                case .signOut: await receive(.account(nil))
                case .switchAccounts: await receive(.failure(.accountChanged))
                @unknown default: await receive(.failure(.accountChanged))
                }
            case .fetchedDatabaseChanges(let update):
                var changes = update.modifications.map { GraphCloudIncoming(kind: .zoneChanged, zone: zone($0.zoneID)) }
                for deletion in update.deletions {
                    let reason: String
                    switch deletion.reason {
                    case .deleted: reason = "deleted"
                    case .purged: reason = "purged"
                    case .encryptedDataReset: reason = "encryptedDataReset"
                    @unknown default: throw GraphCloudError.invalidState
                    }
                    changes.append(GraphCloudIncoming(kind: .zoneDeleted, zone: zone(deletion.zoneID), deletionReason: reason))
                }
                await receive(.incoming(changes))
            case .fetchedRecordZoneChanges(let update):
                var changes = try update.modifications.map { try GraphCloudRecordCodec.archive($0.record, scope: scope) }
                changes += update.deletions.map {
                    GraphCloudIncoming(kind: .recordDeleted, zone: zone($0.recordID.zoneID), recordName: $0.recordID.recordName, recordType: $0.recordType)
                }
                await receive(.incoming(changes))
            case .sentDatabaseChanges, .sentRecordZoneChanges: await receive(.failure(.unexpectedUpload))
            default: break
            }
        } catch { await receive(.failure(error as? GraphCloudError ?? .invalidState)) }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
}

/// Local secure archive codec, independent of engine availability and consumer formats.
enum GraphCloudRecordCodec {
    static func archive(_ record: CKRecord, scope: GraphCloudScope) throws -> GraphCloudIncoming {
        func containsAsset(_ value: Any) -> Bool {
            if value is CKAsset { return true }
            if let values = value as? [Any] { return values.contains(where: containsAsset) }
            return false
        }
        for key in record.allKeys() {
            if let value = record.object(forKey: key), containsAsset(value) { throw GraphCloudError.unsupportedAsset }
        }
        // Encrypted fields can also carry assets; never archive a temporary asset URL.
        for key in record.encryptedValues.allKeys() {
            if let value = record.encryptedValues[key], containsAsset(value) { throw GraphCloudError.unsupportedAsset }
        }
        return GraphCloudIncoming(kind: .recordChanged,
            zone: GraphCloudZone(scope: scope, owner: record.recordID.zoneID.ownerName, name: record.recordID.zoneID.zoneName),
            recordName: record.recordID.recordName, recordType: record.recordType,
            recordArchive: try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true))
    }

    static func validate(_ incoming: GraphCloudIncoming) throws {
        guard incoming.kind == .recordChanged else { return }
        guard let bytes = incoming.recordArchive else { throw GraphCloudError.invalidState }
        let record: CKRecord
        do {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes) else { throw GraphCloudError.invalidState }
            record = decoded
        } catch { throw GraphCloudError.invalidState }
        let checked = try archive(record, scope: incoming.zone.scope)
        guard checked.zone == incoming.zone, checked.recordName == incoming.recordName, checked.recordType == incoming.recordType else {
            throw GraphCloudError.invalidState
        }
    }
}
