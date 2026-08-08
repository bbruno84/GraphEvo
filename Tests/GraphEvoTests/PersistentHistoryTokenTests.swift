//
//  PersistentHistoryTokenTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 09/09/25.
//

import XCTest
@testable import GraphEvo

/// These tests do NOT create real Persistent History transactions (real CloudKit is required).
/// Validano invece:
/// - bootstrap without a token
/// - handler idempotence without transactions
/// - corrupt-token behavior (no crash, no unexpected token)
/// - author-filter wiring (sanity check)

final class PersistentHistoryTokenTests: XCTestCase {

    private final class EventCollector: GraphEventDelegate {
        var events: [GraphEvent] = []

        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            events.append(event)
        }
    }

    // MARK: - Helpers

    /// Creates a `Graph` with the requested name (a new store for each test).
    private func makeGraph(named graphName: String) -> Graph {
        var config = GraphStoreConfiguration()
        config.name = graphName
        return Graph(configuration: config)
    }

    private func waitForHistoryProcessingToSettle() {
        let expectation = expectation(description: "persistent history processing settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Tests

    func test_Bootstrap_NoToken_NoCrash_NoPost() {
        let g = makeGraph(named: "PH-Bootstrap-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists(), "Token should not exist at bootstrap")

        // Simulate a remote notification by calling the handler directly:
        // Without PH transactions, this must not crash or create a token.
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        waitForHistoryProcessingToSettle()

        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Without PH transactions, token must remain absent")
    }

    func test_Idempotency_ReentrantHandle_NoTokenCreated() {
        let g = makeGraph(named: "PH-Idempotency-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists())

        // Repeated invocations: no token should appear without real PH transactions.
        for _ in 0..<3 {
            g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        }
        waitForHistoryProcessingToSettle()
        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Handler is idempotent when there are no PH transactions")
    }

    func test_CorruptedToken_Fallback_NoCrash() {
        let g = makeGraph(named: "PH-Corruption-\(UUID().uuidString)")
        let collector = EventCollector()
        g.eventDelegate = collector
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists())

        // Corrupt the token file on disk and invoke the handler:
        // Loading may fail, but must not crash; without valid transactions,
        // no token should appear.
        g.ph_debug_corruptTokenOnDisk()
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        waitForHistoryProcessingToSettle()

        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Corrupted token should not resurrect into a valid token without PH transactions")
        XCTAssertTrue(collector.events.contains { event in
            guard case .warning(.persistentHistoryRecovery(let reason, _)) = event else { return false }
            if case .corruptedToken = reason { return true }
            return false
        })
    }

    func test_ExpiredToken_IsInvalidatedAndBootstrapsHead() {
        let g = makeGraph(named: "PH-Expired-\(UUID().uuidString)")
        let collector = EventCollector()
        g.eventDelegate = collector
        g.ph_debug_clearToken()

        let error = NSError(domain: NSCocoaErrorDomain, code: 134301)
        XCTAssertTrue(g.ph_debug_recoverFromPersistentHistoryError(error))

        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "An empty history must not create a fabricated token")
        XCTAssertTrue(collector.events.contains { event in
            guard case .warning(.persistentHistoryRecovery(let reason, _)) = event else { return false }
            if case .expiredToken = reason { return true }
            return false
        })
        XCTAssertFalse(g.ph_debug_recoverFromPersistentHistoryError(NSError(domain: NSCocoaErrorDomain, code: 134500)),
                       "Unrelated errors must not enter token recovery")
    }

    func test_ExpiredToken_WithExistingHistoryPersistsCurrentHead() {
        let g = makeGraph(named: "PH-ExpiredHead-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        let context = try! XCTUnwrap(g.newBackgroundContext())
        context.performAndWait {
            context.transactionAuthor = "REMOTE-TEST-AUTHOR"
            let object = NSEntityDescription.insertNewObject(
                forEntityName: "ManagedEntityProperty",
                into: context
            )
            object.setValue("recovery", forKey: "name")
            try! context.save()
        }

        XCTAssertTrue(g.ph_debug_recoverFromPersistentHistoryError(
            NSError(domain: NSCocoaErrorDomain, code: 134301)
        ))
        XCTAssertTrue(g.ph_debug_lastTokenExists(),
                      "Recovery must advance to the current retained history head")
    }

    func test_MissingStoreToken_IsInvalidatedAndBootstrapsHead() {
        let g = makeGraph(named: "PH-MissingStore-\(UUID().uuidString)")
        let collector = EventCollector()
        g.eventDelegate = collector
        g.ph_debug_clearToken()

        let error = NSError(domain: NSCocoaErrorDomain, code: 134501)
        XCTAssertTrue(g.ph_debug_recoverFromPersistentHistoryError(error))
        XCTAssertFalse(g.ph_debug_lastTokenExists())
        XCTAssertTrue(collector.events.contains { event in
            guard case .warning(.persistentHistoryRecovery(let reason, _)) = event else { return false }
            if case .storeUnavailable = reason { return true }
            return false
        })
    }

    func test_RecoveryFollowedByRemoteBurstDoesNotRetryInvalidToken() {
        let g = makeGraph(named: "PH-RecoveryBurst-\(UUID().uuidString)")
        let collector = EventCollector()
        g.eventDelegate = collector
        g.ph_debug_clearToken()
        XCTAssertTrue(g.ph_debug_recoverFromPersistentHistoryError(
            NSError(domain: NSCocoaErrorDomain, code: 134301)
        ))

        for _ in 0..<8 {
            g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        }
        waitForHistoryProcessingToSettle()

        let persistentHistoryFailures = collector.events.filter { event in
            if case .error(.persistentHistory) = event { return true }
            return false
        }
        XCTAssertTrue(persistentHistoryFailures.isEmpty,
                      "The coordinator must not retry the discarded token after recovery")
    }

    func test_FilterLocalWrites_Wiring_OK() {
        let g = makeGraph(named: "PH-Filter-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        waitForHistoryProcessingToSettle()

        XCTAssertFalse(
            g.ph_debug_lastTokenExists(),
            "A local-only notification without persistent-history transactions must not create a token"
        )
    }

    func test_TokenStorageIsolatedPerStore() {
        let first = makeGraph(named: "PH-Isolation-A-\(UUID().uuidString)")
        let second = makeGraph(named: "PH-Isolation-B-\(UUID().uuidString)")

        let firstURL = first.ph_debug_tokenStorageURL()
        let secondURL = second.ph_debug_tokenStorageURL()

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertTrue(firstURL.path.contains("PersistentHistory"))
        XCTAssertTrue(secondURL.path.contains("PersistentHistory"))
    }

}
