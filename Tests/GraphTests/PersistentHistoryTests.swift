//
//  PersistentHistoryTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 20/09/25.
//


// MARK: - PersistentHistoryTests

#if canImport(XCTest)
import XCTest
@testable import Graph
import CoreData

final class PersistentHistoryTests: XCTestCase {
    func testSimulatedRemoteChangeTriggersMigration() throws {
        // 1. Create a fresh Graph with unique name
        var config = GraphStoreConfiguration()
        config.name = "TestGraph)"
        let graph = Graph(configuration: config)

        // 2. Insert a ManagedEntityProperty without appDataVersion
        let nbg = graph.newBackgroundContext()
        guard let bg = nbg else {
            XCTFail("Could not create a background context")
            return
        }
        var objectID: NSManagedObjectID!
        bg.performAndWait {
            // Mark this write as coming from a different author to simulate a *remote* change
            // so that Persistent History processing does not skip it as self-authored.
            bg.transactionAuthor = "REMOTE-TEST-AUTHOR"
            let obj = NSEntityDescription.insertNewObject(
                forEntityName: "ManagedEntityProperty",
                into: bg
            )
            obj.setValue("testProp", forKey: "name")
            try? bg.save()
            objectID = obj.objectID
        }

        // 3. Simulate remote change notification
        graph.processPersistentHistoryForRemoteChange()

        // 4. Wait a short time for async processing
        let exp = expectation(description: "wait for PH")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // 5. Reload object and check appDataVersion updated
        let refreshed = try graph.managedObjectContext?.existingObject(with: objectID)
        graph.managedObjectContext?.refreshAllObjects()
        let version = refreshed?.value(forKey: "appDataVersion") as? Int

        XCTAssertEqual(
            version,
            graph.configuration.requiredVersions.appData,
            "appDataVersion should be upgraded on remote change"
        )
    }
}
#endif
