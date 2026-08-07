//
//  Graph+PersistentHistory.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 08/09/25.
//

import Foundation
import CoreData
import ObjectiveC.runtime

// MARK: - Token store su disco (Application Support o App Group opzionale)

private final class HistoryTokenStore {
    fileprivate enum LoadResult {
        case missing
        case loaded(NSPersistentHistoryToken)
        case invalid(Error)
    }

    private let url: URL
    private let storeKey: String
    private let backupKeyPrefix: String
    private let reportError: (Error) -> Void

    // MARK: - Local shadow backup (UserDefaults) per la *stessa installazione*
    private let backupDefaults: UserDefaults

    fileprivate init(
        storeURL: URL,
        storeUUID: String?,
        configuration: GraphStoreConfiguration,
        reportError: @escaping (Error) -> Void
    ) {
        let storeKey = Self.stableStoreKey(storeURL: storeURL, storeUUID: storeUUID)
        self.storeKey = storeKey
        self.reportError = reportError
        let baseURL: URL
        let defaults: UserDefaults

        if let group = configuration.appGroupIdentifier,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            baseURL = containerURL
                .appendingPathComponent("CosmicMind/Graph/PersistentHistory", isDirectory: true)
            defaults = UserDefaults(suiteName: group) ?? .standard
        } else {
            baseURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(".GraphEvo/PersistentHistory", isDirectory: true)
            defaults = .standard
        }

        self.url = baseURL.appendingPathComponent("history-\(storeKey).token", isDirectory: false)
        self.backupKeyPrefix = "GraphEvo.historyToken.backup.\(storeKey)"
        self.backupDefaults = defaults
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    fileprivate var tokenURL: URL { url }

    fileprivate func matches(storeURL: URL, storeUUID: String?) -> Bool {
        storeKey == Self.stableStoreKey(storeURL: storeURL, storeUUID: storeUUID)
    }

    fileprivate static func stableStoreKey(storeURL: URL, storeUUID: String?) -> String {
        let source = storeUUID ?? storeURL.standardizedFileURL.path
        // FNV-1a provides a short deterministic filename without exposing the
        // full path and without introducing a cryptography dependency.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func backupKey() -> String {
        backupKeyPrefix
    }

    /// Carica il token dal backup in UserDefaults (stessa installazione)
    func loadBackup() -> NSPersistentHistoryToken? {
        switch loadBackupResult() {
        case .loaded(let token): return token
        case .missing, .invalid: return nil
        }
    }

    fileprivate func loadBackupResult() -> LoadResult {
        guard let data = backupDefaults.data(forKey: backupKey()) else { return .missing }
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
                return .invalid(NSError(domain: "GraphEvo.PersistentHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Persistent History backup contained no token."]))
            }
            return .loaded(token)
        } catch {
            return .invalid(error)
        }
    }

    /// Salva il token anche nel backup (UserDefaults)
    func saveBackup(_ token: NSPersistentHistoryToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            backupDefaults.set(data, forKey: backupKey())
        }
    }

    /// Pulisce il backup (UserDefaults)
    func clearBackup() {
        backupDefaults.removeObject(forKey: backupKey())
    }

    func load() -> NSPersistentHistoryToken? {
        switch loadResult() {
        case .loaded(let token): return token
        case .missing, .invalid: return nil
        }
    }

    fileprivate func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
                return .invalid(NSError(domain: "GraphEvo.PersistentHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Persistent History file contained no token."]))
            }
            return .loaded(token)
        } catch {
            return .invalid(error)
        }
    }

    func save(_ token: NSPersistentHistoryToken) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try data.write(to: url, options: [.atomic])
            // Mantieni anche un backup locale (fallback namespace)
            self.saveBackup(token)
        } catch {
            reportError(error)
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            reportError(error)
        }
        // Pulisci anche il backup di fallback
        self.clearBackup()
    }

    func bootstrapTokenToCurrentHead(using context: NSManagedObjectContext) {
        context.performAndWait {
            // Chiedi la history dal "beginning" senza filtrare: solo transazioni.
            let req = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            req.resultType = .transactionsOnly
            // ⚠️ Non impostare req.fetchRequest (niente sort/limit SQL su "timestamp")

            do {
                guard let result = try context.execute(req) as? NSPersistentHistoryResult else {return}

                // Può essere NSNull se non ci sono transazioni
                guard let txs = result.result as? [NSPersistentHistoryTransaction], !txs.isEmpty else {return}

                // Ordina in memoria per timestamp (o semplicemente prendi la max per data)
                if let newest = txs.max(by: { lhs, rhs in lhs.timestamp < rhs.timestamp }) {
                    self.save(newest.token)
                }
            } catch {
            self.reportError(error)
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
    static var coordinatorKey: UInt8 = 0
}

private extension Graph {
    var _ph_lastToken: NSPersistentHistoryToken? {
        get { objc_getAssociatedObject(self, &_GraphPHKeys.lastTokenKey) as? NSPersistentHistoryToken }
        set { objc_setAssociatedObject(self, &_GraphPHKeys.lastTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var _ph_tokenStore: HistoryTokenStore {
        let storeURL = runtimeStoreURL ?? configuration.resolvedStoreURL
        let storeUUID = _ph_currentStoreUUID()
        if let existing = objc_getAssociatedObject(self, &_GraphPHKeys.tokenStoreKey) as? HistoryTokenStore {
            if existing.matches(storeURL: storeURL, storeUUID: storeUUID) {
                return existing
            }
            // The Graph instance was rebound to a different store identity.
            // Never carry the in-memory token across that boundary.
            _ph_lastToken = nil
        }
        let store = HistoryTokenStore(
            storeURL: storeURL,
            storeUUID: storeUUID,
            configuration: configuration,
            reportError: { [weak self] error in self?.emit(.warning(.persistentHistoryTokenStore(underlying: error))) }
        )
        objc_setAssociatedObject(self, &_GraphPHKeys.tokenStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }

    var _ph_remoteChangeCoordinator: RemoteChangeCoordinator {
        if let coordinator = objc_getAssociatedObject(self, &_GraphPHKeys.coordinatorKey) as? RemoteChangeCoordinator {
            return coordinator
        }
        let coordinator = RemoteChangeCoordinator(graph: self)
        objc_setAssociatedObject(self, &_GraphPHKeys.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return coordinator
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
        let key = "GraphEvo.hasLaunchedOnce"
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
        _ph_loadPersistedTokenIfNeeded()

        // Se il token è ancora nil, scegli la strategia corretta in base alla sessione
        if _ph_lastToken == nil {
            // Sessione calda → ripristina dal backup o bootstrap to head
            _ph_restoreFromBackupOrBootstrapIfWarmSession()
            // Se invece è cold start, l’helper non fa nulla e lasciamo il replay completo
        }

        // The coordinator owns ordering, coalescing and delivery.
        _ph_remoteChangeCoordinator.enqueue()
    }
}

// MARK: - Launch-time bootstrap (called after container is ready)

@objc
public extension Graph {
    @objc
    func ph_prepareOnLaunchAfterContainerReady() {
        _ph_markLaunchAndDetectColdStart()
        // Load token from disk (if any)
        _ph_loadPersistedTokenIfNeeded()
        // Warm session & token mancante → prova il backup locale (UserDefaults)
        if _ph_lastToken == nil, _ph_isColdStartSession == false {
            _ph_restoreFromBackupOrBootstrapIfWarmSession()
        }

        // If there is no token we purposefully avoid bootstrapping here.
        // The first remote notification will replay history from the beginning once,
        // emit delegate callbacks, and advance the token.
        if _ph_lastToken == nil {
        }
    }
}

internal extension Graph {
    func processPersistentHistoryForRemoteChange() {
        _ph_remoteChangeCoordinator.enqueue()
    }

    /// Processes one history snapshot. The completion is called after the
    /// merged notification has been delivered to existing Watch observers.
    func processPersistentHistoryBatch(completion: @escaping (Bool) -> Void) {
        // A remote purge invalidates the local object graph and history token.
        // The application is responsible for reopening the store afterwards;
        // do not publish the purge's remote notification as normal data.
        guard !isCloudPurgeInProgress else { completion(false); return }
        guard let container = persistentContainer else { completion(false); return }
        let psc = container.persistentStoreCoordinator
        guard !psc.persistentStores.isEmpty else { completion(false); return }

        let bg = container.newBackgroundContext()
        bg.transactionAuthor = GraphDeviceAuthor.current()
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        bg.perform { [weak self] in
            guard let self = self else { completion(false); return }

            // Richiesta: tutte le transazioni dopo l’ultimo token noto
            let token: NSPersistentHistoryToken? = self._ph_lastToken
            let request: NSPersistentHistoryChangeRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)

            // Nota: niente filtro SQL su `storeID`.
            // Alcune configurazioni non espongono `storeID` nell'entità TRANSACTION → crash.
            // Se servirà filtrare per store in multi-store, farlo *dopo* il fetch in memoria.

            do {
                guard let result = try bg.execute(request) as? NSPersistentHistoryResult,
                      let transactions = result.result as? [NSPersistentHistoryTransaction],
                      !transactions.isEmpty else {
                    completion(false)
                    return
                }

                let orderedTransactions = transactions.sorted { $0.timestamp < $1.timestamp }


                // Raccogliamo gli ObjectID per tipo di change
                var insertedIDs: [NSManagedObjectID] = []
                var updatedIDs:  [NSManagedObjectID] = []
                var deletedIDs:  [NSManagedObjectID] = []

                for tx in orderedTransactions {
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
                            self.emit(.warning(.persistentHistoryMissingTransactionAuthor))
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

                // Se non c'è nulla, esci
                if insertedIDs.isEmpty, updatedIDs.isEmpty, deletedIDs.isEmpty {
                    self.persistPersistentHistoryToken(orderedTransactions.last?.token)
                    completion(true)
                    return
                }

                // Costruisci userInfo nel formato atteso dai Watch:
                // NSSet di NSManagedObjectID (i Watch sanno convertirli in NSManagedObject col moc)
                let userInfo: [AnyHashable: Any] = [
                    NSInsertedObjectsKey: NSSet(array: insertedIDs),
                    NSUpdatedObjectsKey:  NSSet(array: updatedIDs),
                    NSDeletedObjectsKey:  NSSet(array: deletedIDs)
                ]

                // Core Data's merge API expects object-ID keys, while the
                // legacy Watch API expects the historical object keys. Keep
                // those payloads separate so neither contract is changed.
                let mergeUserInfo: [AnyHashable: Any] = [
                    NSInsertedObjectIDsKey: NSSet(array: insertedIDs),
                    NSUpdatedObjectIDsKey:  NSSet(array: updatedIDs),
                    NSDeletedObjectIDsKey:  NSSet(array: deletedIDs)
                ]

                guard !self.isCloudPurgeInProgress else {
                    completion(false)
                    return
                }

                // Prima di postare la notifica, chiama GraphMigrationManager.handleRemoteEntityChanges
                GraphMigrationManager.handleRemoteEntityChanges(
                    configuration: self.configuration,
                    graph: self,
                    inserted: insertedIDs,
                    updated: updatedIDs
                )
                // Merge synchronously on the context's queue before posting to
                // Watch observers. This is the consistency barrier missing from
                // the previous implementation.
                let targetMOC = self.managedObjectContext ?? container.viewContext
                targetMOC.performAndWait {
                    let mergedNotification = Notification(
                        name: .GraphEvoSimulatedRemoteChange,
                        object: targetMOC,
                        userInfo: mergeUserInfo
                    )
                    targetMOC.mergeChanges(fromContextDidSave: mergedNotification)
                }

                // Persist the token only after the observed context has been
                // merged successfully. This prevents losing a batch when the
                // merge path fails before delivery.
                self.persistPersistentHistoryToken(orderedTransactions.last?.token)

                // Post on main (watchers are generally connected to UI-owned
                // contexts and existing clients expect main-thread delivery).
                DispatchQueue.main.async {
                    guard !self.isCloudPurgeInProgress else {
                        completion(false)
                        return
                    }
                    var deliveredUserInfo = userInfo
                    deliveredUserInfo[GraphEvoRemoteChangeAlreadyMergedKey] = true
                    NotificationCenter.default.post(
                        name: .GraphEvoSimulatedRemoteChange,
                        object: targetMOC,
                        userInfo: deliveredUserInfo
                    )
                    completion(true)
                }
            } catch {
                let nsError = error as NSError
                // 134501: token references a store that no longer exists.
                if self._ph_isPersistentHistoryError(134501, in: nsError) {
                    self._ph_recoverPersistentHistoryToken(
                        reason: .storeUnavailable,
                        underlying: error,
                        using: nil
                    )
                    completion(false)
                    return
                }
                // 134301: the token is older than the retained history window.
                if self._ph_isPersistentHistoryError(134301, in: nsError) {
                    self._ph_recoverPersistentHistoryToken(
                        reason: .expiredToken,
                        underlying: error,
                        using: nil
                    )
                    completion(false)
                    return
                }
                debugPrint("[PH][DEBUG] Error processing remote change: \(error)")
                self.emit(.error(.persistentHistory(underlying: error)))
                completion(false)
                }
        }
    }
}

private extension Graph {
    func _ph_loadPersistedTokenIfNeeded() {
        let tokenStore = _ph_tokenStore
        guard _ph_lastToken == nil else { return }
        switch tokenStore.loadResult() {
        case .missing:
            return
        case .loaded(let token):
            _ph_lastToken = token
        case .invalid(let error):
            _ph_recoverPersistentHistoryToken(
                reason: .corruptedToken,
                underlying: error,
                using: nil
            )
        }
    }

    /// Invalidates every local representation of the token before selecting
    /// a new recovery point. Bootstrapping the current history head is safe
    /// after a rebuilt store and prevents the coordinator from retrying the
    /// invalid token on every remote-change notification.
    func _ph_recoverPersistentHistoryToken(
        reason: GraphPersistentHistoryRecoveryReason,
        underlying: Error?,
        using context: NSManagedObjectContext?
    ) {
        _ph_lastToken = nil
        _ph_tokenStore.clear()
        emit(.warning(.persistentHistoryRecovery(reason: reason, underlying: underlying)))

        let recoveryContext: NSManagedObjectContext
        if let context {
            recoveryContext = context
        } else if let container = persistentContainer {
            recoveryContext = container.newBackgroundContext()
        } else {
            return
        }

        _ph_tokenStore.bootstrapTokenToCurrentHead(using: recoveryContext)
        _ph_lastToken = _ph_tokenStore.load()
        _ph_isColdStartSession = false
    }

    func _ph_isPersistentHistoryError(_ code: Int, in error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == code { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return _ph_isPersistentHistoryError(code, in: underlying)
        }
        return false
    }

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
        switch _ph_tokenStore.loadBackupResult() {
        case .loaded(let backup):
            _ph_lastToken = backup
            _ph_isColdStartSession = false
            return
        case .invalid(let error):
            _ph_recoverPersistentHistoryToken(
                reason: .corruptedToken,
                underlying: error,
                using: nil
            )
            return
        case .missing:
            break
        }

        // 2) Nessun backup disponibile → bootstrap alla head per evitare replay integrale
        if let container = persistentContainer {
            let bg = container.newBackgroundContext()
            bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            bg.transactionAuthor = GraphDeviceAuthor.current()

            _ph_tokenStore.bootstrapTokenToCurrentHead(using: bg)

            if let head = _ph_tokenStore.load() {
                _ph_lastToken = head
                _ph_isColdStartSession = false
            }
        }
    }

    func persistPersistentHistoryToken(_ token: NSPersistentHistoryToken?) {
        guard let token else { return }
        _ph_lastToken = token
        _ph_tokenStore.save(token)
        _ph_tokenStore.saveBackup(token)
        _ph_isColdStartSession = false
    }
}

#if DEBUG
@objc
public extension Graph {
    /// Cancella token in memoria e su disco
    func ph_debug_clearToken() {
        _ph_lastToken = nil
        _ph_tokenStore.clear()
    }

    /// True se esiste un token in memoria o su disco
    func ph_debug_lastTokenExists() -> Bool {
        if _ph_lastToken != nil {
            return true
        }
        return _ph_tokenStore.load() != nil
    }

    /// Corrompe intenzionalmente il token su disco (per testare il recovery)
    func ph_debug_corruptTokenOnDisk() {
        _ph_tokenStore.debugCorruptOnDisk()
    }

    /// Returns the per-store token URL for diagnostics and tests.
    func ph_debug_tokenStorageURL() -> URL {
        _ph_tokenStore.tokenURL
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
    }

    /// DEBUG/test seam for exercising token-error classification without
    /// manufacturing a private Core Data token or contacting CloudKit.
    @objc func ph_debug_recoverFromPersistentHistoryError(_ error: NSError) -> Bool {
        if _ph_isPersistentHistoryError(134301, in: error) {
            _ph_recoverPersistentHistoryToken(reason: .expiredToken, underlying: error, using: nil)
            return true
        }
        if _ph_isPersistentHistoryError(134501, in: error) {
            _ph_recoverPersistentHistoryToken(reason: .storeUnavailable, underlying: error, using: nil)
            return true
        }
        return false
    }
}
#endif
