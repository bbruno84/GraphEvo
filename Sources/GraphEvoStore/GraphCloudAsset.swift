import CloudKit
import Foundation
import GraphEvoModel

/// Portable archives retain bounded bytes, never an SDK staging URL. Native files exist only during a send.
package enum GraphCloudAsset {
    static func bytes(_ value: Any?) throws -> Data {
        if let data = value as? Data {
            guard data.count <= GraphAttachmentPayload.maximumByteCount else { throw GraphCloudError.inboxLimit }
            return data
        }
        guard let asset = value as? CKAsset, let url = asset.fileURL, url.isFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw GraphCloudError.invalidState }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = GraphAttachmentPayload.maximumByteCount - data.count
            guard let chunk = try file.read(upToCount: min(256 * 1024, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw GraphCloudError.inboxLimit }
            data.append(chunk)
        }
        return data
    }

    static func portable(_ record: CKRecord, allowBytes: Bool) throws -> CKRecord {
        guard let copy = record.copy() as? CKRecord else { throw GraphCloudError.invalidState }
        func containsAsset(_ value: Any) -> Bool {
            if value is CKAsset { return true }
            return (value as? [Any])?.contains(where: containsAsset) == true
        }
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            if key == "asset", record.recordType == GraphCloudNodeCodec.recordType,
               record["type"] as? String == GraphAttachmentPayload.graphType {
                guard value is CKAsset || (allowBytes && value is Data) else { throw GraphCloudError.invalidState }
                copy[key] = try bytes(value) as CKRecordValue
            } else if containsAsset(value) { throw GraphCloudError.unsupportedAsset }
        }
        for key in record.encryptedValues.allKeys() {
            if let value = record.encryptedValues[key], containsAsset(value) { throw GraphCloudError.unsupportedAsset }
        }
        return copy
    }

    /// Error.serverRecord contains asset references without downloaded files. Fetch a complete current server value.
    static func completeConflict(_ server: CKRecord,
        fetch: @Sendable (CKRecord.ID) async throws -> CKRecord) async throws -> CKRecord {
        guard server["asset"] is CKAsset else { return server }
        let complete = try await fetch(server.recordID)
        guard complete.recordID == server.recordID, complete.recordType == server.recordType else { throw GraphCloudError.invalidState }
        return complete
    }

    static func materialize(_ record: CKRecord, directory: URL) throws {
        guard record["type"] as? String == GraphAttachmentPayload.graphType else { return }
        let data = try bytes(record["asset"])
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .withoutOverwriting)
        record["asset"] = CKAsset(fileURL: url)
    }
}
