import CoreData
import SQLite3
import XCTest
@testable import GraphEvo

final class GraphStructuralValidationRegressionTests: XCTestCase {
    private final class Warnings: GraphEventDelegate {
        var onFailure: ((GraphStructuralValidationFailure) -> Void)?
        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            guard case .warning(.watchReportMaterializationFailed(_, _, let details)) = event else { return }
            for detail in details {
                if let failure = detail.error as? GraphStructuralValidationFailure { onFailure?(failure) }
            }
        }
    }

    /// Make and close a disposable store before altering its archived payload.
    /// Raw SQL is test-only corruption injection, never used by the validator.
    private func payloadFixture(sql: String) throws -> Graph {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ValidationPayload-\(UUID()).sqlite")
        try autoreleasepool {
            GraphValueTransformer.register()
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                at: url, options: [NSPersistentHistoryTrackingKey: true])
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try context.performAndWait {
                context.transactionAuthor = "REMOTE-PAYLOAD"
                let facade = Graph(transactionContext: context, configuration: GraphStoreConfiguration())
                let entity = Entity("Payload", graph: facade)
                entity[dynamicMember: "payload"] = Data([1, 2, 3])
                try context.save()
                context.reset()
            }
            try coordinator.remove(store)
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        return Graph(storeURL: url, migrationEnabled: false)
    }

    func testMalformedPayloadFailsRepeatedValidationEvenAfterAnUnscopedRead() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';")
        let entity = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
        // Populate ordinary Core Data caches before entering the validation scope.
        let request = NSFetchRequest<NSDictionary>(entityName: "ManagedEntityProperty")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["object"]
        _ = try graph.managedObjectContext.fetch(request)
        for _ in 0..<2 {
            let result = entity.validateStructure()
            XCTAssertFalse(result.isValid)
            let issue = try XCTUnwrap(result.issues.first { $0.relationshipName == "propertySet" })
            XCTAssertNotNil(issue.destinationObjectID)
            XCTAssertEqual((issue.error as NSError?)?.domain, NSCocoaErrorDomain)
            XCTAssertEqual((issue.error as NSError?)?.code, CocoaError.coderReadCorrupt.rawValue)
        }
    }

    func testOptionalNilAndValidDataPayloadsDoNotFailValidation() throws {
        for sql in ["UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=NULL;", "SELECT 1;"] {
            let graph = try payloadFixture(sql: sql)
            let entity = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
            XCTAssertTrue(entity.validateStructure().isValid)
        }
    }

    func testDecoderDiagnosticsDoNotLeakIntoLaterReads() throws {
        let transformer = GraphValueTransformer()
        XCTAssertThrowsError(try GraphValueDecodingDiagnostics.checking {
            _ = transformer.transformedValue(Data([0, 1, 2]))
        })
        XCTAssertNoThrow(try GraphValueDecodingDiagnostics.checking {
            _ = transformer.transformedValue(nil)
        })
        XCTAssertNoThrow(try GraphValueDecodingDiagnostics.checking {
            XCTAssertThrowsError(try GraphValueDecodingDiagnostics.checking {
                _ = transformer.transformedValue(Data([0, 1, 2]))
            })
            _ = transformer.transformedValue(try GraphArchiver.archive("valid"))
        })
        XCTAssertNil(transformer.transformedValue(Data([0, 1, 2])))
    }

    func testCorruptCloudPayloadRetainsTokenAndDeliversAfterRepair() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';")
        graph.watchReportSources = [.cloud]
        let warnings = Warnings()
        graph.eventDelegate = warnings
        let failed = expectation(description: "decode failure retains batch")
        failed.assertForOverFulfill = false
        warnings.onFailure = { result in
            XCTAssertTrue(result.result.issues.contains { $0.relationshipName == "propertySet" })
            failed.fulfill()
        }
        let noReport = expectation(description: "corrupt batch not delivered")
        noReport.isInverted = true
        graph.watchReportCompletion = { report, _ in if report != nil { noReport.fulfill() } }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        let tokenStore = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        delivery.request()
        wait(for: [failed, noReport], timeout: 0.5)
        XCTAssertNil(try tokenStore.load())

        let entity = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
        entity[dynamicMember: "payload"] = "repaired"
        graph.sync()
        let delivered = expectation(description: "repaired batch delivered")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.structuralValidationResults.allSatisfy(\.isValid))
            delivered.fulfill()
        }
        delivery.request()
        wait(for: [delivered], timeout: 3)
        XCTAssertNotNil(try tokenStore.load())
    }

    func testLocallyDeletedRemoteInsertIsConsumedWithoutBlockingLaterReports() throws {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidationDeletion-\(UUID()).sqlite"), migrationEnabled: false)
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-BEFORE-LOCAL-DELETE"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            let imported = Entity("Imported", graph: facade)
            imported[dynamicMember: "payload"] = "value"
            imported.add(tags: "tag").add(to: "group")
            try background.save()
        }
        let imported = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Imported")).sync().first)
        imported.delete()
        graph.sync()
        graph.watchReportSources = [.cloud]
        let noReport = expectation(description: "superseded changes produce no report")
        noReport.isInverted = true
        graph.watchReportCompletion = { _, _ in noReport.fulfill() }
        let warnings = Warnings()
        warnings.onFailure = { _ in XCTFail("Known local deletion must not block cloud history") }
        graph.eventDelegate = warnings
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        let tokenStore = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        delivery.request()
        wait(for: [noReport], timeout: 0.5)
        XCTAssertNotNil(try tokenStore.load(), "Even an entirely superseded interval must be consumed")

        try background.performAndWait {
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            _ = Entity("Survivor", graph: facade)
            try background.save()
        }
        let received = expectation(description: "next cloud batch delivers normally")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            let inserted = report.events.compactMap { event -> String? in
                if case .insertedEntity(let entity) = event { return entity.type }
                return nil
            }
            XCTAssertEqual(inserted, ["Survivor"])
            received.fulfill()
        }
        delivery.request()
        wait(for: [received], timeout: 3)
    }

    func testLocalDeletionDoesNotDiscardUnrelatedRemoteEventsInSameInterval() throws {
        let graph = Graph(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidationMixed-\(UUID()).sqlite"), migrationEnabled: false)
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-MIXED"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            _ = Entity("Deleted", graph: facade)
            _ = Entity("Survivor", graph: facade)
            try background.save()
        }
        let deleted = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Deleted")).sync().first)
        deleted.delete()
        graph.sync()
        graph.watchReportSources = [.cloud]
        let received = expectation(description: "surviving events remain deliverable")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertEqual(report.events.count, 1)
            if case .insertedEntity(let entity) = report.events.first { XCTAssertEqual(entity.type, "Survivor") }
            else { XCTFail("Expected the surviving remote insertion") }
            received.fulfill()
        }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        delivery.request()
        wait(for: [received], timeout: 3)
    }

    func testDeletingAnInvalidOwnerAfterFailedDeliveryReleasesTheCursor() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';")
        graph.watchReportSources = [.cloud]
        graph.watchReportCompletion = { _, _ in XCTFail("No valid events remain to deliver") }
        let warnings = Warnings()
        graph.eventDelegate = warnings
        let failed = expectation(description: "initial invalid batch")
        warnings.onFailure = { _ in failed.fulfill() }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        let tokenStore = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        delivery.request()
        wait(for: [failed], timeout: 3)
        XCTAssertNil(try tokenStore.load())
        let entity = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
        entity.delete()
        graph.sync()
        let blocked = expectation(description: "no repeat failure after local deletion")
        blocked.isInverted = true
        warnings.onFailure = { _ in blocked.fulfill() }
        delivery.request()
        wait(for: [blocked], timeout: 0.5)
        XCTAssertNotNil(try tokenStore.load())
    }

}
