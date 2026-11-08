import CloudKit
import Foundation
import GraphEvoModel

struct GraphCloudDeletionService: Sendable {
    let remove: @Sendable (GraphCloudConfiguration, GraphCloudBinding, Bool) async throws -> Void
    static let live = Self { config, route, allowsEmpty in
        guard route.zone.scope == .private else { throw GraphCloudSharingError.ownerRequired }
        let database = CKContainer(identifier: config.containerIdentifier).privateCloudDatabase
        let id = GraphCloudGraphDescriptor.id(in: route.zone)
        do { _ = try await database.recordZone(for: id.zoneID) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { return }
        do {
            do {
                let record = try await database.record(for: id)
                guard try GraphCloudGraphDescriptor.decode(record, zone: route.zone, supportsFiles: config.supportsFiles) == route.graphID else { throw GraphCloudError.ownershipConflict }
            } catch let error as CKError where error.code == .unknownItem && allowsEmpty {
                let page = try await database.recordZoneChanges(inZoneWith: id.zoneID, since: nil, resultsLimit: 1)
                guard page.modificationResultsByID.isEmpty, page.deletions.isEmpty, !page.moreComing else { throw GraphCloudError.ownershipConflict }
            }
            _ = try await database.deleteRecordZone(withID: id.zoneID)
        } catch let error as CKError where error.code == .zoneNotFound { return }
    }
}
