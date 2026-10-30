import Foundation

/// Logical graph identity, independent of a file URL or runtime owner generation.
public struct GraphID: Sendable, Hashable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A graph-aware logical node reference, never a Core Data or CloudKit identifier.
public struct GraphNodeID: Sendable, Hashable, Codable {
    public let graphID: GraphID
    public let rawValue: UUID
    public init(graphID: GraphID, rawValue: UUID = UUID()) {
        self.graphID = graphID
        self.rawValue = rawValue
    }
}

public enum GraphNodeKind: Sendable, Equatable {
    case entity, relationship, action
}

/// Optional relationship endpoints and empty action sets retain valid v1 shapes.
/// References do not imply that their targets have already been resolved/imported.
public enum GraphEndpoints: Sendable, Equatable {
    case entity
    case relationship(subject: GraphNodeID?, object: GraphNodeID?)
    case action(subjects: Set<GraphNodeID>, objects: Set<GraphNodeID>)

    public var kind: GraphNodeKind {
        switch self {
        case .entity: return .entity
        case .relationship: return .relationship
        case .action: return .action
        }
    }

    var references: Set<GraphNodeID> {
        switch self {
        case .entity: return []
        case .relationship(let subject, let object): return Set([subject, object].compactMap { $0 })
        case .action(let subjects, let objects): return subjects.union(objects)
        }
    }
}

/// A detached node envelope; construction validates shape, not target existence or cloud completeness.
public struct GraphRecord: Sendable, Equatable {
    public let id: GraphNodeID
    public let type: String
    public let endpoints: GraphEndpoints
    public let properties: [String: GraphValue]
    public let tags: Set<String>
    public let groups: Set<String>
    public let createdDate: Date?
    public let dataVersion: Int64?

    public init(id: GraphNodeID, type: String, endpoints: GraphEndpoints = .entity,
                properties: [String: GraphValue] = [:], tags: Set<String> = [],
                groups: Set<String> = [], createdDate: Date? = nil, dataVersion: Int64? = nil) throws {
        guard dataVersion.map({ $0 >= 0 }) ?? true else { throw GraphDataFormatError.invalidVersion }
        guard !type.isEmpty, properties.keys.allSatisfy({ !$0.isEmpty }) else {
            throw GraphModelError.invalidRecord("Type and property keys must be nonempty.")
        }
        guard endpoints.references.allSatisfy({ $0.graphID == id.graphID }) else {
            throw GraphModelError.crossGraphReference
        }
        self.id = id
        self.type = type
        self.endpoints = endpoints
        self.properties = properties
        self.tags = tags
        self.groups = groups
        self.createdDate = createdDate
        self.dataVersion = dataVersion
    }

    public func value<Value: GraphPropertyValue>(for key: String, as type: Value.Type = Value.self) throws -> Value {
        guard let value = properties[key] else { throw GraphModelError.missingProperty(key) }
        do { return try Value(graphValue: value) }
        catch { throw GraphModelError.propertyDecodingFailed(key, underlying: error) }
    }

    public func decoded<Model: GraphModel>(as type: Model.Type = Model.self) throws -> Model {
        try validate(type: Model.graphType, kind: Model.graphKind)
        guard Model.graphDataFormat.canRead(dataVersion) else { throw GraphDataFormatError.unreadableVersion(dataVersion) }
        let model = try Model(graphRecord: self)
        guard model.id == id else { throw GraphModelError.identityMismatch }
        return model
    }

    public init<Model: GraphModel>(_ model: Model) throws {
        let record = try model.graphRecord()
        try record.validate(type: Model.graphType, kind: Model.graphKind)
        guard Model.graphDataFormat.canWrite(record.dataVersion) else {
            throw GraphDataFormatError.unwritableVersion(record.dataVersion)
        }
        guard record.id == model.id else { throw GraphModelError.identityMismatch }
        self = record
    }

    private func validate(type: String, kind: GraphNodeKind) throws {
        guard self.type == type else { throw GraphModelError.unexpectedType }
        guard endpoints.kind == kind else { throw GraphModelError.unexpectedKind }
    }
}

/// Application-defined mapping with stable persisted keys and transferable results.
public protocol GraphModel: Sendable {
    var id: GraphNodeID { get }
    static var graphType: String { get }
    static var graphKind: GraphNodeKind { get }
    static var graphDataFormat: GraphDataFormat { get }
    init(graphRecord: GraphRecord) throws
    func graphRecord() throws -> GraphRecord
}

extension GraphModel {
    public static var graphDataFormat: GraphDataFormat { .undeclared }
}

public enum GraphModelError: Error {
    case invalidRecord(String)
    case invalidValue
    case missingProperty(String)
    case propertyDecodingFailed(String, underlying: any Error)
    case unexpectedType
    case unexpectedKind
    case identityMismatch
    case crossGraphReference
    case conflictingPatch
    case unsupportedLegacyValue(String)
}

extension GraphModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason): return "Invalid graph record: \(reason)"
        case .invalidValue: return "The graph value has an unexpected representation."
        case .missingProperty(let key): return "The required graph property is missing: \(key)."
        case .propertyDecodingFailed(let key, _): return "The graph property could not be decoded: \(key)."
        case .unexpectedType: return "The graph record has an unexpected logical type."
        case .unexpectedKind: return "The graph record has an unexpected node kind."
        case .identityMismatch: return "The graph record identity does not match the operation."
        case .crossGraphReference: return "A graph reference points to another graph."
        case .conflictingPatch: return "The graph patch contains conflicting changes."
        case .unsupportedLegacyValue(let key): return "The legacy property requires an explicit value adapter: \(key)."
        }
    }
}
