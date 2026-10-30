import CoreData
import Foundation
import GraphEvoModel
import GraphEvoStore

extension GraphStore {
    /// The alpha buffers complete content and enforces this limit before native mutation.
    public nonisolated static var maximumAttachmentByteCount: Int { GraphAttachmentPayload.maximumByteCount }

    public func attachment(_ id: GraphNodeID) async throws -> GraphAttachmentContent? {
        try await read { try $0.attachment(id) }
    }

    public func attachments(ownedBy ownerID: GraphNodeID) async throws -> [GraphAttachmentMetadata] {
        try await read { try $0.attachments(ownedBy: ownerID) }
    }

    /// Copies source bytes during coordinated access; no dependency on the source URL is retained.
    public func importAttachment(from source: URL, ownedBy ownerID: GraphNodeID,
                                 fileName: String? = nil, contentType: String = "public.data") async throws -> GraphAttachmentMetadata {
        guard ownerID.graphID == id else { throw GraphStoreError.foreignGraph }
        // Validate ownership/handle before potentially expensive document-provider access.
        try await read { scope in
            guard let owner = try scope.record(for: ownerID), owner.type != GraphAttachmentPayload.graphType else { throw GraphAttachmentError.missingOwner }
        }
        let data = try await GraphAttachmentIO.read(source)
        let payload = try GraphAttachmentPayload(id: makeNodeID(), ownerID: ownerID,
            fileName: fileName ?? source.lastPathComponent, contentType: contentType, data: data)
        let graphID = id
        let shared = try await nativeOperation { native in
            guard let cloud = native as? NSPersistentCloudKitContainer else { return false }
            return try await cloud.performBackgroundTask { context in
                GraphSharingNative.prepare(context, container: cloud)
                return try GraphTypedStoreAdapter.Session(context, graphID, database: true).isShared
            }
        }
        if shared { _ = try await insertShared(payload) }
        else { _ = try await transaction { try $0.insert(payload) } }
        return payload.content.metadata
    }

    /// Preserves identity/owner. Local concurrent replacements must still match the captured revision.
    public func replaceAttachment(_ id: GraphNodeID, from source: URL,
                                  fileName: String? = nil, contentType: String? = nil) async throws -> GraphAttachmentMetadata {
        let (old, legacy) = try await read { scope in
            guard let record = try scope.record(for: id) else { throw GraphStoreError.missingNode }
            let payload = try GraphAttachmentPayload(graphRecord: record)
            guard let owner = try scope.record(for: payload.ownerID), owner.type != GraphAttachmentPayload.graphType else {
                throw GraphAttachmentError.missingOwner
            }
            return (payload.content, record.properties[GraphAttachmentPayload.metadataKey] == nil)
        }
        let bytes = try await GraphAttachmentIO.read(source)
        let replacement = try GraphAttachmentPayload(id: id, ownerID: old.metadata.ownerID,
            fileName: fileName ?? old.metadata.fileName, contentType: contentType ?? old.metadata.contentType, data: bytes)
        let record = try replacement.graphRecord(legacy: legacy)
        let patch = try GraphRecordPatch(id: id, properties: record.properties.mapValues { .set($0) })
        return try await transaction { scope in
            guard let current = try scope.attachment(id) else { throw GraphStoreError.missingNode }
            guard current.metadata.revision == old.metadata.revision else { throw GraphAttachmentError.conflict }
            _ = try scope.patch(patch)
            return replacement.content.metadata
        }
    }

    public func deleteAttachment(_ id: GraphNodeID) async throws {
        try await transaction { scope in
            guard try scope.attachment(id) != nil else { throw GraphStoreError.missingNode }
            try scope.delete(id)
        }
    }

    /// Writes a caller-owned file at a new destination; existing content is never replaced.
    @discardableResult public func exportAttachment(_ id: GraphNodeID, to destination: URL) async throws -> GraphAttachmentMetadata {
        guard let content = try await attachment(id) else { throw GraphStoreError.missingNode }
        try await GraphAttachmentIO.export(content.data, to: destination)
        return content.metadata
    }
}
