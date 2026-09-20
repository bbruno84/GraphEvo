import CoreData
import XCTest
@testable import GraphEvo

final class GraphWatchReportTests: XCTestCase {
    private final class ReportCollector {
        var reports: [GraphWatchReport] = []
        var onReport: ((GraphWatchReport) -> Void)?

        func receive(_ report: GraphWatchReport) {
            reports.append(report)
            onReport?(report)
        }
    }

    private func makeGraph() -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "WatchReport-\(UUID().uuidString)"
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    private func install(_ collector: ReportCollector, on graph: Graph) {
        graph.watchReportCompletion = { report, _ in
            if let report { collector.receive(report) }
        }
    }

    func testCompletionDeliversReportAndNilErrorOnLocalBatch() {
        let graph = makeGraph()
        let received = expectation(description: "completion report")
        graph.watchReportSources = [.local]
        graph.watchReportCompletion = { report, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(report)
            XCTAssertNil(error)
            if let report {
                XCTAssertEqual(report.source, .local)
                XCTAssertFalse(report.events.isEmpty)
            }
            received.fulfill()
        }

        _ = Entity("Completion", graph: graph)
        graph.sync()
        wait(for: [received], timeout: 2)
    }

    func testLocalSaveProducesOneGraphLevelReportWithAllNodeFamilies() {
        let graph = makeGraph()
        let delegate = ReportCollector()
        let received = expectation(description: "local report")
        delegate.onReport = { report in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(report.source, .local)
            received.fulfill()
        }
        install(delegate, on: graph)

        let subject = Entity("Person", graph: graph)
        subject[dynamicMember: "name"] = "Ada"
        subject.add(tags: "active").add(to: "people")
        let object = Entity("Person", graph: graph)
        let relationship = subject.is(relationship: "knows")
        relationship.object = object
        relationship[dynamicMember: "weight"] = 1
        relationship.add(tags: "social").add(to: "links")
        let action = subject.will(action: "message").add(objects: object)
        action[dynamicMember: "body"] = "Hello"
        action.add(tags: "outgoing").add(to: "activity")

        graph.sync()
        wait(for: [received], timeout: 2)

        XCTAssertEqual(delegate.reports.count, 1)
        let events = delegate.reports[0].events
        XCTAssertTrue(events.contains { if case .insertedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .insertedRelationship = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .insertedAction = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityTag(_, "active") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedEntityToGroup(_, "people") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipTag(_, "social") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedRelationshipToGroup(_, "links") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionProperty(_, "body", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionTag(_, "outgoing") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .addedActionToGroup(_, "activity") = $0 { return true }; return false })
    }

    func testLocalReportIncludesRelationshipWhenNewEntityLinksToExistingEntity() {
        let graph = makeGraph()
        let existing = Entity("Existing", graph: graph)
        graph.sync()

        let collector = ReportCollector()
        let received = expectation(description: "local relationship report")
        collector.onReport = { report in
            guard report.events.contains(where: {
                if case .insertedRelationship = $0 { return true }
                return false
            }) else { return }
            received.fulfill()
        }
        install(collector, on: graph)

        let inserted = Entity("Inserted", graph: graph)
        _ = inserted.is(relationship: "relatesTo").of(existing)
        graph.sync()
        wait(for: [received], timeout: 2)

        let events = try! XCTUnwrap(collector.reports.last?.events)
        XCTAssertTrue(events.contains { if case .insertedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .insertedRelationship = $0 { return true }; return false })
    }

    func testLocalReportsAreDeliveredForTwoSeparateSyncs() {
        let graph = makeGraph()
        let existing = Entity("Existing", graph: graph)
        graph.sync()

        let collector = ReportCollector()
        let firstReport = expectation(description: "first local report")
        let secondReport = expectation(description: "second local report")
        collector.onReport = { report in
            if report.events.contains(where: { if case .insertedEntity = $0 { return true }; return false }) {
                firstReport.fulfill()
            }
            if report.events.contains(where: { if case .insertedRelationship = $0 { return true }; return false }) {
                secondReport.fulfill()
            }
        }
        install(collector, on: graph)

        let inserted = Entity("Inserted", graph: graph)
        graph.sync()
        _ = inserted.is(relationship: "relatesTo").of(existing)
        graph.sync()

        wait(for: [firstReport, secondReport], timeout: 2)
        XCTAssertGreaterThanOrEqual(collector.reports.count, 2)
    }

    func testLocalReportsIncludeExplicitRelationshipCreatedAfterEntitySync() {
        let graph = makeGraph()
        let existing = Entity("Existing", graph: graph)
        let collector = ReportCollector()
        let firstReport = expectation(description: "entity report")
        let secondReport = expectation(description: "relationship report")
        collector.onReport = { report in
            if report.events.contains(where: { if case .insertedEntity = $0 { return true }; return false }) {
                firstReport.fulfill()
            }
            if report.events.contains(where: { if case .insertedRelationship = $0 { return true }; return false }) {
                secondReport.fulfill()
            }
        }
        install(collector, on: graph)

        let inserted = Entity("Inserted", graph: graph)
        graph.sync()
        let relationship = Relationship("relatesTo", graph: graph)
        relationship.subject = inserted
        relationship.object = existing
        graph.sync()

        wait(for: [firstReport, secondReport], timeout: 2)
        XCTAssertGreaterThanOrEqual(collector.reports.count, 2)
    }

    func testLocalDeletionKeepsGraphObjectAndIsDeliveredWithTheSaveBatch() {
        let graph = makeGraph()
        let entity = Entity("Temporary", graph: graph)
        graph.sync()

        let delegate = ReportCollector()
        let received = expectation(description: "delete report")
        delegate.onReport = { _ in received.fulfill() }
        install(delegate, on: graph)

        entity.delete()
        XCTAssertTrue(delegate.reports.isEmpty, "The batch must wait for the save boundary")
        graph.sync()
        wait(for: [received], timeout: 2)

        guard case .deletedEntity(let deleted)? = delegate.reports.first?.events.first(where: {
            if case .deletedEntity = $0 { return true }
            return false
        }) else {
            return XCTFail("Missing deleted Entity wrapper")
        }
        XCTAssertTrue(deleted === entity || deleted.managedNode === entity.managedNode)
    }

    func testCloudOnlySelectionAndLegacyWatcherRemainParallel() {
        let graph = makeGraph()
        let entity = Entity("RemoteNote", graph: graph)
        graph.sync()

        let reportDelegate = ReportCollector()
        let reportReceived = expectation(description: "cloud report")
        reportDelegate.onReport = { report in
            XCTAssertEqual(report.source, .cloud)
            reportReceived.fulfill()
        }
        graph.watchReportSources = [.cloud]
        install(reportDelegate, on: graph)

        final class LegacyDelegate: NSObject, GraphEntityDelegate {
            let expectation: XCTestExpectation
            init(_ expectation: XCTestExpectation) { self.expectation = expectation }
            func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
                guard source == .cloud else { return }
                expectation.fulfill()
            }
        }
        let legacyReceived = expectation(description: "legacy cloud callback")
        let legacyDelegate = LegacyDelegate(legacyReceived)
        let watcher = Watch<Entity>(graph: graph).where(.type("RemoteNote"))
        watcher.delegate = legacyDelegate

        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [NSInsertedObjectsKey: NSSet(object: entity.managedNode)]
        )

        wait(for: [reportReceived, legacyReceived], timeout: 2)
        XCTAssertEqual(reportDelegate.reports.count, 1)
        XCTAssertEqual(reportDelegate.reports.first?.events.count, 1)
        withExtendedLifetime(watcher) {}
        withExtendedLifetime(legacyDelegate) {}
    }

    func testEmptyAndUnselectedSourcesDoNotProduceReports() {
        let graph = makeGraph()
        let delegate = ReportCollector()
        graph.watchReportSources = [.cloud]
        install(delegate, on: graph)

        _ = Entity("LocalOnly", graph: graph)
        graph.sync()
        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [:]
        )

        XCTAssertTrue(delegate.reports.isEmpty)
    }

    func testDeterministicOrderingDoesNotDependOnInputSetOrder() throws {
        let graph = makeGraph()
        let first = Entity("B", graph: graph)
        let second = Entity("A", graph: graph)
        graph.sync()

        let firstEnvelope = try XCTUnwrap(GraphWatchEventMaterializer.materialize(
            object: first.managedNode,
            operation: .insert,
            source: .cloud,
            transactionIndex: 2,
            changeIndex: 0
        ))
        let secondEnvelope = try XCTUnwrap(GraphWatchEventMaterializer.materialize(
            object: second.managedNode,
            operation: .insert,
            source: .cloud,
            transactionIndex: 1,
            changeIndex: 0
        ))

        let ordered = [firstEnvelope, secondEnvelope].sorted { $0.isOrdered(before: $1) }
        XCTAssertTrue(ordered[0].owner === second.managedNode)
        XCTAssertTrue(ordered[1].owner === first.managedNode)
    }

    func testUpdatesAndRemovalsCoverEveryNodeFamily() {
        let graph = makeGraph()
        let subject = Entity("Person", graph: graph)
        let object = Entity("Person", graph: graph)
        subject[dynamicMember: "name"] = "Before"
        subject.add(tags: "entity-tag").add(to: "entity-group")
        let relationship = subject.is(relationship: "knows")
        relationship.object = object
        relationship[dynamicMember: "weight"] = 1
        relationship.add(tags: "relationship-tag").add(to: "relationship-group")
        let action = subject.will(action: "message").add(objects: object)
        action[dynamicMember: "body"] = "Before"
        action.add(tags: "action-tag").add(to: "action-group")
        graph.sync()

        let delegate = ReportCollector()
        let updateReport = expectation(description: "update report")
        let removalReport = expectation(description: "removal report")
        delegate.onReport = { report in
            if delegate.reports.count == 1 { updateReport.fulfill() }
            if delegate.reports.count == 2 { removalReport.fulfill() }
        }
        install(delegate, on: graph)

        subject[dynamicMember: "name"] = "After"
        relationship[dynamicMember: "weight"] = 2
        relationship.object = subject
        action[dynamicMember: "body"] = "After"
        graph.sync()

        subject[dynamicMember: "name"] = nil
        subject.remove(tags: "entity-tag").remove(from: "entity-group")
        relationship[dynamicMember: "weight"] = nil
        relationship.remove(tags: "relationship-tag").remove(from: "relationship-group")
        action[dynamicMember: "body"] = nil
        action.remove(tags: "action-tag").remove(from: "action-group")
        graph.sync()

        wait(for: [updateReport, removalReport], timeout: 2)
        let updates = delegate.reports[0].events
        XCTAssertTrue(updates.contains { if case .updatedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedRelationship = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(updates.contains { if case .updatedActionProperty(_, "body", _) = $0 { return true }; return false })

        let removals = delegate.reports[1].events
        XCTAssertTrue(removals.contains { if case .removedEntityProperty(_, "name", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedEntityTag(_, "entity-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedEntityFromGroup(_, "entity-group") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipProperty(_, "weight", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipTag(_, "relationship-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedRelationshipFromGroup(_, "relationship-group") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionProperty(_, "body", _) = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionTag(_, "action-tag") = $0 { return true }; return false })
        XCTAssertTrue(removals.contains { if case .removedActionFromGroup(_, "action-group") = $0 { return true }; return false })
    }

    func testDeletingEveryNodeFamilyProducesTypedDeletionEvents() {
        let graph = makeGraph()
        let first = Entity("Person", graph: graph)
        let second = Entity("Person", graph: graph)
        let relationship = first.is(relationship: "knows")
        relationship.object = second
        let action = first.will(action: "message").add(objects: second)
        graph.sync()

        let delegate = ReportCollector()
        let received = expectation(description: "typed deletions")
        delegate.onReport = { _ in received.fulfill() }
        install(delegate, on: graph)

        relationship.delete()
        action.delete()
        first.delete()
        graph.sync()
        wait(for: [received], timeout: 2)

        let events = delegate.reports[0].events
        XCTAssertTrue(events.contains { if case .deletedEntity = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .deletedRelationship = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .deletedAction = $0 { return true }; return false })
    }

    func testMaterializationFailureIsReportedAndOtherEventsContinue() {
        final class EventDelegate: GraphEventDelegate {
            var failures: [GraphFailure] = []
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                if case .error(let failure) = event { failures.append(failure) }
            }
        }

        let graph = makeGraph()
        let valid = Entity("Valid", graph: graph)
        graph.sync()
        let invalid = NSEntityDescription.insertNewObject(
            forEntityName: "ManagedEntityProperty",
            into: graph.managedObjectContext
        )
        invalid.setValue("orphan", forKey: "name")
        invalid.setValue("value", forKey: "object")

        let reports = ReportCollector()
        let reportReceived = expectation(description: "partial report")
        reports.onReport = { _ in reportReceived.fulfill() }
        let events = EventDelegate()
        install(reports, on: graph)
        graph.eventDelegate = events

        NotificationCenter.default.post(
            name: .GraphEvoSimulatedRemoteChange,
            object: graph.managedObjectContext,
            userInfo: [NSInsertedObjectsKey: NSSet(array: [invalid, valid.managedNode])]
        )
        wait(for: [reportReceived], timeout: 2)

        XCTAssertEqual(reports.reports.first?.events.count, 1)
        XCTAssertTrue(events.failures.contains {
            if case .watchEventMaterialization(source: .cloud, underlying: _) = $0 { return true }
            return false
        })
        graph.managedObjectContext.rollback()
    }

    func testPersistentHistoryTokenIsPersistedBeforeCloudReportDelivery() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        let delegate = ReportCollector()
        let received = expectation(description: "persistent history report")
        delegate.onReport = { report in
            XCTAssertEqual(report.source, .cloud)
            XCTAssertTrue(graph.ph_debug_lastTokenExists())
            received.fulfill()
        }
        graph.watchReportSources = [.cloud]
        install(delegate, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-REPORT-TEST"
            _ = ManagedEntity("Remote", managedObjectContext: background)
            try! background.save()
        }

        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [received], timeout: 3)
        XCTAssertEqual(delegate.reports.count, 1)
    }

    func testPersistentHistoryDeliversTwoConsecutiveCloudBatchesExactlyOnce() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]

        let collector = ReportCollector()
        let firstReceived = expectation(description: "first persistent history report")
        let secondReceived = expectation(description: "second persistent history report")
        collector.onReport = { report in
            switch collector.reports.count {
            case 1: firstReceived.fulfill()
            case 2: secondReceived.fulfill()
            default: XCTFail("Unexpected duplicate cloud report")
            }
        }
        install(collector, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-REPORT-FIRST"
            _ = ManagedEntity("FirstRemoteBatch", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [firstReceived], timeout: 3)

        try background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-REPORT-SECOND"
            _ = ManagedEntity("SecondRemoteBatch", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [secondReceived], timeout: 3)

        XCTAssertEqual(collector.reports.count, 2)
        XCTAssertTrue(collector.reports[0].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "FirstRemoteBatch" }
            return false
        })
        XCTAssertTrue(collector.reports[1].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "SecondRemoteBatch" }
            return false
        })
        XCTAssertFalse(collector.reports[1].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "FirstRemoteBatch" }
            return false
        })
    }

    func testCloudDeliveryCursorSurvivesLocalOnlyHistoryBetweenRemoteBatches() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]

        let collector = ReportCollector()
        let firstReceived = expectation(description: "first cloud report")
        let secondReceived = expectation(description: "cloud report after local-only history")
        collector.onReport = { _ in
            switch collector.reports.count {
            case 1: firstReceived.fulfill()
            case 2: secondReceived.fulfill()
            default: XCTFail("Unexpected duplicate cloud report")
            }
        }
        install(collector, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-BEFORE-LOCAL"
            _ = ManagedEntity("BeforeLocalHistory", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [firstReceived], timeout: 3)

        _ = Entity("LocalOnlyHistory", graph: graph)
        graph.sync()
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))

        try background.performAndWait {
            background.transactionAuthor = "REMOTE-WATCH-AFTER-LOCAL"
            _ = ManagedEntity("AfterLocalHistory", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [secondReceived], timeout: 3)

        XCTAssertEqual(collector.reports.count, 2)
        XCTAssertTrue(collector.reports[1].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "AfterLocalHistory" }
            return false
        })
        XCTAssertFalse(collector.reports[1].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "LocalOnlyHistory" }
            return false
        })
    }

    func testSuccessfulIncrementalImportDrainsPendingHistoryWithoutRemoteChangeWakeup() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        graph.configureCloudSyncTrackingForTesting(
            storeIdentifier: "incremental-import-store",
            initialImportPending: false
        )
        let importIdentifier = UUID()

        let received = expectation(description: "cloud report driven by completed import")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertEqual(report.source, .cloud)
            XCTAssertTrue(report.events.contains {
                if case .insertedEntity(let entity) = $0 { return entity.type == "ImportedWithoutWakeup" }
                return false
            })
            received.fulfill()
        }

        let background = try XCTUnwrap(graph.newBackgroundContext())
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "incremental-import-store",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-IMPORT-WITHOUT-WAKEUP"
            _ = ManagedEntity("ImportedWithoutWakeup", managedObjectContext: background)
            try background.save()
        }

        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "incremental-import-store",
            type: .import,
            succeeded: true
        )

        wait(for: [received], timeout: 1)
    }

    func testFailedIncrementalImportDrainsCommittedPartialHistory() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        graph.configureCloudSyncTrackingForTesting(
            storeIdentifier: "failed-incremental-import-store",
            initialImportPending: false
        )
        let importIdentifier = UUID()
        let received = expectation(description: "partial cloud report from failed import")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.events.contains {
                if case .insertedEntity(let entity) = $0 { return entity.type == "PartiallyImported" }
                return false
            })
            received.fulfill()
        }

        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "failed-incremental-import-store",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-FAILED-IMPORT-PARTIAL-HISTORY"
            _ = ManagedEntity("PartiallyImported", managedObjectContext: background)
            try background.save()
        }
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "failed-incremental-import-store",
            type: .import,
            succeeded: false,
            error: NSError(domain: "GraphWatchReportTests", code: 1)
        )

        wait(for: [received], timeout: 1)
    }

    func testCompletedImportWithNoPendingHistoryDoesNotProduceReport() {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        graph.configureCloudSyncTrackingForTesting(
            storeIdentifier: "empty-incremental-import-store",
            initialImportPending: false
        )
        let unexpected = expectation(description: "no cloud report for empty import")
        unexpected.isInverted = true
        graph.watchReportCompletion = { _, _ in unexpected.fulfill() }
        let importIdentifier = UUID()

        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "empty-incremental-import-store",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "empty-incremental-import-store",
            type: .import,
            succeeded: true
        )

        wait(for: [unexpected], timeout: 0.25)
    }

    func testImportCompletionAfterRemoteWakeupDoesNotRedeliverConsumedHistory() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        graph.configureCloudSyncTrackingForTesting(
            storeIdentifier: "already-delivered-import-store",
            initialImportPending: false
        )
        let collector = ReportCollector()
        let received = expectation(description: "report from remote-change wakeup")
        collector.onReport = { _ in received.fulfill() }
        install(collector, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-ALREADY-DELIVERED"
            _ = ManagedEntity("AlreadyDelivered", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [received], timeout: 3)

        let duplicate = expectation(description: "no duplicate after import completion")
        duplicate.isInverted = true
        collector.onReport = { _ in duplicate.fulfill() }
        let importIdentifier = UUID()
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "already-delivered-import-store",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "already-delivered-import-store",
            type: .import,
            succeeded: true
        )

        wait(for: [duplicate], timeout: 0.25)
        XCTAssertEqual(collector.reports.count, 1)
    }

    func testNewCloudDeliveryCoordinatorResumesFromPersistedCursor() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        let firstReceived = expectation(description: "first report before coordinator recreation")
        graph.watchReportCompletion = { report, _ in
            guard report != nil else { return }
            firstReceived.fulfill()
        }

        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-BEFORE-DELIVERY-RECREATION"
            _ = ManagedEntity("BeforeDeliveryRecreation", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [firstReceived], timeout: 3)

        let recreated = GraphWatchBatchDeliveryCoordinator(
            graph: graph,
            context: try XCTUnwrap(graph.managedObjectContext)
        )
        let replay = expectation(description: "persisted cursor prevents replay")
        replay.isInverted = true
        graph.watchReportCompletion = { report, _ in
            if report != nil { replay.fulfill() }
        }
        recreated.request()
        wait(for: [replay], timeout: 0.25)

        let secondReceived = expectation(description: "new report after coordinator recreation")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.events.contains {
                if case .insertedEntity(let entity) = $0 { return entity.type == "AfterDeliveryRecreation" }
                return false
            })
            XCTAssertFalse(report.events.contains {
                if case .insertedEntity(let entity) = $0 { return entity.type == "BeforeDeliveryRecreation" }
                return false
            })
            secondReceived.fulfill()
        }
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-AFTER-DELIVERY-RECREATION"
            _ = ManagedEntity("AfterDeliveryRecreation", managedObjectContext: background)
            try background.save()
        }
        recreated.request()
        wait(for: [secondReceived], timeout: 3)
    }

    func testCloudBatchMaterializationFailureKeepsCursorForRetry() throws {
        final class WarningCollector: GraphEventDelegate {
            var onMaterializationFailure: (() -> Void)?
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                guard case .warning(.watchReportMaterializationFailed(
                    source: .cloud,
                    failedEvents: _,
                    details: _
                )) = event else { return }
                onMaterializationFailure?()
            }
        }

        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        let warnings = WarningCollector()
        graph.eventDelegate = warnings
        let warningReceived = expectation(description: "retryable materialization warning")
        warningReceived.assertForOverFulfill = false
        warnings.onMaterializationFailure = { warningReceived.fulfill() }
        let prematureReport = expectation(description: "no partial report")
        prematureReport.isInverted = true
        graph.watchReportCompletion = { report, _ in
            if report != nil { prematureReport.fulfill() }
        }

        let background = try XCTUnwrap(graph.newBackgroundContext())
        var ownerID: NSManagedObjectID!
        var orphanID: NSManagedObjectID!
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-INVALID-WATCH-BATCH"
            let owner = ManagedEntity("RecoveredOwner", managedObjectContext: background)
            _ = ManagedEntity("ValidAlongsideInvalid", managedObjectContext: background)
            let orphan = NSEntityDescription.insertNewObject(
                forEntityName: "ManagedEntityProperty",
                into: background
            )
            orphan.setValue("recoverable", forKey: "name")
            orphan.setValue("value", forKey: "object")
            try background.save()
            ownerID = owner.objectID
            orphanID = orphan.objectID
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [warningReceived, prematureReport], timeout: 1)

        let retryReceived = expectation(description: "complete report after materialization retry")
        graph.watchReportCompletion = { report, error in
            XCTAssertNil(error)
            guard let report else { return }
            XCTAssertTrue(report.events.contains {
                if case .insertedEntity(let entity) = $0 { return entity.type == "ValidAlongsideInvalid" }
                return false
            })
            XCTAssertTrue(report.events.contains {
                if case .addedEntityProperty(let entity, "recoverable", _) = $0 {
                    return entity.type == "RecoveredOwner"
                }
                return false
            })
            retryReceived.fulfill()
        }
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-REPAIRED-WATCH-BATCH"
            let owner = try background.existingObject(with: ownerID)
            let orphan = try background.existingObject(with: orphanID)
            orphan.setValue(owner, forKey: "node")
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [retryReceived], timeout: 3)
    }

    func testRemoteWakeupAndImportCompletionCoalesceIntoOneReport() throws {
        let graph = makeGraph()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]
        graph.configureCloudSyncTrackingForTesting(
            storeIdentifier: "coalesced-import-store",
            initialImportPending: false
        )
        let collector = ReportCollector()
        let received = expectation(description: "one coalesced cloud report")
        collector.onReport = { _ in received.fulfill() }
        install(collector, on: graph)

        let importIdentifier = UUID()
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "coalesced-import-store",
            type: .import,
            endDate: nil,
            succeeded: false
        )
        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-COALESCED-IMPORT"
            _ = ManagedEntity("CoalescedImport", managedObjectContext: background)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        graph.receiveCloudKitEventForTesting(
            identifier: importIdentifier,
            storeIdentifier: "coalesced-import-store",
            type: .import,
            succeeded: true
        )
        wait(for: [received], timeout: 3)

        let duplicate = expectation(description: "no second report from overlapping wakeups")
        duplicate.isInverted = true
        collector.onReport = { _ in duplicate.fulfill() }
        wait(for: [duplicate], timeout: 0.25)
        XCTAssertEqual(collector.reports.count, 1)
        XCTAssertTrue(collector.reports[0].events.contains {
            if case .insertedEntity(let entity) = $0 { return entity.type == "CoalescedImport" }
            return false
        })
    }

    func testPersistentHistoryMaterializesRemotePropertyUpdateAndEntityDeletion() throws {
        final class WarningCollector: GraphEventDelegate {
            var warnings: [GraphWarning] = []
            func graph(_ graph: Graph, didReceive event: GraphEvent) {
                if case .warning(let warning) = event { warnings.append(warning) }
            }
        }

        let graph = makeGraph()
        let entity = Entity("RemoteMutable", graph: graph)
        entity[dynamicMember: "name"] = "Before"
        graph.sync()
        graph.ph_debug_clearToken()
        graph.watchReportSources = [.cloud]

        let collector = ReportCollector()
        let warnings = WarningCollector()
        graph.eventDelegate = warnings
        let updateReceived = expectation(description: "remote property update report")
        let deletionReceived = expectation(description: "remote entity deletion report")
        collector.onReport = { report in
            if report.events.contains(where: {
                if case .updatedEntityProperty(_, "name", let value) = $0 {
                    return value as? String == "After"
                }
                return false
            }) {
                updateReceived.fulfill()
            }
            if report.events.contains(where: {
                if case .deletedEntity = $0 { return true }
                return false
            }) {
                deletionReceived.fulfill()
            }
        }
        install(collector, on: graph)

        let background = try XCTUnwrap(graph.newBackgroundContext())
        try background.performAndWait {
            background.transactionAuthor = "REMOTE-PROPERTY-UPDATE"
            let request = NSFetchRequest<ManagedEntityProperty>(entityName: "ManagedEntityProperty")
            request.predicate = NSPredicate(format: "name == %@", "name")
            let property = try XCTUnwrap(background.fetch(request).first)
            property.object = "After"
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [updateReceived], timeout: 3)

        try background.performAndWait {
            background.transactionAuthor = "REMOTE-ENTITY-DELETION"
            let request = NSFetchRequest<ManagedEntity>(entityName: "ManagedEntity")
            request.predicate = NSPredicate(format: "type == %@", "RemoteMutable")
            let remoteEntity = try XCTUnwrap(background.fetch(request).first)
            background.delete(remoteEntity)
            try background.save()
        }
        graph.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        wait(for: [deletionReceived], timeout: 3)
        XCTAssertGreaterThanOrEqual(
            collector.reports.count,
            2,
            "The remote deletion must produce a report distinct from the preceding update"
        )
        XCTAssertFalse(warnings.warnings.contains {
            if case .watchReportMaterializationFailed(source: .cloud, failedEvents: _, details: _) = $0 {
                return true
            }
            return false
        }, warnings.warnings.map(\.localizedDescription).joined(separator: "\n"))
    }

    func testGraphsSharingAContextReceiveOneReportPerInstance() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "SharedWatchReport-\(UUID().uuidString)"
        let first = Graph(configuration: configuration, migrationEnabled: false)
        let second = Graph(configuration: configuration, migrationEnabled: false)
        XCTAssertTrue(first.managedObjectContext === second.managedObjectContext)

        let firstDelegate = ReportCollector()
        let secondDelegate = ReportCollector()
        let firstReceived = expectation(description: "first graph report")
        let secondReceived = expectation(description: "second graph report")
        firstDelegate.onReport = { report in
            XCTAssertTrue(report.graph === first)
            firstReceived.fulfill()
        }
        secondDelegate.onReport = { report in
            XCTAssertTrue(report.graph === second)
            secondReceived.fulfill()
        }
        install(firstDelegate, on: first)
        install(secondDelegate, on: second)

        _ = Entity("Shared", graph: first)
        first.sync()
        wait(for: [firstReceived, secondReceived], timeout: 2)

        XCTAssertEqual(firstDelegate.reports.count, 1)
        XCTAssertEqual(secondDelegate.reports.count, 1)
    }
}
