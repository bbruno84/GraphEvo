import CloudKit
import Foundation
import GraphEvoModel

private actor CapacityServer {
    var authorities: [String: GraphCloudAuthorityRemote] = [:]
    var records: [String: GraphCloudIncoming] = [:]
    var sends = 0
    var offline = false
    var ambiguousClaim = false
    var ambiguousPublication = false
    var failRecordOnce = false
    private var sizeRejectedRecord: String?
    func configure(offline: Bool = false, claim: Bool = false, publication: Bool = false, record: Bool = false) {
        self.offline = offline; ambiguousClaim = claim; ambiguousPublication = publication; failRecordOnce = record
    }
    func check() throws { if offline { throw URLError(.notConnectedToInternet) } }
    func key(_ route: GraphCloudBinding) -> String { route.zone.name }
    func fetch(_ route: GraphCloudBinding) throws -> GraphCloudAuthorityRemote? { try check(); return authorities[key(route)] }
    func save(_ value: GraphCloudAuthority, route: GraphCloudBinding, base: GraphCloudAuthorityRemote?) throws -> GraphCloudAuthorityRemote {
        try check()
        let name = key(route)
        guard authorities[name]?.value == base?.value else { throw CKError(.serverRecordChanged) }
        let native = try GraphCloudAuthorityCodec.encode(value, binding: route, base: base)
        let saved = try GraphCloudAuthorityCodec.decode(native, binding: route)
        authorities[name] = saved
        if !value.published && ambiguousClaim { ambiguousClaim = false; throw URLError(.timedOut) }
        if value.published && ambiguousPublication { ambiguousPublication = false; throw URLError(.timedOut) }
        return saved
    }
    func inventory(_ route: GraphCloudBinding) throws -> [GraphCloudIncoming] {
        try check()
        var result = records.values.filter { $0.zone == route.zone && $0.kind == .recordChanged }
        if let authority = authorities[key(route)] {
            result.append(try GraphCloudRecordCodec.archive(GraphCloudRecordCodec.restore(authority.archive), scope: .private))
        }
        return result
    }
    func send(_ batch: GraphCloudOutgoingBatch) async throws -> GraphCloudSentReceipt {
        try check(); sends += 1
        var saved: [GraphCloudIncoming] = [], deleted: [String] = [], failed: [GraphCloudRecordFailure] = []
        for item in batch.items {
            if item.recordName == sizeRejectedRecord {
                failed.append(.init(recordName: item.recordName, code: CKError.Code.limitExceeded.rawValue))
                continue
            }
            if failRecordOnce { failRecordOnce = false; failed.append(.init(recordName: item.recordName, code: CKError.networkFailure.rawValue)); continue }
            if let archive = item.recordArchive {
                let record = try GraphCloudRecordCodec.restore(archive)
                if let reference = item.assetReference {
                    guard let root = batch.assetRoot else { throw GraphCloudError.invalidState }
                    let spool = try GraphCloudAssetSpool(root: root)
                    record["asset"] = try await spool.read(reference, role: .outgoing, identity: reference.identity,
                        binding: reference.binding, recordName: item.recordName,
                        storeID: reference.storeID, epoch: reference.epoch) as CKRecordValue
                }
                let value = try GraphCloudRecordCodec.archive(record, scope: .private, portableAsset: true)
                records[batch.zone.name + item.recordName] = value; saved.append(value)
            } else {
                records.removeValue(forKey: batch.zone.name + item.recordName); deleted.append(item.recordName)
            }
        }
        return .init(batchID: batch.id, graphID: batch.graphID, zone: batch.zone, saved: saved, deletedNames: deleted, failures: failed)
    }
    func removeRecord(_ id: GraphNodeID, route: GraphCloudBinding) { records.removeValue(forKey: route.zone.name + "node." + id.rawValue.uuidString.lowercased()) }
    func removeAuthority(_ route: GraphCloudBinding) { authorities.removeValue(forKey: key(route)) }
    func injectAuthority(_ value: GraphCloudAuthority, route: GraphCloudBinding) throws {
        authorities[key(route)] = try GraphCloudAuthorityCodec.decode(GraphCloudAuthorityCodec.encode(value, binding: route, base: nil), binding: route)
    }
    func injectRecord(_ record: CKRecord, route: GraphCloudBinding) throws {
        records[route.zone.name + record.recordID.recordName] = try GraphCloudRecordCodec.archive(record, scope: .private, portableAsset: true)
    }
    nonisolated var service: GraphCloudActivationService {
        .init(ensureZone: { _, _ in try await self.check() }, fetch: { _, route in try await self.fetch(route) },
              save: { _, route, value, base in try await self.save(value, route: route, base: base) },
              inventory: { configuration, _, route, _ in
                  var inventory = try GraphCloudActivationInventory(sessionDirectory: configuration.directory)
                  for record in try await self.inventory(route) { try inventory.store(record) }
                  return inventory
              })
    }
    nonisolated var adapter: GraphCloudAdapter {
        .init(activation: service, account: { _ in "synthetic-activation-account" }, make: { _, _, _, callback in
            GraphCloudDriver(fetch: { _ in }, cancel: {}, send: { batch in
                await callback(.sent(try await self.send(batch)))
            })
        })
    }
}


package struct DeviceCapacityTransport: Sendable {
    private let server = CapacityServer()
    package init() {}
    package func configure(_ manager: GraphContextManager) async { await manager.setLocalAccountAdapter(server.adapter) }
    package func start(_ manager: GraphContextManager, configuration: GraphCloudConfiguration) async throws {
        _ = try await manager.startCloudSession(configuration, adapter: server.adapter)
    }
    package var sends: Int { get async { await server.sends } }
}
