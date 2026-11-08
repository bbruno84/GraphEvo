import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
@testable import GraphEvo
@testable import GraphEvoStore
@testable import GraphEvoRuntime

private final class KeyedAttachmentReadGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    let resume = DispatchSemaphore(value: 0)
    let writerSubmitted = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var armed = false
    private var committed = false
    func arm() { lock.withLock { armed = true } }
    func didSubmitWrite() { if lock.withLock({ armed }) { writerSubmitted.continuation.yield(()) } }
    func didCommit() { lock.withLock { if armed { committed = true } } }
    var writerCommitted: Bool { lock.withLock { committed } }
    func pause() throws {
        entered.continuation.yield(())
        guard resume.wait(timeout: .now() + 15) == .success else { throw GraphStoreError.resourceReserved }
    }
}

@Suite(.serialized) struct GraphKeyedAttachmentTests {
    private struct Item: GraphModel {
        static let graphType = "Keyed.Item"
        static let graphKind: GraphNodeKind = .entity
        let record: GraphRecord
        var id: GraphNodeID { record.id }
        init(graphRecord: GraphRecord) { record = graphRecord }
        func graphRecord(in graphID: GraphID) -> GraphRecord { record }
    }
    private struct Settings: Codable, Sendable, Equatable { let names: [String]; let count: Int }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Keyed-" + UUID().uuidString) }

    @Test(arguments: [0, 2_097_151, 2_097_152, 2_097_153])
    func insertionAndReplacementEnforceEncodedByteLimit(size: Int) async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GraphContext(), graph = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let id = graph.makeNodeID(), bytes = Data(repeating: 91, count: size)
        let record = try GraphRecord(id: id, type: Item.graphType, attachments: ["body": .init(data: bytes)])
        if size > GraphAttachmentValue.maximumByteCount {
            await #expect(throws: GraphAttachmentError.self) { try await graph.transaction { try $0.insert(record) } }
            #expect(try await graph.read { try $0.record(for: id) } == nil)
            try await graph.transaction { try $0.insert(GraphRecord(id: id, type: Item.graphType, properties: ["name": .string("before")])) }
            await #expect(throws: GraphAttachmentError.self) {
                try await graph.transaction { scope in
                    try scope.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("after"))], attachments: ["body": .set(.init(data: bytes))]))
                }
            }
            #expect(try await graph.read { try $0.record(for: id)?.properties["name"] } == .string("before"))
        } else {
            try await graph.transaction { try $0.insert(record) }
            #expect(try await graph.read { try $0.record(for: id)?.attachmentData(for: "body") } == bytes)
            let metadata = try #require(try await graph.attachments(ownedBy: id).first)
            try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, attachments: ["body": .set(.init(data: bytes))])) }
            #expect(try await graph.attachments(ownedBy: id).first?.id == metadata.id)
        }
        try await graph.close()
    }

    @Test func codableReopenProjectionAndDeletionUseIndependentChannels() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Store.sqlite"), context = GraphContext()
        let graph = try await context.createGraph(id: GraphID(), at: path), id = graph.makeNodeID()
        let settings = Settings(names: ["Ada", "Grace"], count: 2)
        let bytes = Data(repeating: 8, count: 128 * 1024)
        try await graph.transaction { try $0.insert(GraphRecord(id: id, type: Item.graphType,
            properties: ["names": ["one", "two"].graphValue], attachments: ["body": .init(data: bytes), "settings": try .init(codable: settings)])) }
        let budget = try GraphQueryBudget(maximumCandidates: 100, maximumPropertyBytes: 1024)
        let query = GraphQuery<Item>(budget: budget)
        #expect(try await graph.count(query).value == 1)
        #expect(try await graph.project(query, properties: ["names"]).rows.count == 1)
        await #expect(throws: GraphQueryError.self) { try await graph.query(query) }
        try await graph.close()
        let reopened = try await GraphContext().openGraph(id: graph.id, at: path)
        let record = try #require(try await reopened.read { try $0.record(for: id) })
        #expect(try record.attachmentValue(for: "settings", as: Settings.self) == settings)
        #expect(try record.attachmentData(for: "body") == bytes)
        let children = try await reopened.attachments(ownedBy: id)
        try await reopened.delete(id)
        for child in children { #expect(try await reopened.attachment(child.id) == nil) }
        try await reopened.close()
    }
    @Test(.timeLimit(.minutes(2))) func migratedOversizeIsReadableButCannotBeReinsertedOrReplaced() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("V1.sqlite"), destination = root.appendingPathComponent("V2.sqlite")
        let size = 33 * 1024 * 1024 + 1
        let oldIDs = try await seedConversionSource(source, binaryByteCount: size)
        let context = GraphContextManager(schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter), graphID = GraphID()
        let accountAdapter = GraphCloudAdapter(account: { _ in "fixture" }, make: { _, _, _, _ in throw GraphCloudError.transportUnavailable })
        await context.setLocalAccountAdapter(accountAdapter)
        let result = try await context.openGraph(convertingLocalV1: .init(sourceURL: source, destinationURL: destination,
            graphID: graphID, operationID: UUID(), backupRoot: root.appendingPathComponent("Backups"), reason: "Oversize migration regression"))
        let graph = try result.opening.get(), id = try #require(result.conversion.receipt.nodeIDs[oldIDs[0]])
        let original = try #require(try await graph.read { try $0.record(for: id)?.attachments["binary"] })
        #expect(original.data.count == size)
        #expect(original.data == Data(repeating: 91, count: size))
        let metadata = try #require(try await graph.attachments(ownedBy: id).first { $0.propertyKey == "binary" })
        #expect(metadata.origin == "v1")
        _ = try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("edited"))])) }
        await #expect(throws: GraphAttachmentError.self) {
            try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, attachments: ["binary": .set(original)])) }
        }
        let route = GraphCloudBinding(zone: .init(scope: .private, owner: "owner", name: "oversize"), graphID: graphID)
        let content = try #require(try await graph.attachment(metadata.id))
        let record = try GraphAttachmentPayload(metadata: content.metadata, data: content.data).graphRecord(in: graphID)
        let native = try GraphCloudNodeCodec.encode(record, binding: route)
        #expect((native["payload"] as? Data)?.count ?? Int.max < 16 * 1024)
        #expect(try GraphCloudNodeCodec.decode(native, binding: route).record == record)
        let binding = GraphCloudTransportBinding(identity: .init(container: "iCloud.migration-regression", environment: .development, account: "fixture"), route: route)
        _ = try await graph.collectSyncChanges()
        var sentLarge = false
        for _ in 0..<12 {
            let batch = try await graph.prepareTransport(binding)
            if batch.items.isEmpty { break }
            if let item = batch.items.first(where: { $0.change.id == metadata.id }) {
                #expect(batch.items.count == 1)
                #expect(item.assetReference?.byteCount == size)
                sentLarge = true
            }
            let saved = try batch.items.compactMap { item -> GraphCloudIncoming? in
                guard let bytes = item.recordArchive else { return nil }
                return GraphCloudIncoming(kind: .recordChanged, zone: route.zone, recordName: item.recordName,
                    recordType: GraphCloudNodeCodec.recordType, recordArchive: bytes,
                    assetReference: item.assetReference.map { ref in
                        GraphCloudAssetReference(role: .incoming, namespace: ref.namespace, file: ref.file,
                            identity: ref.identity, binding: ref.binding, recordName: ref.recordName,
                            byteCount: ref.byteCount, sha256: ref.sha256)
                    })
            }
            var assets: [String: Data] = [:]
            for item in batch.items where item.assetReference != nil {
                assets[item.recordName] = try await graph.read { try $0.record(for: item.change.id)?.storedAttachment?.data }
            }
            _ = try await graph.commitTransport(binding, receipts: [.init(batchID: batch.id, graphID: graphID,
                zone: route.zone, saved: saved, deletedNames: batch.items.filter { $0.recordArchive == nil }.map(\.recordName), failures: [])], remoteAssets: assets)
        }
        #expect(sentLarge)
        try await graph.close()
        let reopenManager = GraphContextManager(schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
        await reopenManager.setLocalAccountAdapter(accountAdapter)
        let reopened = try await reopenManager.openGraph(id: graphID, at: destination)
        // Local opening does not await account verification. The injected adapter
        // verifies asynchronously; under full-suite load the first read can race it.
        let access = try await reopened.observeCloudAccountState()
        for await state in access {
            if state == .available { break }
            guard state == .isolated(.verificationRequired) else {
                Issue.record("Unexpected injected account state during reopen")
                break
            }
        }
        access.cancel()
        #expect(try await reopened.read { try $0.record(for: id)?.attachments["binary"]?.data.count } == size)
        try await reopened.deleteAttachment(metadata.id)
        #expect(try await reopened.read { try $0.record(for: id)?.attachments["binary"] } == nil)
        try await reopened.close()
    }

    @Test(arguments: [false, true]) func historicalAlphaSchemasAreRefusedUnchanged(files: Bool) async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Old.sqlite"), id = GraphID()
        let manager = GraphContextManager(schema: files ? GraphRuntimeSchema.localFiles : GraphRuntimeSchema.typedProperties, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: id, at: path)
        try await graph.close()
        let original = try Data(contentsOf: path)
        let context = files ? GraphContext.localFiles() : GraphContext()
        await #expect(throws: (any Error).self) { try await context.openGraph(id: id, at: path) }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func codableLimitMeasuresEncodedBytesAndConflictingPatchEditsNothing() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let exact = try GraphAttachmentValue(codable: String(repeating: "x", count: GraphAttachmentValue.maximumByteCount - 2))
        let over = try GraphAttachmentValue(codable: String(repeating: "x", count: GraphAttachmentValue.maximumByteCount - 1))
        #expect(exact.data.count == GraphAttachmentValue.maximumByteCount)
        #expect(over.data.count == GraphAttachmentValue.maximumByteCount + 1)
        let id = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: id, type: Item.graphType, properties: ["name": .string("before")], attachments: ["body": exact])) }
        try await graph.transaction { scope in
            #expect(throws: GraphAttachmentError.self) {
                try scope.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("wrong"))], attachments: ["body": .set(over)]))
            }
            #expect(throws: GraphModelError.self) {
                try scope.patch(GraphRecordPatch(id: id, properties: ["name": .set(.string("wrong")), "body": .set(.null)]))
            }
        }
        let result = try #require(try await graph.read { try $0.record(for: id) })
        #expect(result.properties["name"] == .string("before"))
        #expect(result.attachments["body"] == exact)
        try await graph.close()
    }

    @Test func currentNativeModelsRetainFixedAttachmentFieldsAndHistoricalHashes() throws {
        #expect(GraphRuntimeSchema.attachmentProperties.coordinatesReads && GraphRuntimeSchema.attachmentFiles.coordinatesReads)
        #expect(!GraphRuntimeSchema.typedProperties.coordinatesReads && !GraphRuntimeSchema.localFiles.coordinatesReads)
        for files in [false, true] {
            let model = GraphNativeAttachmentStorage.makeModel(files: files)
            let entity = try #require(model.entitiesByName[ModelIdentifier.entityName])
            let content = try #require(entity.attributesByName[GraphNativeAttachmentStorage.contentKey])
            let metadata = try #require(entity.attributesByName[GraphNativeAttachmentStorage.metadataKey])
            #expect(content.isOptional && content.allowsExternalBinaryDataStorage)
            #expect(metadata.isOptional && !metadata.allowsExternalBinaryDataStorage)
            for key in [GraphNativeAttachmentStorage.ownerKey, GraphNativeAttachmentStorage.propertyKey] {
                #expect(entity.attributesByName[key]?.preservesValueInHistoryOnDeletion == true)
            }
            #expect(entity.indexes.contains { $0.name == "ge_attachment_owner_key" })
            #expect(model.entities.count == (files ? 13 : 12))
            let historical = files ? ManagedGraphFile.makeModel() : GraphNativePropertyStorage.makeModel()
            #expect(historical.entitiesByName[ModelIdentifier.entityName]?.attributesByName[GraphNativeAttachmentStorage.contentKey] == nil)
            #expect(model.entityVersionHashesByName != historical.entityVersionHashesByName)
        }
    }

    @Test func caughtRemovalRefusalCannotCommitEarlierScalarEdits() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let owner = graph.makeNodeID(), other = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, properties: ["name": .string("before")], attachments: ["body": .init(data: Data([1]))]))
            try scope.insert(GraphRecord(id: other, type: Item.graphType, attachments: ["body": .init(data: Data([2]))]))
        }
        let otherChild = try #require(try await graph.attachments(ownedBy: other).first)
        try await graph.transaction { scope in
            try scope.withContext { context, _ in
                let session = try GraphTypedStoreAdapter.Session(context, graph.id, database: true)
                let node = try #require(try session.node(otherChild.id))
                let previous = try #require(node.node.value(forKey: GraphNativeAttachmentStorage.metadataKey) as? Data)
                var invalid = otherChild
                invalid.origin = "invalid"
                let bytes = try GraphAttachmentPayload.metadataBytes(invalid)
                node.node.setValue(bytes, forKey: GraphNativeAttachmentStorage.metadataKey)
                defer { node.node.setValue(previous, forKey: GraphNativeAttachmentStorage.metadataKey) }
                #expect(throws: GraphAttachmentError.self) {
                    try scope.patch(GraphRecordPatch(id: owner, properties: ["name": .set(.string("wrong"))], attachments: ["body": .remove]))
                }
                #expect(try scope.record(for: owner)?.properties["name"] == .string("before"))
                #expect(try scope.record(for: owner)?.attachments["body"]?.data == Data([1]))
            }
        }
        try await graph.close()
    }

    @Test func coldAttachmentReadRetainsAppleGrantUntilItsContentIsDetached() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = KeyedAttachmentReadGate()
        let registry = StoreRegistry(hooks: .init(afterCommit: { gate.didCommit() }, didSubmitCoordinatedWrite: { gate.didSubmitWrite() }))
        let manager = GraphContextManager(registry: registry, schema: GraphRuntimeSchema.attachmentProperties, adapter: GraphCoordinatorFactory.adapter)
        let graph = try await manager.createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let id = graph.makeNodeID(), before = Data(repeating: 31, count: 1024 * 1024), after = Data(repeating: 99, count: 1024 * 1024)
        try await graph.transaction { try $0.insert(GraphRecord(id: id, type: Item.graphType, attachments: ["body": .init(data: before)])) }
        gate.arm()
        let reader = Task {
            try await graph.read { scope in
                _ = try scope.withContext { context, _ in
                    let request = NSFetchRequest<NSDictionary>(entityName: ModelIdentifier.entityName)
                    request.resultType = .dictionaryResultType; request.propertiesToFetch = [GraphNativeIdentityColumns.nodeAttribute]
                    request.predicate = NSPredicate(format: "ge2NodeID == %@", id.rawValue.uuidString)
                    return try context.fetch(request).count
                }
                try gate.pause()
                return try scope.record(for: id)?.attachmentData(for: "body")
            }
        }
        for await _ in gate.entered.stream { break }
        let writer = Task { try await graph.transaction { try $0.patch(GraphRecordPatch(id: id, attachments: ["body": .set(.init(data: after))])) } }
        for await _ in gate.writerSubmitted.stream { break }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!gate.writerCommitted)
        gate.resume.signal()
        #expect(try await reader.value == before)
        _ = try await writer.value
        #expect(try await graph.read { try $0.record(for: id)?.attachmentData(for: "body") } == after)
        try await graph.close()
    }

    @Test func metadataListingNeverMaterializesAnOwnersMissingBody() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let owner = graph.makeNodeID()
        try await graph.transaction { try $0.insert(GraphRecord(id: owner, type: Item.graphType, attachments: ["body": .init(data: Data([1, 2]))])) }
        let metadata = try #require(try await graph.attachments(ownedBy: owner).first)
        try await graph.transaction { scope in
            try scope.withContext { context, _ in
                let node = try #require(try GraphTypedStoreAdapter.Session(context, graph.id, database: true).node(metadata.id))
                let data = node.node.value(forKey: GraphNativeAttachmentStorage.contentKey)
                node.node.setValue(nil, forKey: GraphNativeAttachmentStorage.contentKey)
                defer { node.node.setValue(data, forKey: GraphNativeAttachmentStorage.contentKey) }
                #expect(try scope.attachments(ownedBy: owner) == [metadata])
                #expect(throws: GraphAttachmentError.self) { try scope.attachment(metadata.id) }
            }
        }
        try await graph.close()
    }

    @Test func metadataListingIncludesPendingNamedFieldsAndRejectsBinaryOwners() async throws {
        guard #available(iOS 17, macOS 14, *) else { throw GraphV1ConversionError.unavailable }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await GraphContext().createGraph(id: GraphID(), at: root.appendingPathComponent("Store.sqlite"))
        let owner = graph.makeNodeID()
        try await graph.transaction { scope in
            try scope.insert(GraphRecord(id: owner, type: Item.graphType, attachments: ["first": .init(data: Data([1]))]))
            #expect(try scope.attachments(ownedBy: owner).map(\.propertyKey) == ["first"])
            _ = try scope.patch(GraphRecordPatch(id: owner, attachments: ["second": .set(.init(data: Data([2])))]))
            let metadata = try scope.attachments(ownedBy: owner)
            #expect(Set(metadata.compactMap(\.propertyKey)) == ["first", "second"])
            let child = try #require(metadata.first)
            #expect(throws: GraphAttachmentError.self) { try scope.attachments(ownedBy: child.id) }
            _ = try scope.patch(GraphRecordPatch(id: owner, attachments: ["first": .remove]))
            #expect(try scope.attachments(ownedBy: owner).map(\.propertyKey) == ["second"])
        }
        try await graph.close()
    }

}
