import CloudKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private actor CloudFormatSignal {
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !ready { await withCheckedContinuation { waiting.append($0) } } }
    func signal() { ready = true; let values = waiting; waiting.removeAll(); for value in values { value.resume() } }
}
private final class CloudFormatCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    let ready = CloudFormatSignal()
    let proceed = DispatchSemaphore(value: 0)
    func enable() { lock.withLock { enabled = true } }
    func afterCommit() {
        let pause = lock.withLock { let value = enabled; enabled = false; return value }
        guard pause else { return }
        Task { await ready.signal() }
        _ = proceed.wait(timeout: .now() + 30)
    }
}

@Suite struct GraphCloudNodeCodecTests {
    private let graphID = GraphID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let uuid = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private var binding: GraphCloudBinding {
        GraphCloudBinding(zone: GraphCloudZone(scope: .private, owner: "owner", name: "graph-A"), graphID: graphID)
    }
    private var id: GraphNodeID { GraphNodeID(graphID: graphID, rawValue: uuid) }
    private func node(_ endpoints: GraphEndpoints = .entity, properties: [String: GraphValue] = [:]) throws -> GraphRecord {
        try GraphRecord(id: id, type: "Invoice", endpoints: endpoints, properties: properties, tags: ["z", "a"], groups: ["g"],
                        createdDate: Date(timeIntervalSince1970: -1234.125))
    }
    private func decoded(_ record: GraphRecord) throws -> GraphRecord {
        try GraphCloudNodeCodec.decode(GraphCloudNodeCodec.encode(record, binding: binding), binding: binding).record
    }

    @Test(arguments: ["entity", "relationship", "action"]) func primitivesRoundTrip(_ kind: String) throws {
        let other = GraphNodeID(graphID: graphID)
        let endpoints: GraphEndpoints
        switch kind {
        case "relationship": endpoints = .relationship(subject: nil, object: other)
        case "action": endpoints = .action(subjects: [id, other], objects: [])
        default: endpoints = .entity
        }
        let record = try node(endpoints)
        #expect(try decoded(record) == record)
        let native = try GraphCloudNodeCodec.encode(record, binding: binding)
        #expect(native.recordType == "GraphEvoNode" && native["kind"] as? String == kind)
        #expect(native.recordID.recordName == "node.bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        #expect(native["graphID"] as? String == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(Set(native.allKeys()) == ["format", "graphID", "nodeID", "kind", "type", "payload"])
    }

    @Test func everyValueCaseRemainsLosslessWithoutConsumerCodecRegistration() throws {
        let opaque = try GraphEncodedValue(codec: "application.unknown", version: 91, data: Data([0, 255, 42]))
        let values: [String: GraphValue] = [
            "null": .null, "bool": .boolean(true), "signed": .integer(.min), "unsigned": .unsignedInteger(.max),
            "double": .floatingPoint(-1234.125), "decimal": .decimal(Decimal(string: "12345678901234567890.123456789012345678")!),
            "string": .string("caffè 🐈"), "data": .data(Data([0, 1, 255])), "date": .date(Date(timeIntervalSince1970: 12345.125)),
            "url": .url(URL(string: "https://example.com/a?b=c")!), "uuid": .uuid(uuid),
            "array": .array([.null, .integer(4), .object(["nested": .string("value")])]),
            "object": .object(["data": .data(Data([2, 3])), "null": .null]), "encoded": .encoded(opaque)
        ]
        let record = try node(properties: values)
        #expect(try decoded(record) == record)
        #expect(try decoded(record).properties["missing"] == nil)
        #expect(try decoded(record).properties["null"] == .null)
    }

    @Test func payloadEncodingIsDeterministicAndNilDatesStayAbsent() throws {
        let second = GraphNodeID(graphID: graphID, rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        let first = try GraphRecord(id: id, type: "Action", endpoints: .action(subjects: [id, second], objects: [id]),
                                    properties: ["z": .integer(4), "a": .array([.null])], tags: ["z", "a"], groups: ["b", "a"])
        let reordered = try GraphRecord(id: id, type: "Action", endpoints: .action(subjects: [second, id], objects: [id]),
                                        properties: ["a": .array([.null]), "z": .integer(4)], tags: ["a", "z"], groups: ["a", "b"])
        let a = try GraphCloudNodeCodec.encode(first, binding: binding), b = try GraphCloudNodeCodec.encode(reordered, binding: binding)
        #expect(a["payload"] as? Data == b["payload"] as? Data)
        #expect(try GraphCloudNodeCodec.decode(a, binding: binding).record.createdDate == nil)
    }

    @Test func formatTwoHasAFixedMinimalPayloadAndHeader() throws {
        let minimal = try GraphRecord(id: id, type: "Item")
        let native = try GraphCloudNodeCodec.encode(minimal, binding: binding)
        let payload = try #require(native["payload"] as? Data)
        #expect(String(data: payload, encoding: .utf8) == #"{"endpoints":{"entity":{}},"groups":[],"properties":{},"tags":[]}"#)
        #expect(native["format"] as? NSNumber == NSNumber(value: 2))
        #expect(native["type"] as? String == "Item")
    }

    @Test func formatTwoCarriesDateAndLegacyFormatOneHasUnknownDate() throws {
        let record = try GraphRecord(id: id, type: "Item")
        let date = Date(timeIntervalSince1970: 100)
        let native = try GraphCloudNodeCodec.encode(record, binding: binding, modifiedAt: date)
        #expect(try GraphCloudNodeCodec.decode(native, binding: binding).modifiedAt == date)
        native["format"] = NSNumber(value: 1)
        #expect(try GraphCloudNodeCodec.decode(native, binding: binding).modifiedAt == nil)
        native["format"] = NSNumber(value: 2)
        let raw = try #require(native["payload"] as? Data)
        var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        json["modifiedAt"] = "invalid"
        native["payload"] = try JSONSerialization.data(withJSONObject: json) as CKRecordValue
        #expect(throws: GraphCloudNodeError.invalidRecord) { try GraphCloudNodeCodec.decode(native, binding: binding) }
    }

    @Test func foreignSystemFieldZonesAndRecordTypesAreRejected() throws {
        for foreign in [
            CKRecord(recordType: "Other", recordID: try GraphCloudNodeCodec.recordID(for: id, binding: binding)),
            CKRecord(recordType: "GraphEvoNode", recordID: CKRecord.ID(recordName: "node." + uuid.uuidString.lowercased(), zoneID: CKRecordZone.ID(zoneName: "other", ownerName: "owner")))
        ] {
            let encoder = NSKeyedArchiver(requiringSecureCoding: true)
            foreign.encodeSystemFields(with: encoder); encoder.finishEncoding()
            #expect(throws: GraphCloudNodeError.invalidSystemFields) {
                try GraphCloudNodeCodec.encode(node(), binding: binding, systemFields: encoder.encodedData)
            }
        }
    }

    @Test(arguments: ["version", "boolean-version", "type", "graph", "node", "name", "kind", "payload", "property", "duplicate-tags", "duplicate-endpoints", "extra", "encrypted"]) func malformedRecordsFailVisibly(_ fault: String) throws {
        let native = try GraphCloudNodeCodec.encode(node(), binding: binding)
        switch fault {
        case "version": native["format"] = NSNumber(value: 3)
        case "boolean-version": native["format"] = NSNumber(value: true)
        case "type": native["type"] = "" as CKRecordValue
        case "graph": native["graphID"] = UUID().uuidString as CKRecordValue
        case "node": native["nodeID"] = UUID().uuidString as CKRecordValue
        case "name":
            let foreign = CKRecord(recordType: "GraphEvoNode", recordID: CKRecord.ID(recordName: "other", zoneID: native.recordID.zoneID))
            for key in native.allKeys() { foreign[key] = native[key] }
            #expect(throws: GraphCloudNodeError.self) { try GraphCloudNodeCodec.decode(foreign, binding: binding) }; return
        case "kind": native["kind"] = "relationship" as CKRecordValue
        case "payload": native["payload"] = Data([0, 1]) as CKRecordValue
        case "extra": native["other"] = "unknown" as CKRecordValue
        case "encrypted": native.encryptedValues["hidden"] = "unknown" as NSString
        default:
            let payload = try #require(native["payload"] as? Data)
            var body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            if fault == "property" { body["properties"] = ["bad": Data([0, 1]).base64EncodedString()] }
            else if fault == "duplicate-tags" { body["tags"] = ["duplicate", "duplicate"] }
            else { body["endpoints"] = ["action": ["subjects": [uuid.uuidString, uuid.uuidString], "objects": []]]; native["kind"] = "action" as CKRecordValue }
            native["payload"] = try JSONSerialization.data(withJSONObject: body) as CKRecordValue
        }
        #expect(throws: (any Error).self) { try GraphCloudNodeCodec.decode(native, binding: binding) }
    }

    @Test func zoneAndGraphBindingsDoNotInferDatabaseScope() throws {
        let native = try GraphCloudNodeCodec.encode(node(), binding: binding)
        let wrongGraph = GraphCloudBinding(zone: binding.zone, graphID: GraphID())
        #expect(throws: GraphCloudNodeError.foreignGraph) { try GraphCloudNodeCodec.decode(native, binding: wrongGraph) }
        #expect(throws: GraphCloudNodeError.foreignGraph) { try GraphCloudNodeCodec.encode(node(), binding: wrongGraph) }
        let otherZone = GraphCloudBinding(zone: GraphCloudZone(scope: .private, owner: "other", name: "graph-A"), graphID: graphID)
        #expect(throws: GraphCloudNodeError.foreignZone) { try GraphCloudNodeCodec.decode(native, binding: otherZone) }
        let shared = GraphCloudBinding(zone: GraphCloudZone(scope: .shared, owner: "owner", name: "graph-A"), graphID: graphID)
        #expect(try GraphCloudNodeCodec.decode(native, binding: shared).record.id == id)
        // A CKRecord does not carry database scope. The incoming envelope must match the trusted route.
        let incoming = try GraphCloudRecordCodec.archive(native, scope: .private)
        #expect(throws: GraphCloudNodeError.foreignZone) { try GraphCloudNodeCodec.decode(incoming, binding: shared) }
    }

    @Test func secureSystemFieldsAreBoundToTheRecordAndReusedForEdits() throws {
        let native = try GraphCloudNodeCodec.encode(node(), binding: binding)
        let original = try GraphCloudNodeCodec.decode(native, binding: binding)
        let changed = try node(properties: ["changed": .boolean(true)])
        let updated = try GraphCloudNodeCodec.encode(changed, binding: binding, systemFields: original.systemFields)
        #expect(updated.recordID == native.recordID && updated.recordType == native.recordType)
        #expect(try GraphCloudNodeCodec.decode(updated, binding: binding).record == changed)
        let other = try GraphRecord(id: GraphNodeID(graphID: graphID), type: "Other")
        #expect(throws: GraphCloudNodeError.invalidSystemFields) { try GraphCloudNodeCodec.encode(other, binding: binding, systemFields: original.systemFields) }
        #expect(throws: GraphCloudNodeError.invalidSystemFields) { try GraphCloudNodeCodec.encode(changed, binding: binding, systemFields: Data([0, 1])) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.encode(changed, binding: binding, systemFields: original.systemFields,
                                                                                         limits: .init(maximumSystemFieldsBytes: 1)) }
        // Native server change tags are not fabricated in this network-free fixture.
        #expect(updated.recordChangeTag == native.recordChangeTag)
    }

    @Test func payloadAndCollectionBudgetsRefuseWithoutTruncation() throws {
        let record = try node(properties: ["first": .integer(1), "second": .integer(2)])
        let native = try GraphCloudNodeCodec.encode(record, binding: binding)
        let payload = try #require(native["payload"] as? Data)
        #expect(try GraphCloudNodeCodec.decode(native, binding: binding, limits: .init(maximumPayloadBytes: payload.count)).record == record)
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.encode(record, binding: binding, limits: .init(maximumPayloadBytes: payload.count - 1)) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.decode(native, binding: binding, limits: .init(maximumPayloadBytes: payload.count - 1)) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.encode(record, binding: binding, limits: .init(maximumProperties: 1)) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.decode(native, binding: binding, limits: .init(maximumProperties: 1)) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.encode(record, binding: binding, limits: .init(maximumCollectionItems: 1)) }
        #expect(throws: GraphCloudNodeError.limitExceeded) { try GraphCloudNodeCodec.encode(record, binding: binding, limits: .init(maximumPayloadBytes: 0)) }
    }

    @Test func attachmentAndControlRecordsAreNotSmuggledIntoOpaquePayloads() throws {
        for type in [GraphAttachmentPayload.graphType, "__graphevo_v2.graph"] {
            let record = try GraphRecord(id: id, type: type)
            #expect(throws: GraphCloudNodeError.self) { try GraphCloudNodeCodec.encode(record, binding: binding) }
        }
        #expect(throws: GraphCloudNodeError.invalidRecord) { try GraphCloudNodeCodec.encode(node(properties: ["__graphevo_v2.syncCheckpoint": .data(Data())]), binding: binding) }
        #expect(throws: GraphCloudNodeError.invalidRecord) { try GraphCloudNodeCodec.encode(node(properties: ["bad": .floatingPoint(.infinity)]), binding: binding) }
    }

    @Test func durableInboxShapesDecodeWithoutApplyingOrAcknowledging() throws {
        let record = try node(), native = try GraphCloudNodeCodec.encode(record, binding: binding)
        let incoming = try GraphCloudRecordCodec.archive(native, scope: .private)
        guard case .save(let result) = try GraphCloudNodeCodec.decode(incoming, binding: binding) else { Issue.record("Missing decoded save."); return }
        #expect(result.record == record)
        let deletion = GraphCloudIncoming(kind: .recordDeleted, zone: binding.zone, recordName: native.recordID.recordName, recordType: "GraphEvoNode")
        guard case .delete(let deletedID) = try GraphCloudNodeCodec.decode(deletion, binding: binding) else { Issue.record("Missing decoded deletion."); return }
        #expect(deletedID == id)
        let foreign = GraphCloudIncoming(kind: .recordDeleted, zone: binding.zone, recordName: "legacy", recordType: "Other")
        #expect(throws: GraphCloudNodeError.invalidRecord) { try GraphCloudNodeCodec.decode(foreign, binding: binding) }
        guard case .zoneDeleted(let reason) = try GraphCloudNodeCodec.decode(GraphCloudIncoming(kind: .zoneDeleted, zone: binding.zone, deletionReason: "purged"), binding: binding) else {
            Issue.record("Missing decoded zone deletion."); return
        }
        #expect(reason == "purged")
    }

    @Test func batchValidationPreservesLogicalChangesAndRejectsMismatches() throws {
        let record = try node()
        let change = GraphSyncChange(id: id, nativeKind: "ManagedEntity", operation: .save, generation: 7)
        let batch = GraphSyncBatch(id: UUID(), graphID: graphID, items: [GraphSyncItem(change: change, record: record)], epoch: UUID())
        let result = try GraphCloudNodeCodec.encode(batch, binding: binding)
        #expect(result.id == batch.id && result.items.first?.change == change)
        let empty = GraphSyncBatch(id: UUID(), graphID: graphID, items: [], epoch: UUID())
        let invalidZone = GraphCloudBinding(zone: GraphCloudZone(scope: .private, owner: "", name: ""), graphID: graphID)
        #expect(throws: GraphCloudNodeError.foreignZone) { try GraphCloudNodeCodec.encode(empty, binding: invalidZone) }
        let duplicate = GraphSyncBatch(id: UUID(), graphID: graphID, items: batch.items + batch.items, epoch: UUID())
        #expect(throws: GraphCloudNodeError.invalidBatch) { try GraphCloudNodeCodec.encode(duplicate, binding: binding) }
        let wrong = GraphSyncBatch(id: UUID(), graphID: graphID,
            items: [GraphSyncItem(change: GraphSyncChange(id: id, nativeKind: "ManagedAction", operation: .save, generation: 1), record: record)], epoch: UUID())
        #expect(throws: GraphCloudNodeError.invalidBatch) { try GraphCloudNodeCodec.encode(wrong, binding: binding) }
        let deleted = GraphSyncBatch(id: UUID(), graphID: graphID,
            items: [GraphSyncItem(change: GraphSyncChange(id: id, nativeKind: "ManagedEntity", operation: .delete, generation: 8), record: nil)], epoch: UUID())
        #expect(try GraphCloudNodeCodec.encode(deleted, binding: binding).items.first?.recordArchive == nil)
    }

    @Test func cancelledFailedPreparationDoesNotLeaveAnUnreachableActiveBatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CloudFormatCancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = CloudFormatCommitGate()
        let registry = StoreRegistry(hooks: .init(afterCommit: { gate.afterCommit() }))
        let manager = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: graphID, at: dir.appendingPathComponent("Graph.sqlite"))
        _ = try await graph.transaction { try $0.insert(node()) }
        let route = GraphCloudBinding(zone: binding.zone, graphID: graphID)
        gate.enable()
        let work = Task { try await graph.prepareCloudBatch(maximumRecords: 1, binding: route, encodingLimits: .init(maximumPayloadBytes: 1)) }
        await gate.ready.wait(); work.cancel(); gate.proceed.signal()
        await #expect(throws: GraphCloudNodeError.limitExceeded) { try await work.value }
        #expect(try await graph.collectSyncChanges() == 1)
        let retry = try await graph.prepareCloudBatch(maximumRecords: 1, binding: route)
        #expect(retry.items.count == 1)
        try await graph.abandonSyncBatch(retry.id); try await graph.close()
    }

    @Test func realPHBatchEncodingFailureRetainsPendingAndReleasesAttempt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CloudFormat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = GraphContextManager(registry: StoreRegistry(), schema: GraphRuntimeSchema.nativeIdentity, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: graphID, at: dir.appendingPathComponent("Graph.sqlite"))
        _ = try await graph.transaction { try $0.insert(node(properties: ["value": .integer(1)])) }
        let route = GraphCloudBinding(zone: binding.zone, graphID: graphID)
        await #expect(throws: GraphCloudNodeError.limitExceeded) { try await graph.prepareCloudBatch(maximumRecords: 10, binding: route, encodingLimits: .init(maximumPayloadBytes: 1)) }
        #expect(try await graph.collectSyncChanges() == 1)
        let batch = try await graph.prepareCloudBatch(maximumRecords: 10, binding: route)
        await #expect(throws: GraphSyncError.busy) { try await graph.prepareCloudBatch(maximumRecords: 10, binding: route) }
        let item = try #require(batch.items.first), bytes = try #require(item.recordArchive)
        let native = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: bytes))
        #expect(try GraphCloudNodeCodec.decode(native, binding: route).record.properties["value"] == .integer(1))
        try await graph.transaction { _ = try $0.patch(GraphRecordPatch(id: id, properties: ["value": .set(.integer(2))])) }
        #expect(try await graph.acknowledgeSyncBatch(batch.id, succeeded: [id]) == 0)
        let newer = try await graph.prepareCloudBatch(maximumRecords: 10, binding: route)
        #expect(newer.items.first!.change.generation > item.change.generation)
        try await graph.abandonSyncBatch(newer.id)
        try await graph.delete(id)
        let deletion = try await graph.prepareCloudBatch(maximumRecords: 10, binding: route)
        #expect(deletion.items.first?.change.operation == .delete && deletion.items.first?.recordArchive == nil)
        try await graph.abandonSyncBatch(deletion.id); try await graph.close()
    }
}
