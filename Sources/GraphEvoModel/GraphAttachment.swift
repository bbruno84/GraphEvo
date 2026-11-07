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
    public package(set) var propertyKey: String? = nil
    public package(set) var codec: String? = nil
    public package(set) var codecVersion: UInt? = nil
    public package(set) var origin: String? = nil
    public package(set) var sourcePropertyVersion: Int? = nil
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

/// Internal attachment envelope shared by native persistence and transport.
package struct GraphAttachmentPayload: GraphModel {
    package static let graphType = "GraphEvo.Attachment.v1"
    package static let graphKind: GraphNodeKind = .entity
    package static let contentKey = "content"
    package static let metadataKey = "attachmentMetadata"
    private struct MetadataEnvelope: Codable {
        let version: Int
        let metadata: GraphAttachmentMetadata
    }
    package static let maximumByteCount = GraphAttachmentValue.maximumByteCount
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
        guard graphRecord.type == Self.graphType, graphRecord.endpoints == .entity,
              let stored = graphRecord.storedAttachment, stored.metadata.id == graphRecord.id else {
            throw GraphAttachmentError.notAnAttachment
        }
        try Self.validate(stored.metadata, data: stored.data)
        content = stored
    }

    package static func metadata(from record: GraphRecord) throws -> GraphAttachmentMetadata {
        guard record.type == graphType, record.endpoints == .entity, let content = record.storedAttachment, content.metadata.id == record.id else { throw GraphAttachmentError.notAnAttachment }
        try validateMetadata(content.metadata)
        return content.metadata
    }

    package func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        guard graphID == id.graphID else { throw GraphModelError.crossGraphReference }
        return try graphRecord(legacy: false)
    }

    package func graphRecord(legacy: Bool) throws -> GraphRecord {
        var record = try GraphRecord(id: id, type: Self.graphType)
        record.storedAttachment = content
        record.legacyAttachment = legacy
        return record
    }

    package static func metadataBytes(_ metadata: GraphAttachmentMetadata, version: Int = 3) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(MetadataEnvelope(version: version, metadata: metadata))
    }

    package static func decodeMetadata(_ bytes: Data) throws -> GraphAttachmentMetadata {
        let envelope = try PropertyListDecoder().decode(MetadataEnvelope.self, from: bytes)
        guard [2, 3].contains(envelope.version) else { throw GraphAttachmentError.unsupportedVersion }
        try validateMetadata(envelope.metadata)
        return envelope.metadata
    }

    package static func legacyEnvelopeBytes(_ content: GraphAttachmentContent) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(Envelope(version: 1, metadata: content.metadata, data: content.data))
    }

    package static func decodeLegacyEnvelope(_ bytes: Data) throws -> GraphAttachmentContent {
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1 else { throw GraphAttachmentError.unsupportedVersion }
        return try Self(metadata: envelope.metadata, data: envelope.data).content
    }

    package static func validateMetadata(_ metadata: GraphAttachmentMetadata) throws {
        guard metadata.id.graphID == metadata.ownerID.graphID, metadata.id != metadata.ownerID,
              !metadata.fileName.isEmpty, ![".", ".."].contains(metadata.fileName),
              !metadata.fileName.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" }),
              !metadata.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.byteCount >= 0, metadata.propertyKey.map({ !$0.isEmpty }) ?? true,
              metadata.codec.map({ !$0.isEmpty }) ?? true,
              metadata.codecVersion.map({ $0 > 0 }) ?? true,
              (metadata.codec == nil) == (metadata.codecVersion == nil),
              metadata.origin == nil || metadata.origin == "v1",
              metadata.sourcePropertyVersion == nil || metadata.origin == "v1",
              metadata.sha256.utf8.count == 64,
              metadata.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GraphAttachmentError.invalidMetadata
        }
    }

    private static func validate(_ metadata: GraphAttachmentMetadata, data: Data) throws {
        try validateMetadata(metadata)
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
