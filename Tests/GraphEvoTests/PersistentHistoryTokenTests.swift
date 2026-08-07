//
//  PersistentHistoryTokenTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 09/09/25.
//

import XCTest
@testable import GraphEvo

/// Questi test NON generano vere transazioni di Persistent History (serve CloudKit reale).
/// Validano invece:
/// - bootstrap senza token
/// - idempotenza dell'handler in assenza di transazioni
/// - comportamento con token corrotto (no crash, no token “magico”)
/// - wiring del filtro autore (sanity)

final class PersistentHistoryTokenTests: XCTestCase {

    private final class EventCollector: GraphEventDelegate {
        var events: [GraphEvent] = []

        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            events.append(event)
        }
    }

    // MARK: - Helpers

    /// Crea un `Graph` col nome richiesto (nuovo store per test), matching lo stile dei vostri test.
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

        // Simula l’arrivo della notifica remota chiamando direttamente l’handler:
        // in assenza di transazioni di PH, non deve crashare né creare token.
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        waitForHistoryProcessingToSettle()

        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Without PH transactions, token must remain absent")
    }

    func test_Idempotency_ReentrantHandle_NoTokenCreated() {
        let g = makeGraph(named: "PH-Idempotency-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists())

        // Più invocazioni consecutive: nessun token deve apparire senza transazioni PH reali.
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

        // Corrompe il file token su disco e invoca l’handler:
        // il load fallisce ma non deve crashare, e senza transazioni valide
        // non deve apparire alcun token.
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

    // MARK: - (Facoltativo) Segnaposto per integrazione reale con CloudKit
    // Abilitare solo quando si eseguono test strumentali su device:
    //
    // func test_AdvanceToken_AfterRealRemoteSync() {
    //     let g = makeGraph(named: "PH-Advance-\(UUID().uuidString)")
    //     g.ph_debug_clearToken()
    //     XCTAssertFalse(g.ph_debug_lastTokenExists())
    //
    //     // 1) Da un altro device: eseguire un inserimento che arrivi su questo store.
    //     // 2) Attendere che il container pubblichi .NSPersistentStoreRemoteChange (l’handler viene chiamato).
    //     // 3) Verificare che il token ora esista:
    //     // XCTAssertTrue(g.ph_debug_lastTokenExists())
    // }
}
