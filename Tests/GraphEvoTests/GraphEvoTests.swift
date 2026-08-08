//
//  GraphEvoTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 04/09/25.
//


import XCTest
@testable import GraphEvo

final class GraphEvoTests: XCTestCase {

    /// Minimal smoke test for M2:
    /// - Ensures the SQLite filename is `GraphEvo_<name>.sqlite`
    /// - Ensures the viewContext is available
    /// - (If available) Persists and fetches a simple Entity
    func test_M2_Smoke_SaveFetch_FileNaming() throws {
        let name = "M2Smoke-\(UUID().uuidString)"

        // Optional: set CloudKit identifier at runtime (comment out if not configured)
        // Graph.cloudKitContainerIdentifier = "iCloud.com.yourdomain.yourapp"

        // 1) Init graph (local/AppGroup behavior preserved by existing initializers)
        var config = GraphStoreConfiguration()
        config.name = name
        let g = Graph(configuration: config)
        g.clear()
        

        // 2) Check file naming
        guard let storeURL = g.runtimeStoreURL else {
            XCTFail("No Store URL available")
            return
        }
        XCTAssertEqual(storeURL.lastPathComponent, "GraphEvo_\(name).sqlite", "Store file should be renamed to GraphEvo_<name>.sqlite")

        // 3) Context should be ready
        XCTAssertNotNil(g.managedObjectContext, "Managed object context should be initialized")

        // 4) Save / Fetch roundtrip (uses original Graph APIs if present)
        //    If your project uses a different API to persist entities, adjust this block accordingly.
        
            let e = Entity("note", graph: g)
            e[dynamicMember: "title"] = "Hello M2"

            // Persist (adjust if your Entity save API differs)
            g.sync()

            // Fetch back (adjust if your Search API differs)
            let results = Search<Entity>(graph: g).where(.type("note")).sync()
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
        var config = GraphStoreConfiguration()
        config.name = "StatusProbe_NoID"
        let g = Graph(configuration: config)
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
        var config = GraphStoreConfiguration()
        config.name = "StatusProbe_WithID"
        let g = Graph(configuration: config)
        let stub = CloudStatusDelegateStub(expectation: exp)
        g.cloudStatusDelegate = stub
        
        waitForExpectations(timeout: 4.0)
        
        XCTAssertFalse(stub.statuses.isEmpty, "Delegate should be called when identifier is set")
        XCTAssertEqual(
            g.configuration.cloudKitContainerIdentifier,
            "iCloud.com.example.dummy",
            "The runtime CloudKit identifier must be retained by the resolved configuration"
        )
        
        // Restore previous override
        Graph.cloudKitContainerIdentifier = old
    }
}
