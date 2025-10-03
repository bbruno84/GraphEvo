//
//  Graph+PersistentHistory.swift
//  GraphCK
//
//  Created by Valerio Buriani on 08/09/25.
//

import Foundation
import CoreData
import ObjectiveC.runtime

// MARK: - Token store su disco (Application Support o App Group opzionale)

private final class HistoryTokenStore {
    private let url: URL

    // MARK: - Local shadow backup (UserDefaults) per la *stessa installazione*
    private let backupDefaults = UserDefaults.standard

    private func backupKey(for storeUUID: String?) -> String {
        let suffix = storeUUID ?? "fallback"
        return "GraphCK.historyToken.backup.\(suffix)"
    }

    /// Carica il token dal backup in UserDefaults (stessa installazione)
    func loadBackup(storeUUID: String?) -> NSPersistentHistoryToken? {
        let key = backupKey(for: storeUUID)
        guard let data = backupDefaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    /// Salva il token anche nel backup (UserDefaults)
    func saveBackup(_ token: NSPersistentHistoryToken, storeUUID: String?) {
        let key = backupKey(for: storeUUID)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            backupDefaults.set(data, forKey: key)
        }
    }

    /// Pulisce il backup (UserDefaults)
    func clearBackup(storeUUID: String?) {
        backupDefaults.removeObject(forKey: backupKey(for: storeUUID))
    }

    init(appGroup: String? = nil) {
        if let group = appGroup,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            self.url = containerURL.appendingPathComponent("GraphCK.historyToken", isDirectory: false)
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                        ?? FileManager.default.temporaryDirectory
            self.url = base.appendingPathComponent("GraphCK.historyToken", isDirectory: false)
        }
    }

    func load() -> NSPersistentHistoryToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
        } catch { return nil }
    }

    func save(_ token: NSPersistentHistoryToken) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try data.write(to: url, options: [.atomic])
            // Mantieni anche un backup locale (fallback namespace)
            self.saveBackup(token, storeUUID: nil)
        } catch {
            // Silenzioso: non blocchiamo il flusso in caso di I/O error
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        // Pulisci anche il backup di fallback
        self.clearBackup(storeUUID: nil)
    }

    func bootstrapTokenToCurrentHead(using context: NSManagedObjectContext) {
        context.performAndWait {
            // Chiedi la history dal "beginning" senza filtrare: solo transazioni.
            let req = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            req.resultType = .transactionsOnly
            // ⚠️ Non impostare req.fetchRequest (niente sort/limit SQL su "timestamp")

            do {
                guard let result = try context.execute(req) as? NSPersistentHistoryResult else {
                    #if DEBUG
                    print("[PH] bootstrapTokenToCurrentHead: unexpected result type")
                    #endif
                    return
                }

                // Può essere NSNull se non ci sono transazioni
                guard let txs = result.result as? [NSPersistentHistoryTransaction], !txs.isEmpty else {
                    #if DEBUG
                    print("[PH] bootstrapTokenToCurrentHead: no transactions found → no token to save.")
                    #endif
                    return
                }

                // Ordina in memoria per timestamp (o semplicemente prendi la max per data)
                if let newest = txs.max(by: { lhs, rhs in lhs.timestamp < rhs.timestamp }) {
                    #if DEBUG
                    print("[PH] bootstrapTokenToCurrentHead: acquired token from most recent transaction, saving.")
                    #endif
                    self.save(newest.token)
                } else {
                    #if DEBUG
                    print("[PH] bootstrapTokenToCurrentHead: unable to determine newest transaction")
                    #endif
                }
            } catch {
                #if DEBUG
                print("[PH] bootstrapTokenToCurrentHead: error executing history request: \(error)")
                #endif
            }
        }
    }
    
#if DEBUG
    // DEBUG: sovrascrive il file token con dati non validi per simulare corruzione
    func debugCorruptOnDisk() {
        let junk = Data("not-a-token".utf8)
        try? junk.write(to: url, options: [.atomic])
        // Non serve aggiornare _ph_lastToken qui: l'intento è simulare un token corrotto su disco.
    }

    // DEBUG: verifica se il file token esiste su disco
    func debugTokenFileExists() -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }
#endif
}

// MARK: - Associated storage per Graph (no stored properties nelle extension)

private enum _GraphPHKeys {
    // Use stable addressable keys for objc associated objects
    static var lastTokenKey: UInt8 = 0
    static var tokenStoreKey: UInt8 = 0
    static var bootstrapFlagKey: UInt8 = 0
    static var coldStartFlagKey: UInt8 = 0
}

private extension Graph {
    var _ph_lastToken: NSPersistentHistoryToken? {
        get { objc_getAssociatedObject(self, &_GraphPHKeys.lastTokenKey) as? NSPersistentHistoryToken }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.lastTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var _ph_tokenStore: HistoryTokenStore {
        if let store = objc_getAssociatedObject(self, &_GraphPHKeys.tokenStoreKey) as? HistoryTokenStore {
            return store
        }
        // Se in futuro vuoi un App Group, passalo qui.
        let store = HistoryTokenStore(appGroup: nil)
        objc_setAssociatedObject(self, &_GraphPHKeys.tokenStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }

    /// If true, when no token is found (fresh install / cold start), we bootstrap the token to the current head
    /// instead of replaying the entire history. Default: false (so that history replay rebuilds local state and delegati fire).
    var _ph_bootstrapToHeadOnColdStart: Bool {
        get { (objc_getAssociatedObject(self, &_GraphPHKeys.bootstrapFlagKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.bootstrapFlagKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Flag di sessione: true alla prima esecuzione (app "fredda" subito dopo install/launch), false successivamente.
    var _ph_isColdStartSession: Bool {
        get { (objc_getAssociatedObject(self, &_GraphPHKeys.coldStartFlagKey) as? NSNumber)?.boolValue ?? true }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.coldStartFlagKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Prova ad ottenere lo store UUID corrente dal PSC
    func _ph_currentStoreUUID() -> String? {
        guard let psc = persistentContainer?.persistentStoreCoordinator else { return nil }
        for store in psc.persistentStores {
            let meta = psc.metadata(for: store)
            if let uuid = meta[NSStoreUUIDKey] as? String {
                return uuid
            }
        }
        return nil
    }

    /// Marca l'avvio e determina se è una cold-start session (solo per questa installazione).
    func _ph_markLaunchAndDetectColdStart() {
        let defaults = UserDefaults.standard
        let key = "GraphCK.hasLaunchedOnce"
        let hasLaunched = defaults.bool(forKey: key)
        _ph_isColdStartSession = !hasLaunched
        if !hasLaunched {
            defaults.set(true, forKey: key)
        }
    }

    // MARK: - Persistent History configuration (tunable)
    /// Skip local writes authored by this device to avoid double callbacks on the originator device.
    private var _ph_filterLocalWrites: Bool { true }
    /// The author used by local contexts when _ph_filterLocalWrites is enabled.
    private var _ph_appAuthor: String { GraphDeviceAuthor.current() }
}

// MARK: - Entry point: remote change → process history → post custom notification

@objc
internal extension Graph {
    /// Chiamato dall'observer registrato in Context.swift
    func handlePersistentStoreRemoteChange(_ notification: Notification) {
        // Lazy load dal disco alla primissima occorrenza
        if _ph_lastToken == nil {
            _ph_lastToken = _ph_tokenStore.load()
        }

        // Se il token è ancora nil, scegli la strategia corretta in base alla sessione
        if _ph_lastToken == nil {
            // Sessione calda → ripristina dal backup o bootstrap to head
            _ph_restoreFromBackupOrBootstrapIfWarmSession()
            // Se invece è cold start, l’helper non fa nulla e lasciamo il replay completo
        }

        // Procedi con l’elaborazione della history (userInfo + post notifica custom)
        processPersistentHistoryForRemoteChange()
    }
}

// MARK: - Launch-time bootstrap (called after container is ready)

@objc
public extension Graph {
    @objc
    func ph_prepareOnLaunchAfterContainerReady() {
        _ph_markLaunchAndDetectColdStart()
        // Load token from disk (if any)
        if _ph_lastToken == nil {
            _ph_lastToken = _ph_tokenStore.load()
        }
        // Warm session & token mancante → prova il backup locale (UserDefaults)
        if _ph_lastToken == nil, _ph_isColdStartSession == false {
            let storeUUID = _ph_currentStoreUUID()
            if let backup = _ph_tokenStore.loadBackup(storeUUID: storeUUID) {
                _ph_lastToken = backup
                #if DEBUG
                print("[PH] prepareOnLaunch: disk token missing, restored from UserDefaults backup (warm session)")
                #endif
            }
        }

        // If there is no token we purposefully avoid bootstrapping here.
        // The first remote notification will replay history from the beginning once,
        // emit delegate callbacks, and advance the token.
        if _ph_lastToken == nil {
            #if DEBUG
            print("[PH] prepareOnLaunch: token missing → will replay from beginning on first remote change (no bootstrap)")
            #endif
        }
    }
}

internal extension Graph {
    func processPersistentHistoryForRemoteChange() {
        
        guard let container = persistentContainer else {return}
        let psc = container.persistentStoreCoordinator
        guard !psc.persistentStores.isEmpty else {return}
        guard !psc.persistentStores.isEmpty else {return}

        let bg = container.newBackgroundContext()
        bg.transactionAuthor = GraphDeviceAuthor.current()
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        bg.perform { [weak self] in
            guard let self = self else {return }

            // Richiesta: tutte le transazioni dopo l’ultimo token noto
            let token: NSPersistentHistoryToken? = self._ph_lastToken
            let request: NSPersistentHistoryChangeRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)

            // Nota: niente filtro SQL su `storeID`.
            // Alcune configurazioni non espongono `storeID` nell'entità TRANSACTION → crash.
            // Se servirà filtrare per store in multi-store, farlo *dopo* il fetch in memoria.

            do {
                guard let result = try bg.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction],
                      !transactions.isEmpty else {return}


                // Raccogliamo gli ObjectID per tipo di change
                var insertedIDs: [NSManagedObjectID] = []
                var updatedIDs:  [NSManagedObjectID] = []
                var deletedIDs:  [NSManagedObjectID] = []

                for tx in transactions {
//                    #if DEBUG
//                    let a = tx.author ?? "nil"
//                    let cn = tx.contextName ?? "nil"
//                    print("[PH] tx: author=\(a) contextName=\(cn) changes=\(tx.changes?.count ?? 0)")
//                    #endif

                    // 🔒 Hardening filtro autore: evita doppio callback sull’originatore
                    if _ph_filterLocalWrites {
                        if let author = tx.author {
                            if author == _ph_appAuthor {
//                                #if DEBUG
//                                print("[PH] skip self-authored transaction (author=\(author))")
//                                #endif
                                continue
                            }
                        } else {
                            // author == nil → probabile salvataggio da un contesto senza transactionAuthor
                            // Questo può causare il doppio scatto su A dopo bootstrap del token.
                            #if DEBUG
                            print("[PH][warn] tx.author == nil (imposta context.transactionAuthor = \( _ph_appAuthor )) su TUTTI i contesti che salvano")
                            #endif
                        }
                    }

                    tx.changes?.forEach { change in
                        switch change.changeType {
                        case .insert: insertedIDs.append(change.changedObjectID)
                        case .update: updatedIDs.append(change.changedObjectID)
                        case .delete: deletedIDs.append(change.changedObjectID)
                        @unknown default: break
                        }
                    }
                }

                // Aggiorna e persisti il token
                if let last = transactions.last?.token {
                    self._ph_lastToken = last
                    self._ph_tokenStore.save(last)
                    // Mantieni in sync anche il backup (namespacizzato per store)
                    let storeUUID = self._ph_currentStoreUUID()
                    self._ph_tokenStore.saveBackup(last, storeUUID: storeUUID)
                    self._ph_isColdStartSession = false
                }

                // Se non c'è nulla, esci
                if insertedIDs.isEmpty, updatedIDs.isEmpty, deletedIDs.isEmpty { return }

                // Costruisci userInfo nel formato atteso dai Watch:
                // NSSet di NSManagedObjectID (i Watch sanno convertirli in NSManagedObject col moc)
                let userInfo: [AnyHashable: Any] = [
                    NSInsertedObjectsKey: NSSet(array: insertedIDs),
                    NSUpdatedObjectsKey:  NSSet(array: updatedIDs),
                    NSDeletedObjectsKey:  NSSet(array: deletedIDs)
                ]

                // Prima di postare la notifica, chiama GraphMigrationManager.handleRemoteEntityChanges
                GraphMigrationManager.handleRemoteEntityChanges(
                    configuration: self.configuration,
                    graph: self,
                    inserted: insertedIDs,
                    updated: updatedIDs
                )
                // Post sul main (i watcher sono tipicamente agganciati sul main runloop)
                DispatchQueue.main.async {
                    let targetMOC = self.managedObjectContext ?? container.viewContext
                    NotificationCenter.default.post(
                        name: .GraphCKSimulatedRemoteChange,
                        object: targetMOC,
                        userInfo: userInfo
                    )
                }
            } catch {
                // Expand error handling for persistent history token store mismatch (error code 134501)
                let nsError = error as NSError
                // 134501: "Unable to find stores referenced in History Token" (NSCocoaErrorDomain)
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == 134501 {
                    self._ph_lastToken = nil
                    self._ph_tokenStore.clear()
                    let storeUUID = self._ph_currentStoreUUID()
                    self._ph_tokenStore.clearBackup(storeUUID: storeUUID)
                    return
                }
                debugPrint("[PH][DEBUG] Error processing remote change: \(error)")
                }
                
            
        }
    }
}

private extension Graph {
    /// Se il token è mancante *in una sessione calda*, prova a ripristinarlo dal backup.
    /// Se non esiste un backup, fai bootstrap alla head per evitare replay e doppi callback.
    func _ph_restoreFromBackupOrBootstrapIfWarmSession() {
        // Se abbiamo già un token in memoria, nulla da fare.
        guard _ph_lastToken == nil else { return }

        // Se è davvero una cold start session, lasciamo il replay completo.
        guard _ph_isColdStartSession == false else {
//            #if DEBUG
//            print("[PH] cold start: history replay from beginning (forced, no bootstrap)")
//            #endif
            return
        }

        // 1) Prova prima il backup su UserDefaults (stessa installazione / warm session)
        let storeUUID = _ph_currentStoreUUID()
        if let backup = _ph_tokenStore.loadBackup(storeUUID: storeUUID) {
            _ph_lastToken = backup
            _ph_isColdStartSession = false   // ✅ segna esplicitamente “non più cold” perché abbiamo un token valido
            #if DEBUG
            print("[PH] warm start: token restored from UserDefaults backup")
            #endif
            return
        }

        // 2) Nessun backup disponibile → bootstrap alla head per evitare replay integrale
        if let container = persistentContainer {
            let bg = container.newBackgroundContext()
            bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            bg.transactionAuthor = GraphDeviceAuthor.current()

            _ph_tokenStore.bootstrapTokenToCurrentHead(using: bg)

            if let head = _ph_tokenStore.load() {
                _ph_lastToken = head
                _ph_isColdStartSession = false   // ✅ anche in questo caso non siamo più “cold”
                #if DEBUG
                print("[PH] warm start: no backup → bootstrapped token to current head")
                #endif
            } else {
                #if DEBUG
                print("[PH][warn] warm start: bootstrap to head failed (no token written)")
                #endif
            }
        }
    }
}

#if DEBUG
@objc
public extension Graph {
    /// Cancella token in memoria e su disco
    func ph_debug_clearToken() {
        _ph_lastToken = nil
        _ph_tokenStore.clear()
        // Pulisci anche il backup per lo store corrente
        //let storeUUID = _ph_currentStoreUUID()
        //_ph_tokenStore.clearBackup(storeUUID: storeUUID)
        print("[PH][DEBUG] Token cleared")
    }

    /// True se esiste un token in memoria o su disco
    func ph_debug_lastTokenExists() -> Bool {
        if _ph_lastToken != nil {
            print("[PH][DEBUG] lastTokenExists = true (memory)")
            return true
        }
        let exists = _ph_tokenStore.load() != nil
        print("[PH][DEBUG] lastTokenExists = \(exists) (disk)")
        return exists
    }

    /// Corrompe intenzionalmente il token su disco (per testare il recovery)
    func ph_debug_corruptTokenOnDisk() {
        _ph_tokenStore.debugCorruptOnDisk()
        print("[PH][DEBUG] Token file corrupted on disk")
    }

    /// Stampa autore configurato e nome del contesto attuale
    func ph_debug_printAuthorAndContext() {
        let author = _ph_appAuthor
        let ctxName = (managedObjectContext?.name) ?? "nil"
        print("[PH][DEBUG] author=\(author) viewContext.name=\(ctxName)")
    }

    /// Stampa stato sintetico del token (mem/disk)
    func ph_debug_printTokenStatus() {
        let mem = (_ph_lastToken != nil) ? "mem=YES" : "mem=NO"
        let disk = (_ph_tokenStore.load() != nil) ? "disk=YES" : "disk=NO"
        print("[PH][DEBUG] token: \(mem), \(disk)")
    }

    /// DEBUG: abilita/disabilita il bootstrap del token alla head su cold start
    @objc func ph_debug_setBootstrapOnColdStart(_ enabled: Bool) {
        _ph_bootstrapToHeadOnColdStart = enabled
        print("[PH][DEBUG] bootstrapToHeadOnColdStart = \(enabled)")
    }
}
#endif
