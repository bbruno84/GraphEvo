import Foundation

public enum GraphFileError: Error {
    case unavailable
    case localOnly
    case invalidMetadata
    case fixedMetadata
    case missingContent
    case corruptContent
    case conflict
}

/// Fixed metadata for a first-class file node.
public struct GraphFile: Sendable, Equatable, Identifiable, Codable {
    public static let nodeType = "GraphEvo.File.v1"
    public let id: GraphNodeID
    public let name: String
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String
    public let revision: UUID

    private enum CodingKeys: String, CodingKey { case id, name, contentType, byteCount, sha256, revision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(GraphNodeID.self, forKey: .id),
            name: values.decode(String.self, forKey: .name), contentType: values.decode(String.self, forKey: .contentType),
            byteCount: values.decode(Int64.self, forKey: .byteCount), sha256: values.decode(String.self, forKey: .sha256),
            revision: values.decode(UUID.self, forKey: .revision))
    }

    package init(id: GraphNodeID, name: String, contentType: String, byteCount: Int64, sha256: String, revision: UUID) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              !contentType.isEmpty, !contentType.contains("\0"), byteCount >= 0,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw GraphFileError.invalidMetadata }
        self.id = id
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }
}
