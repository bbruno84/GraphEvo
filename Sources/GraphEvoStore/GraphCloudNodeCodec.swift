import CloudKit
import CoreFoundation
import Foundation
import GraphEvoModel

package enum GraphCloudNodeError: Error, Equatable {
    case invalidRecord, unsupportedVersion, foreignGraph, foreignZone, invalidSystemFields
    case limitExceeded, unsupportedAttachment, invalidBatch
}

/// Transport budgets, not a guarantee that CloudKit accepts a record's total server-side size.
package struct GraphCloudNodeLimits: Sendable {
    package let maximumPayloadBytes: Int
    package let maximumProperties: Int
    package let maximumCollectionItems: Int
    package let maximumSystemFieldsBytes: Int
    package init(maximumPayloadBytes: Int = 512 * 1024, maximumProperties: Int = 4096,
                 maximumCollectionItems: Int = 4096, maximumSystemFieldsBytes: Int = 64 * 1024) {
        self.maximumPayloadBytes = maximumPayloadBytes; self.maximumProperties = maximumProperties
        self.maximumCollectionItems = maximumCollectionItems; self.maximumSystemFieldsBytes = maximumSystemFieldsBytes
    }
    func validate() throws {
        guard maximumPayloadBytes > 0, maximumProperties > 0, maximumCollectionItems > 0,
              maximumSystemFieldsBytes > 0 else { throw GraphCloudNodeError.limitExceeded }
    }
}

package struct GraphCloudDecodedNode: Sendable {
    package let record: GraphRecord
    package let systemFields: Data
    package let modifiedAt: Date?
}

package enum GraphCloudDecodedEvent: Sendable {
    case save(GraphCloudDecodedNode)
    case delete(GraphNodeID)
    case zoneChanged, zoneDeleted(reason: String?)
}

/// CF01 transport shape: one application primitive per record, independent of native Core Data rows.
package enum GraphCloudNodeCodec {
    package static let recordType = "GraphEvoNode"
    private static let reservedPrefix = "__graphevo_v2."
    private static let keys: Set<String> = ["format", "graphID", "nodeID", "kind", "type", "payload"]
    private enum Endpoints: Codable {
        case entity
        case relationship(subject: UUID?, object: UUID?)
        case action(subjects: [UUID], objects: [UUID])
    }
    private struct Attachment: Codable {
        let metadata: GraphAttachmentMetadata
        let legacy: Bool
    }
    private struct Body: Codable {
        let properties: [String: Data]
        let tags: [String]
        let groups: [String]
        let endpoints: Endpoints
        let createdDate: Date?
        var modifiedAt: Date?
        var attachment: Attachment?
    }

    package static func recordID(for id: GraphNodeID, binding: GraphCloudBinding) throws -> CKRecord.ID {
        guard id.graphID == binding.graphID else { throw GraphCloudNodeError.foreignGraph }
        guard !binding.zone.name.isEmpty, !binding.zone.owner.isEmpty else { throw GraphCloudNodeError.foreignZone }
        return CKRecord.ID(recordName: "node." + id.rawValue.uuidString.lowercased(),
                           zoneID: CKRecordZone.ID(zoneName: binding.zone.name, ownerName: binding.zone.owner))
    }

    private static func logicalID(_ recordID: CKRecord.ID, binding: GraphCloudBinding) throws -> GraphNodeID {
        guard !binding.zone.name.isEmpty, !binding.zone.owner.isEmpty,
              recordID.zoneID.zoneName == binding.zone.name, recordID.zoneID.ownerName == binding.zone.owner else {
            throw GraphCloudNodeError.foreignZone
        }
        let name = recordID.recordName
        guard name.hasPrefix("node."), let uuid = UUID(uuidString: String(name.dropFirst(5))),
              name == "node." + uuid.uuidString.lowercased() else { throw GraphCloudNodeError.invalidRecord }
        return GraphNodeID(graphID: binding.graphID, rawValue: uuid)
    }

    private static func validate(_ record: GraphRecord, limits: GraphCloudNodeLimits) throws {
        if record.type == GraphAttachmentPayload.graphType {
            do { _ = try GraphAttachmentPayload(graphRecord: record) }
            catch { throw GraphCloudNodeError.invalidRecord }
        }
        guard !record.type.hasPrefix(reservedPrefix), record.properties.keys.allSatisfy({ !$0.hasPrefix(reservedPrefix) }) else {
            throw GraphCloudNodeError.invalidRecord
        }
        guard record.properties.count <= limits.maximumProperties, record.tags.count <= limits.maximumCollectionItems,
              record.groups.count <= limits.maximumCollectionItems else { throw GraphCloudNodeError.limitExceeded }
    }

    private static func body(_ record: GraphRecord, limits: GraphCloudNodeLimits) throws -> Body {
        let endpoints: Endpoints
        switch record.endpoints {
        case .entity: endpoints = .entity
        case .relationship(let subject, let object): endpoints = .relationship(subject: subject?.rawValue, object: object?.rawValue)
        case .action(let subjects, let objects):
            guard subjects.count <= limits.maximumCollectionItems, objects.count <= limits.maximumCollectionItems else { throw GraphCloudNodeError.limitExceeded }
            endpoints = .action(subjects: subjects.map(\.rawValue).sorted { $0.uuidString < $1.uuidString },
                                objects: objects.map(\.rawValue).sorted { $0.uuidString < $1.uuidString })
        }
        return Body(properties: try record.properties.mapValues { try GraphValueCodec.encode($0) },
                    tags: record.tags.sorted(), groups: record.groups.sorted(), endpoints: endpoints, createdDate: record.createdDate)
    }

    private static func kind(_ endpoints: GraphEndpoints) -> String {
        switch endpoints { case .entity: return "entity"; case .relationship: return "relationship"; case .action: return "action" }
    }

    private static func native(_ systemFields: Data, limits: GraphCloudNodeLimits) throws -> CKRecord {
        guard systemFields.count <= limits.maximumSystemFieldsBytes else { throw GraphCloudNodeError.limitExceeded }
        do {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            defer { decoder.finishDecoding() }
            guard let record = CKRecord(coder: decoder), decoder.error == nil else { throw GraphCloudNodeError.invalidSystemFields }
            return record
        } catch let error as GraphCloudNodeError { throw error }
        catch { throw GraphCloudNodeError.invalidSystemFields }
    }

    package static func changeTag(_ systemFields: Data, for id: GraphNodeID, binding: GraphCloudBinding) throws -> String? {
        let record = try native(systemFields, limits: .init())
        guard record.recordID == (try recordID(for: id, binding: binding)), record.recordType == recordType else { throw GraphCloudNodeError.invalidSystemFields }
        return record.recordChangeTag
    }
    package static func matchesFrozenServer(_ server: CKRecord, item: GraphCloudOutgoingNode, binding: GraphCloudBinding) -> Bool {
        guard let bytes = item.recordArchive,
              let original = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes),
              let wanted = try? decode(original, binding: binding), let actual = try? decode(server, binding: binding) else { return false }
        return wanted.record == actual.record && wanted.modifiedAt == actual.modifiedAt
    }
    package static func sameServerVersion(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }; return left == right
    }

    package static func encode(_ record: GraphRecord, binding: GraphCloudBinding, systemFields: Data? = nil, modifiedAt: Date? = nil,
                               limits: GraphCloudNodeLimits = .init()) throws -> CKRecord {
        try limits.validate(); try validate(record, limits: limits)
        let id = try recordID(for: record.id, binding: binding)
        let data: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let modifiedAt, !modifiedAt.timeIntervalSinceReferenceDate.isFinite { throw GraphCloudNodeError.invalidRecord }
            var projection = record
            var attachment: Attachment?
            if record.type == GraphAttachmentPayload.graphType {
                let payload = try GraphAttachmentPayload(graphRecord: record)
                attachment = Attachment(metadata: payload.content.metadata, legacy: record.properties[GraphAttachmentPayload.metadataKey] == nil)
                projection = try GraphRecord(id: record.id, type: record.type, endpoints: record.endpoints,
                    properties: record.properties.filter { $0.key != GraphAttachmentPayload.contentKey && $0.key != GraphAttachmentPayload.metadataKey },
                    tags: record.tags, groups: record.groups, createdDate: record.createdDate)
            }
            var value = try body(projection, limits: limits)
            value.modifiedAt = modifiedAt
            value.attachment = attachment
            data = try encoder.encode(value)
        } catch let error as GraphCloudNodeError { throw error }
        catch { throw GraphCloudNodeError.invalidRecord }
        guard data.count <= limits.maximumPayloadBytes else { throw GraphCloudNodeError.limitExceeded }
        let native = try systemFields.map { try self.native($0, limits: limits) } ?? CKRecord(recordType: recordType, recordID: id)
        guard native.recordType == recordType, native.recordID == id else { throw GraphCloudNodeError.invalidSystemFields }
        let attachment = record.type == GraphAttachmentPayload.graphType
        native["format"] = NSNumber(value: attachment ? 3 : 2)
        if attachment { native["asset"] = try GraphAttachmentPayload(graphRecord: record).content.data as CKRecordValue }
        native["graphID"] = binding.graphID.rawValue.uuidString.lowercased() as CKRecordValue
        native["nodeID"] = record.id.rawValue.uuidString.lowercased() as CKRecordValue
        native["kind"] = kind(record.endpoints) as CKRecordValue
        native["type"] = record.type as CKRecordValue
        native["payload"] = data as CKRecordValue
        return native
    }

    package static func decode(_ native: CKRecord, binding: GraphCloudBinding,
                               limits: GraphCloudNodeLimits = .init()) throws -> GraphCloudDecodedNode {
        try limits.validate()
        let isAttachment = native["type"] as? String == GraphAttachmentPayload.graphType
        guard native.recordType == recordType, Set(native.allKeys()) == (isAttachment ? keys.union(["asset"]) : keys), native.encryptedValues.allKeys().isEmpty else {
            throw GraphCloudNodeError.invalidRecord
        }
        let id = try logicalID(native.recordID, binding: binding)
        guard let format = native["format"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(),
              (format == NSNumber(value: 1) || format == NSNumber(value: 2) || format == NSNumber(value: 3)) else { throw GraphCloudNodeError.unsupportedVersion }
        guard native["graphID"] as? String == binding.graphID.rawValue.uuidString.lowercased() else { throw GraphCloudNodeError.foreignGraph }
        guard native["nodeID"] as? String == id.rawValue.uuidString.lowercased(),
              let type = native["type"] as? String, let expectedKind = native["kind"] as? String,
              let data = native["payload"] as? Data else { throw GraphCloudNodeError.invalidRecord }
        guard data.count <= limits.maximumPayloadBytes else { throw GraphCloudNodeError.limitExceeded }
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) }
        catch { throw GraphCloudNodeError.invalidRecord }
        let modifiedAt = format == NSNumber(value: 1) ? nil : body.modifiedAt
        if let modifiedAt, !modifiedAt.timeIntervalSinceReferenceDate.isFinite { throw GraphCloudNodeError.invalidRecord }
        guard body.properties.count <= limits.maximumProperties, body.tags.count <= limits.maximumCollectionItems,
              body.groups.count <= limits.maximumCollectionItems else { throw GraphCloudNodeError.limitExceeded }
        guard Set(body.tags).count == body.tags.count, Set(body.groups).count == body.groups.count else { throw GraphCloudNodeError.invalidRecord }
        func reference(_ uuid: UUID) -> GraphNodeID { GraphNodeID(graphID: binding.graphID, rawValue: uuid) }
        let endpoints: GraphEndpoints
        switch body.endpoints {
        case .entity: endpoints = .entity
        case .relationship(let subject, let object): endpoints = .relationship(subject: subject.map(reference), object: object.map(reference))
        case .action(let subjects, let objects):
            guard subjects.count <= limits.maximumCollectionItems, objects.count <= limits.maximumCollectionItems else { throw GraphCloudNodeError.limitExceeded }
            guard Set(subjects).count == subjects.count, Set(objects).count == objects.count else { throw GraphCloudNodeError.invalidRecord }
            endpoints = .action(subjects: Set(subjects.map(reference)), objects: Set(objects.map(reference)))
        }
        guard kind(endpoints) == expectedKind else { throw GraphCloudNodeError.invalidRecord }
        var properties = try body.properties.mapValues { try GraphValueCodec.decode($0) }
        if isAttachment {
            guard format == NSNumber(value: 3), let attachment = body.attachment,
                  attachment.metadata.id == id, endpoints == .entity,
                  properties[GraphAttachmentPayload.contentKey] == nil, properties[GraphAttachmentPayload.metadataKey] == nil else { throw GraphCloudNodeError.invalidRecord }
            let bytes = try GraphCloudAsset.bytes(native["asset"])
            let payload = try GraphAttachmentPayload(metadata: attachment.metadata, data: bytes)
            for (key, value) in try payload.graphRecord(legacy: attachment.legacy).properties { properties[key] = value }
        } else {
            guard body.attachment == nil, format != NSNumber(value: 3) else { throw GraphCloudNodeError.invalidRecord }
        }
        let record: GraphRecord
        do {
            record = try GraphRecord(id: id, type: type, endpoints: endpoints,
                                     properties: properties,
                                     tags: Set(body.tags), groups: Set(body.groups), createdDate: body.createdDate)
        } catch { throw GraphCloudNodeError.invalidRecord }
        try validate(record, limits: limits)
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        native.encodeSystemFields(with: encoder); encoder.finishEncoding()
        guard encoder.encodedData.count <= limits.maximumSystemFieldsBytes else { throw GraphCloudNodeError.limitExceeded }
        return GraphCloudDecodedNode(record: record, systemFields: encoder.encodedData, modifiedAt: modifiedAt)
    }

    /// Scope comes from the durable route, never from untrusted record fields.
    package static func decode(_ incoming: GraphCloudIncoming, binding: GraphCloudBinding,
                               limits: GraphCloudNodeLimits = .init()) throws -> GraphCloudDecodedEvent {
        try limits.validate()
        guard incoming.valid, incoming.zone == binding.zone else { throw GraphCloudNodeError.foreignZone }
        switch incoming.kind {
        case .zoneChanged: return .zoneChanged
        case .zoneDeleted: return .zoneDeleted(reason: incoming.deletionReason)
        case .recordDeleted:
            guard incoming.recordType == recordType, let name = incoming.recordName else { throw GraphCloudNodeError.invalidRecord }
            return .delete(try logicalID(CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: incoming.zone.name, ownerName: incoming.zone.owner)), binding: binding))
        case .recordChanged:
            try GraphCloudRecordCodec.validate(incoming)
            guard let data = incoming.recordArchive,
                  let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else { throw GraphCloudNodeError.invalidRecord }
            return .save(try decode(record, binding: binding, limits: limits))
        }
    }
}

/// Detached upload candidates. Preparation is not network admission or acknowledgement.
package struct GraphCloudOutgoingNode: Codable, Equatable, Sendable {
    package let change: GraphSyncChange
    package let recordName: String
    package let recordArchive: Data?
    package init(change: GraphSyncChange, recordName: String, recordArchive: Data?) {
        self.change = change; self.recordName = recordName; self.recordArchive = recordArchive
    }
}
package struct GraphCloudOutgoingBatch: Codable, Equatable, Sendable {
    package let id: UUID
    package let graphID: GraphID
    package let zone: GraphCloudZone
    package let items: [GraphCloudOutgoingNode]
    package init(id: UUID, graphID: GraphID, zone: GraphCloudZone, items: [GraphCloudOutgoingNode]) {
        self.id = id; self.graphID = graphID; self.zone = zone; self.items = items
    }
}

extension GraphCloudNodeCodec {
    package static func encode(_ batch: GraphSyncBatch, binding: GraphCloudBinding,
                               systemFields: [GraphNodeID: Data] = [:], modifiedDates: [GraphNodeID: Date] = [:],
                               limits: GraphCloudNodeLimits = .init()) throws -> GraphCloudOutgoingBatch {
        try limits.validate()
        guard !binding.zone.name.isEmpty, !binding.zone.owner.isEmpty else { throw GraphCloudNodeError.foreignZone }
        guard batch.graphID == binding.graphID, Set(batch.items.map { $0.change.id }).count == batch.items.count else { throw GraphCloudNodeError.invalidBatch }
        let items = try batch.items.map { item -> GraphCloudOutgoingNode in
            guard item.change.id.graphID == batch.graphID, item.change.generation > 0,
                  ["ManagedEntity", "ManagedRelationship", "ManagedAction"].contains(item.change.nativeKind) else { throw GraphCloudNodeError.invalidBatch }
            let id = try recordID(for: item.change.id, binding: binding)
            let archive: Data?
            switch item.change.operation {
            case .save:
                guard let record = item.record, record.id == item.change.id else { throw GraphCloudNodeError.invalidBatch }
                let expected: String
                switch record.endpoints { case .entity: expected = "ManagedEntity"; case .relationship: expected = "ManagedRelationship"; case .action: expected = "ManagedAction" }
                guard item.change.nativeKind == expected else { throw GraphCloudNodeError.invalidBatch }
                let native = try encode(record, binding: binding, systemFields: systemFields[record.id], modifiedAt: modifiedDates[record.id], limits: limits)
                archive = try GraphCloudRecordCodec.archive(native, scope: binding.zone.scope, portableAsset: true).recordArchive
            case .delete:
                guard item.record == nil else { throw GraphCloudNodeError.invalidBatch }
                archive = nil
            }
            return GraphCloudOutgoingNode(change: item.change, recordName: id.recordName, recordArchive: archive)
        }
        return GraphCloudOutgoingBatch(id: batch.id, graphID: batch.graphID, zone: binding.zone, items: items)
    }
}
