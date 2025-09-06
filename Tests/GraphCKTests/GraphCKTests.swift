//
//  GraphCKTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 04/09/25.
//


import XCTest
@testable import GraphCK

final class GraphCKTests: XCTestCase {

    /// Minimal smoke test for M2:
    /// - Ensures the SQLite filename is `GraphCK_<name>.sqlite`
    /// - Ensures the viewContext is available
    /// - (If available) Persists and fetches a simple Entity
    func test_M2_Smoke_SaveFetch_FileNaming() throws {
        let name = "M2Smoke"

        // Optional: set CloudKit identifier at runtime (comment out if not configured)
        // Graph.cloudKitContainerIdentifier = "iCloud.com.yourdomain.yourapp"

        // 1) Init graph (local/AppGroup behavior preserved by existing initializers)
        let g = Graph(name: name)

        // 2) Check file naming
        let storeURL = g.locationPublic
        XCTAssertEqual(storeURL.lastPathComponent, "GraphCK_\(name).sqlite", "Store file should be renamed to GraphCK_<name>.sqlite")

        // 3) Context should be ready
        XCTAssertNotNil(g.managedObjectContext, "Managed object context should be initialized by NSPersistentCloudKitContainer")

        // 4) Save / Fetch roundtrip (uses original Graph APIs if present)
        //    If your project uses a different API to persist entities, adjust this block accordingly.
        
            let e = Entity("note")
            e[dynamicMember: "title"] = "Hello M2"

            // Persist (adjust if your Entity save API differs)
            g.sync()

            // Fetch back (adjust if your Search API differs)
            //let results = Search<Entity>(types: ["note"]).sync()
            let results = Search<Entity>().where(.type("note")).sync()
            debugPrint("Results: \(results.count)")
            let titles = results.compactMap { $0[dynamicMember: "title"] as? String }
            XCTAssertTrue(titles.contains("Hello M2"), "Expected to find the saved entity by title")
        
    }

    // MARK: - Cloud status / identifier stubs
    
    private final class CloudStatusDelegateStub: GraphCloudStatusDelegate {
        let exp: XCTestExpectation
        var statuses: [GraphCloudStatus] = []
        
        init(expectation: XCTestExpectation) {
            self.exp = expectation
        }
        
        func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus) {
            statuses.append(status)
            exp.fulfill()
        }
    }
    
    func test_CloudStatus_NoIdentifier_ReportsUnavailable() {
        // Preserve and clear any existing runtime override
        let old = Graph.cloudKitContainerIdentifier
        Graph.cloudKitContainerIdentifier = nil
        
        let exp = self.expectation(description: "cloud status callback without identifier")
        let g = Graph(name: "StatusProbe_NoID")
        let stub = CloudStatusDelegateStub(expectation: exp)
        g.cloudStatusDelegate = stub
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertFalse(stub.statuses.isEmpty, "Delegate should be called even without identifier")
        XCTAssertEqual(stub.statuses.last, .unavailable, "Without identifier, status must be unavailable")
        
        // Restore previous override
        Graph.cloudKitContainerIdentifier = old
    }
    
    func test_CloudStatus_WithIdentifier_ReportsCallback() {
        // Use a dummy identifier; on simulator/no iCloud we expect .unavailable,
        // on properly configured env it may be .available. We only assert we got a callback.
        let old = Graph.cloudKitContainerIdentifier
        Graph.cloudKitContainerIdentifier = "iCloud.com.example.dummy"
        
        let exp = self.expectation(description: "cloud status callback with identifier")
        let g = Graph(name: "StatusProbe_WithID")
        let stub = CloudStatusDelegateStub(expectation: exp)
        g.cloudStatusDelegate = stub
        
        waitForExpectations(timeout: 4.0)
        
        XCTAssertFalse(stub.statuses.isEmpty, "Delegate should be called when identifier is set")
        // Typically .unavailable on simulator/no account; allow either for portability.
        XCTAssertTrue(stub.statuses.last == .available || stub.statuses.last == .unavailable,
                      "Expected a valid status callback")
        
        // Restore previous override
        Graph.cloudKitContainerIdentifier = old
    }
}
