//
//  PersistentHistoryTokenTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 09/09/25.
//

import XCTest
@testable import Graph

/// Questi test NON generano vere transazioni di Persistent History (serve CloudKit reale).
/// Validano invece:
/// - bootstrap senza token
/// - idempotenza dell'handler in assenza di transazioni
/// - comportamento con token corrotto (no crash, no token “magico”)
/// - wiring del filtro autore (sanity)

final class PersistentHistoryTokenTests: XCTestCase {

    // MARK: - Helpers

    /// Crea un `Graph` col nome richiesto (nuovo store per test), matching lo stile dei vostri test.
    private func makeGraph(named graphName: String) -> Graph {
        var config = GraphStoreConfiguration()
        config.name = graphName
        return Graph(configuration: config)
    }

    // MARK: - Tests

    func test_Bootstrap_NoToken_NoCrash_NoPost() {
        let g = makeGraph(named: "PH-Bootstrap-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists(), "Token should not exist at bootstrap")

        // Simula l’arrivo della notifica remota chiamando direttamente l’handler:
        // in assenza di transazioni di PH, non deve crashare né creare token.
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))

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
        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Handler is idempotent when there are no PH transactions")
    }

    func test_CorruptedToken_Fallback_NoCrash() {
        let g = makeGraph(named: "PH-Corruption-\(UUID().uuidString)")
        g.ph_debug_clearToken()
        XCTAssertFalse(g.ph_debug_lastTokenExists())

        // Corrompe il file token su disco e invoca l’handler:
        // il load fallisce ma non deve crashare, e senza transazioni valide
        // non deve apparire alcun token.
        g.ph_debug_corruptTokenOnDisk()
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))

        XCTAssertFalse(g.ph_debug_lastTokenExists(),
                       "Corrupted token should not resurrect into a valid token without PH transactions")
    }

    func test_FilterLocalWrites_Wiring_OK() {
        // Sanity check: l’handler deve poter essere chiamato con filtro autore attivo.
        // (il comportamento “no doppio scatto” lo validiamo in integrazione reale)
        let g = makeGraph(named: "PH-Filter-\(UUID().uuidString)")
        g.ph_debug_printAuthorAndContext()   // giusto per visibilità nei log
        g.handlePersistentStoreRemoteChange(Notification(name: .NSPersistentStoreRemoteChange))
        // Nessuna asserzione specifica: verifichiamo solo che non ci siano crash.
        XCTAssertTrue(true)
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
