import CloudKit
import Foundation

/// Estimates the CloudKit request, whose server-side encoding is opaque.
package struct GraphCloudBatchSizing {
    package static let engineMaximumOperations = 250
    // Allow 10% headroom for CloudKit framing beyond our estimate.
    static let requestBudget = 1_800_000
    static let recordWarning = 900_000

    private var count = 0
    private var bytes = 0
    private var requiresSingleton = false
    package init() {}

    package mutating func append(_ estimate: Int) -> Bool {
        let large = estimate > Self.recordWarning
        guard count == 0 || (!requiresSingleton && !large && count < Self.engineMaximumOperations &&
                             estimate <= Self.requestBudget - bytes) else { return false }
        requiresSingleton = large
        count += 1
        bytes += estimate
        return true
    }

    package static func estimate(_ item: GraphCloudOutgoingNode, zone: GraphCloudZone) throws -> Int {
        // Reserve space for record/operation metadata and CloudKit framing.
        let overhead = 1_024 + item.recordName.utf8.count + zone.name.utf8.count + zone.owner.utf8.count
        guard let archive = item.recordArchive else { return overhead }
        let record = try GraphCloudRecordCodec.restore(archive)
        return record.allKeys().reduce(overhead + record.recordType.utf8.count +
                                        (record.recordChangeTag?.utf8.count ?? 0)) { total, key in
            let field = key.utf8.count + 16
            if key == "asset" { return total + field }
            if let data = record[key] as? Data { return total + field + data.count }
            if let string = record[key] as? String { return total + field + string.utf8.count }
            if record[key] is NSNumber { return total + field + 8 }
            return total + field + archive.count
        }
    }

    static func requests(for batch: GraphCloudOutgoingBatch) throws -> [[GraphCloudOutgoingNode]] {
        var sizing = Self()
        var requests: [[GraphCloudOutgoingNode]] = []
        var items: [GraphCloudOutgoingNode] = []
        for item in batch.items {
            let estimate = try estimate(item, zone: batch.zone)
            if !sizing.append(estimate) {
                requests.append(items)
                items.removeAll()
                sizing = Self()
                _ = sizing.append(estimate)
            }
            items.append(item)
        }
        if !items.isEmpty { requests.append(items) }
        return requests
    }
}
