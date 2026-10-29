import CoreData
import Foundation
import GraphEvoRuntime
import Testing
@testable import GraphEvo

/// Offline adapter checks: the native container has two local descriptions and no cloud options.
/// These assertions do not establish native setup, assignment or remote import.
@Suite(.timeLimit(.minutes(2))) struct GraphNativePairedLaboratoryTests {
    @Test(arguments: [false, true])
    func optInPairRoutesEqualNodeUUIDsAndPreservesLocalOnlyRejection(sharedLoadsFirst: Bool) async throws {
        GraphValueTransformer.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativePair-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("private.sqlite"), sharedURL = directory.appendingPathComponent("shared.sqlite")
        let container = NSPersistentCloudKitContainer(name: "OfflineNativePair", managedObjectModel: GraphNativeIdentityColumns.makeModel(indexed: true))
        for url in sharedLoadsFirst ? [sharedURL, privateURL] : [privateURL, sharedURL] {
            _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores { try? container.persistentStoreCoordinator.remove(store) }
        }
        let a = GraphID(), b = GraphID(), uuid = UUID()
        let first = GraphNodeID(graphID: a, rawValue: uuid), second = GraphNodeID(graphID: b, rawValue: uuid)
        try await container.performBackgroundTask { context in
            defer { context.rollback(); context.reset() }
            let adapter = GraphNativeIdentityDatabaseAdapter.makeDatabase(allowsMirroredPair: true)
            context.userInfo[StoreNativeContext.containerKey] = container
            context.userInfo[StoreNativeContext.privateURLKey] = privateURL
            context.userInfo[StoreNativeContext.sharedURLKey] = sharedURL
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityDatabaseAdapter.database.catalog(context) }
            try adapter.create(context, a)
            try adapter.graph.insert(context, a, GraphRecord(id: first, type: "item", properties: ["value": .string("private")]))
            try context.save()
            #expect(try GraphTypedStoreAdapter.nativeMembers(context, id: a).allSatisfy { $0.persistentStore?.url == privateURL })
            // Synthetic imported shared rows: seed through a local-only context view, never fake CKShare metadata.
            context.userInfo.removeObject(forKey: StoreNativeContext.containerKey)
            context.userInfo[StoreNativeContext.privateURLKey] = sharedURL
            context.userInfo.removeObject(forKey: StoreNativeContext.sharedURLKey)
            try adapter.create(context, b)
            try adapter.graph.insert(context, b, GraphRecord(id: second, type: "item", properties: ["value": .string("shared")]))
            try context.save(); context.reset()
            context.userInfo[StoreNativeContext.containerKey] = container
            context.userInfo[StoreNativeContext.privateURLKey] = privateURL
            context.userInfo[StoreNativeContext.sharedURLKey] = sharedURL
            #expect(Set(try adapter.catalog(context)) == [a, b])
            #expect(try adapter.graph.fetch(context, a, first)?.properties["value"] == .string("private"))
            #expect(try adapter.graph.fetch(context, b, second)?.properties["value"] == .string("shared"))
            #expect(try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: b, allowsMirroredPair: true) == 1)
            #expect(try GraphTypedStoreAdapter.nativeMembers(context, id: b).allSatisfy { $0.persistentStore?.url == sharedURL })
            #expect(throws: GraphStoreError.self) { try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: b) }
            do { _ = try adapter.graph.fetch(context, a, second); Issue.record("Foreign graph lookup was admitted.") }
            catch GraphStoreError.foreignGraph {}
            let session = try GraphTypedStoreAdapter.Session(context, b, database: true)
            let node = try #require(session.nodes[second])
            #expect(node.runtimeObjectID.persistentStore?.url == sharedURL)
            do {
                _ = try adapter.graph.patch(context, b, GraphRecordPatch(id: second, properties: ["value": .set(.string("denied"))]))
                Issue.record("A shared write without accepted native metadata was admitted.")
            } catch GraphStoreError.permissionDenied {}
            node.node.setValue(nil, forKey: GraphNativeIdentityColumns.nodeAttribute)
            #expect(throws: GraphStoreError.self) { try adapter.graph.fetch(context, b, second) }
            #expect(throws: GraphStoreError.self) {
                try GraphNativeIdentityDatabaseAdapter.validate(context, graphID: b, allowsMirroredPair: true)
            }
            context.rollback()
            #expect(try adapter.graph.fetch(context, b, second)?.properties["value"] == .string("shared"))
            context.userInfo.removeObject(forKey: StoreNativeContext.sharedURLKey)
            #expect(throws: GraphStoreError.self) { try adapter.catalog(context) }
        }
    }
}
