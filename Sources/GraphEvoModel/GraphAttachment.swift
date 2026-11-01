import CryptoKit
import Foundation

/// An attachment has exactly one application-node owner in its logical graph.
public struct GraphAttachmentMetadata: Sendable, Equatable, Codable {
    public let id: GraphNodeID
    public let ownerID: GraphNodeID
    public let fileName: String
    public let contentType: String
    public let byteCount: Int
    public let sha256: String
    public let revision: UUID
}

/// Complete locally readable content, verified against its metadata. No native file URL escapes.
public struct GraphAttachmentContent: Sendable, Equatable {
    public let metadata: GraphAttachmentMetadata
    public let data: Data
    package init(metadata: GraphAttachmentMetadata, data: Data) { self.metadata = metadata; self.data = data }
}

public enum GraphAttachmentError: Error {
    case invalidMetadata
    case invalidFileURL
    case limitExceeded(maxBytes: Int)
    case incompleteOrInvalidContent
    case unsupportedVersion
    case notAnAttachment
    case missingOwner
    case conflict
    case destinationExists
}

/// Alpha representation over the existing native Entity/property model, not a frozen schema.
package struct GraphAttachmentPayload: GraphModel {
    package static let graphType = "GraphEvo.Attachment.v1"
    package static let graphKind: GraphNodeKind = .entity
    package static let contentKey = "content"
    package static let metadataKey = "attachmentMetadata"
    private struct MetadataEnvelope: Codable {
        let version: Int
        let metadata: GraphAttachmentMetadata
    }
    package static let maximumByteCount = 10 * 1024 * 1024
    private struct Envelope: Codable {
        let version: Int
        let metadata: GraphAttachmentMetadata
        let data: Data
    }
    package let content: GraphAttachmentContent
    package var id: GraphNodeID { content.metadata.id }
    package var ownerID: GraphNodeID { content.metadata.ownerID }

    package init(id: GraphNodeID, ownerID: GraphNodeID, fileName: String, contentType: String, data: Data) throws {
        let metadata = GraphAttachmentMetadata(id: id, ownerID: ownerID, fileName: fileName,
            contentType: contentType, byteCount: data.count, sha256: Self.digest(data), revision: UUID())
        try Self.validate(metadata, data: data)
        content = GraphAttachmentContent(metadata: metadata, data: data)
    }

    package init(metadata: GraphAttachmentMetadata, data: Data) throws {
        try Self.validate(metadata, data: data)
        content = GraphAttachmentContent(metadata: metadata, data: data)
    }

    package init(graphRecord: GraphRecord) throws {
        guard graphRecord.type == Self.graphType, graphRecord.endpoints == .entity else { throw GraphAttachmentError.notAnAttachment }
        if graphRecord.properties[Self.metadataKey] == nil {
            let envelope = try Self.legacyEnvelope(graphRecord)
            try Self.validate(envelope.metadata, data: envelope.data)
            content = GraphAttachmentContent(metadata: envelope.metadata, data: envelope.data)
            return
        }
        let metadata = try Self.metadata(from: graphRecord)
        let data: Data = try graphRecord.value(for: Self.contentKey)
        try Self.validate(metadata, data: data)
        content = GraphAttachmentContent(metadata: metadata, data: data)
    }

    /// Metadata is descriptive; only a complete content read verifies body availability and checksum.
    package static func metadata(from record: GraphRecord) throws -> GraphAttachmentMetadata {
        guard record.type == graphType, record.endpoints == .entity else { throw GraphAttachmentError.notAnAttachment }
        guard record.properties[metadataKey] != nil else { return try GraphAttachmentPayload(legacy: record).content.metadata }
        let bytes: Data = try record.value(for: metadataKey)
        let envelope: MetadataEnvelope
        do { envelope = try PropertyListDecoder().decode(MetadataEnvelope.self, from: bytes) }
        catch { throw GraphAttachmentError.incompleteOrInvalidContent }
        guard envelope.version == 2 else { throw GraphAttachmentError.unsupportedVersion }
        guard envelope.metadata.id == record.id else { throw GraphAttachmentError.incompleteOrInvalidContent }
        try validateMetadata(envelope.metadata)
        return envelope.metadata
    }

    private static func legacyEnvelope(_ record: GraphRecord) throws -> Envelope {
        let bytes: Data = try record.value(for: contentKey)
        let envelope: Envelope
        do { envelope = try PropertyListDecoder().decode(Envelope.self, from: bytes) }
        catch { throw GraphAttachmentError.incompleteOrInvalidContent }
        guard envelope.version == 1 else { throw GraphAttachmentError.unsupportedVersion }
        guard envelope.metadata.id == record.id else { throw GraphAttachmentError.incompleteOrInvalidContent }
        return envelope
    }

    private init(legacy record: GraphRecord) throws {
        let envelope = try Self.legacyEnvelope(record)
        try Self.validate(envelope.metadata, data: envelope.data)
        content = GraphAttachmentContent(metadata: envelope.metadata, data: envelope.data)
    }

    /// Existing envelopes remain readable and replaceable without adding shared native rows.
    package func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        guard graphID == id.graphID else { throw GraphModelError.crossGraphReference }
        return try graphRecord(legacy: false)
    }

    package func graphRecord(legacy: Bool) throws -> GraphRecord {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        if legacy {
            let bytes = try encoder.encode(Envelope(version: 1, metadata: content.metadata, data: content.data))
            return try GraphRecord(id: id, type: Self.graphType, properties: [Self.contentKey: .data(bytes)])
        }
        let metadata = try encoder.encode(MetadataEnvelope(version: 2, metadata: content.metadata))
        return try GraphRecord(id: id, type: Self.graphType, properties: [Self.metadataKey: .data(metadata), Self.contentKey: .data(content.data)])
    }

    private static func validateMetadata(_ metadata: GraphAttachmentMetadata) throws {
        guard metadata.id.graphID == metadata.ownerID.graphID, metadata.id != metadata.ownerID,
              !metadata.fileName.isEmpty, ![".", ".."].contains(metadata.fileName),
              !metadata.fileName.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" }),
              !metadata.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...maximumByteCount).contains(metadata.byteCount), metadata.sha256.utf8.count == 64,
              metadata.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GraphAttachmentError.invalidMetadata
        }
    }

    private static func validate(_ metadata: GraphAttachmentMetadata, data: Data) throws {
        try validateMetadata(metadata)
        guard data.count <= maximumByteCount else { throw GraphAttachmentError.limitExceeded(maxBytes: maximumByteCount) }
        guard metadata.byteCount == data.count, metadata.sha256 == digest(data) else {
            throw GraphAttachmentError.incompleteOrInvalidContent
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension GraphAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "The attachment metadata or owner is invalid."
        case .invalidFileURL: return "A supported local file or directory URL is required."
        case .limitExceeded(let maximum): return "The attachment exceeds the supported limit of \(maximum) bytes."
        case .incompleteOrInvalidContent: return "The attachment content is incomplete or does not match its metadata."
        case .unsupportedVersion: return "The attachment format version is unsupported."
        case .notAnAttachment: return "The requested node is not an attachment."
        case .missingOwner: return "The attachment's application-node owner is not available."
        case .conflict: return "The attachment changed while the replacement was being prepared."
        case .destinationExists: return "The destination already exists."
        }
    }
}
