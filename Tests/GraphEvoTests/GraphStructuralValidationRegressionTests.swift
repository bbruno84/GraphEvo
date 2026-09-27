import CoreData
import SQLite3
import XCTest
@testable import GraphEvo

final class GraphStructuralValidationRegressionTests: XCTestCase {
    private final class Warnings: GraphEventDelegate {
        var onFailure: ((GraphStructuralValidationFailure) -> Void)?
        var onLocalFailure: ((GraphStructuralValidationFailure) -> Void)?
        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            if case .error(.watchEventMaterialization(source: .local, underlying: let error)) = event,
               let failure = error as? GraphStructuralValidationFailure {
                onLocalFailure?(failure)
            }
            guard case .warning(.watchReportMaterializationFailed(_, _, let details)) = event else { return }
            for detail in details {
                if let failure = detail.error as? GraphStructuralValidationFailure { onFailure?(failure) }
            }
        }
    }

    /// Make and close a disposable store before altering its archived payload.
    /// Raw SQL is test-only corruption injection, never used by the validator.
    private func payloadFixture(sql: String, populate: ((Graph) -> Void)? = nil) throws -> Graph {
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
                if let populate {
                    populate(facade)
                } else {
                    let entity = Entity("Payload", graph: facade)
                    entity[dynamicMember: "payload"] = Data([1, 2, 3])
                }
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

    func testCorruptRelationshipDetailsFailBothIncomingAndOutgoingEntityValidation() throws {
        try assertCorruptEdgeDetails(action: false)
    }

    func testCorruptActionDetailsFailBothSubjectAndObjectEntityValidation() throws {
        try assertCorruptEdgeDetails(action: true)
    }

    private func assertCorruptEdgeDetails(action: Bool) throws {
        let table = action ? "ZMANAGEDACTIONPROPERTY" : "ZMANAGEDRELATIONSHIPPROPERTY"
        let graph = try payloadFixture(sql: "UPDATE \(table) SET ZOBJECT=x'000102';") { graph in
            let subject = Entity("Subject", graph: graph)
            let object = Entity("Object", graph: graph)
            let edge: Node = action
                ? subject.will(action: "Edge").add(objects: object)
                : subject.is(relationship: "Edge").of(object)
            edge[dynamicMember: "payload"] = "valid before corruption"
        }
        let edge: Node
        if action { edge = try XCTUnwrap(Search<Action>(graph: graph).where(.type("Edge")).sync().first) }
        else { edge = try XCTUnwrap(Search<Relationship>(graph: graph).where(.type("Edge")).sync().first) }
        let roots: [Node] = [edge] + Search<Entity>(graph: graph).where(.type("Subject") || .type("Object")).sync().map { $0 as Node }
        XCTAssertEqual(roots.count, 3)
        for root in roots {
            let result = root.validateStructure()
            XCTAssertFalse(result.isValid)
            let issue = try XCTUnwrap(result.issues.first)
            XCTAssertEqual(issue.sourceObjectID, edge.node.objectID)
            XCTAssertEqual(issue.relationshipName, "propertySet")
            XCTAssertNotNil(issue.destinationObjectID)
            XCTAssertEqual((issue.error as NSError?)?.code, CocoaError.coderReadCorrupt.rawValue)
        }
    }

    func testCorruptEndpointDetailsRequireSeparateApplicationValidation() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';") { graph in
            let root = Entity("Root", graph: graph)
            let endpoint = Entity("Endpoint", graph: graph)
            endpoint[dynamicMember: "payload"] = "valid before corruption"
            _ = root.is(relationship: "Edge").of(endpoint)
            _ = root.will(action: "Action").add(objects: endpoint)
        }
        let root = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Root")).sync().first)
        let endpoint = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Endpoint")).sync().first)
        let edge = try XCTUnwrap(Search<Relationship>(graph: graph).where(.type("Edge")).sync().first)
        let action = try XCTUnwrap(Search<Action>(graph: graph).where(.type("Action")).sync().first)
        for node in [root as Node, edge, action] {
            let result = node.validateStructure()
            XCTAssertTrue(result.isValid)
            XCTAssertTrue(result.references.contains {
                $0.destinationObjectID == endpoint.node.objectID && $0.state == .materialized
            })
            XCTAssertFalse(result.references.contains { $0.sourceObjectID == endpoint.node.objectID })
        }
        XCTAssertFalse(endpoint.validateStructure().isValid)
    }

    func testLocalBatchOmitsInvalidOwnerAndStillDeliversValidOwner() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';")
        let invalid = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
        let warnings = Warnings()
        graph.eventDelegate = warnings
        graph.watchReportSources = [.local]
        let failure = expectation(description: "invalid local owner diagnosed")
        warnings.onLocalFailure = { diagnostic in
            XCTAssertEqual(diagnostic.result.objectID, invalid.node.objectID)
            failure.fulfill()
        }
        let received = expectation(description: "valid local owner delivered")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertEqual(report.events.count, 1)
            if case .insertedEntity(let node) = report.events.first { XCTAssertEqual(node.type, "Valid") }
            else { XCTFail("Expected only the valid owner insertion") }
            XCTAssertEqual(report.structuralValidationResults.count, 2)
            XCTAssertEqual(report.structuralValidationResults.first { $0.objectID == invalid.node.objectID }?.isValid, false)
            received.fulfill()
        }
        invalid[dynamicMember: "anotherProperty"] = "local change"
        _ = Entity("Valid", graph: graph)
        graph.sync()
        wait(for: [failure, received], timeout: 3)
    }

    func testInvalidSurvivorRetainsDeletionEvidenceUntilRepair() throws {
        let graph = try payloadFixture(sql: "UPDATE ZMANAGEDENTITYPROPERTY SET ZOBJECT=x'000102';")
        let background = try XCTUnwrap(graph.newBackgroundContext())
        var detailIDs = Set<NSManagedObjectID>()
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-DELETION-WITH-INVALID-SURVIVOR"
            let facade = Graph(transactionContext: background, configuration: graph.configuration)
            let transient = Entity("Transient", graph: facade)
            transient.add(tags: "tag").add(to: "group")
            try background.save()
            detailIDs = Set(["tagSet", "groupSet"].flatMap { transient.node.objectIDs(forRelationshipNamed: $0) })
            transient.delete()
            try background.save()
        }
        XCTAssertEqual(detailIDs.count, 2)
        graph.watchReportSources = [.cloud]
        let warnings = Warnings()
        graph.eventDelegate = warnings
        let failed = expectation(description: "survivor blocks entire interval")
        warnings.onFailure = { _ in failed.fulfill() }
        let premature = expectation(description: "deletion evidence is not delivered early")
        premature.isInverted = true
        graph.watchReportCompletion = { report, _ in if report != nil { premature.fulfill() } }
        let delivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: graph.managedObjectContext)
        let tokens = GraphWatchDeliveryTokenStore(configuration: graph.configuration,
            storeURL: graph.runtimeStoreURL ?? graph.configuration.resolvedStoreURL)
        delivery.request()
        wait(for: [failed, premature], timeout: 0.5)
        XCTAssertNil(try tokens.load())

        let survivor = try XCTUnwrap(Search<Entity>(graph: graph).where(.type("Payload")).sync().first)
        survivor[dynamicMember: "payload"] = "repaired"
        graph.sync()
        let received = expectation(description: "survivor and deletions delivered together")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertEqual(Set(report.unmaterializedDeletions.map(\.objectID)), detailIDs)
            XCTAssertTrue(report.events.contains { if case .insertedEntity(let node) = $0 { return node.type == "Payload" }; return false })
            XCTAssertTrue(report.events.contains { if case .deletedEntity = $0 { return true }; return false })
            XCTAssertTrue(report.structuralValidationResults.allSatisfy(\.isValid))
            received.fulfill()
        }
        delivery.request()
        wait(for: [received], timeout: 3)
        XCTAssertNotNil(try tokens.load())
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
