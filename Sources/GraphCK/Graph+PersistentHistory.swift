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
        } catch {
            // Silenzioso: non blocchiamo il flusso in caso di I/O error
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    func bootstrapFromNow(using context: NSManagedObjectContext) {
        let nilToken: NSPersistentHistoryToken? = nil
        let request: NSPersistentHistoryChangeRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: nilToken)
        request.fetchRequest = NSPersistentHistoryTransaction.fetchRequest!
        request.fetchRequest?.predicate = NSPredicate(format: "timestamp > %@", Date() as NSDate)
        if let result = try? context.execute(request) as? NSPersistentHistoryResult,
           let transactions = result.result as? [NSPersistentHistoryTransaction],
           let last = transactions.last?.token {
            save(last)
        }
    }
}

// MARK: - Associated storage per Graph (no stored properties nelle extension)

private enum _GraphPHKeys {
    // Use stable addressable keys for objc associated objects
    static var lastTokenKey: UInt8 = 0
    static var tokenStoreKey: UInt8 = 0
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

    // MARK: - Persistent History configuration (tunable)
    /// Set to true to skip local writes (requires setting viewContext.transactionAuthor = APP_AUTHOR)
    private var _ph_filterLocalWrites: Bool { false }
    /// The author used by local contexts when _ph_filterLocalWrites is enabled.
    private var _ph_appAuthor: String { "app" }
}

// MARK: - Entry point: remote change → process history → post custom notification

@objc
internal extension Graph {
    /// Chiamato dall'observer registrato in Context.swift
    func handlePersistentStoreRemoteChange(_ notification: Notification) {
        #if DEBUG
        let keys = Array((notification.userInfo ?? [:]).keys)
        print("[PH] remote change notification received: keys=\(keys)")
        #endif
        // Lazy load del token salvato su disco (solo la prima volta)
        if _ph_lastToken == nil {
            _ph_lastToken = _ph_tokenStore.load()
        }
        processPersistentHistoryForRemoteChange()
    }
}

private extension Graph {
    func processPersistentHistoryForRemoteChange() {
        guard let container = persistentContainer else { return }
        let psc = container.persistentStoreCoordinator
        guard !psc.persistentStores.isEmpty else { return }

        let bg = container.newBackgroundContext()
        bg.perform { [weak self] in
            guard let self = self else { return }

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
                    return
                }

                // Raccogliamo gli ObjectID per tipo di change
                var insertedIDs: [NSManagedObjectID] = []
                var updatedIDs:  [NSManagedObjectID] = []
                var deletedIDs:  [NSManagedObjectID] = []

                for tx in transactions {
                    #if DEBUG
                    let a = tx.author ?? "nil"
                    let cn = tx.contextName ?? "nil"
                    print("[PH] tx: author=\(a) contextName=\(cn) changes=\(tx.changes?.count ?? 0)")
                    #endif

                    // Opzionale: salta le scritture locali se configurato
                    if _ph_filterLocalWrites, tx.author == _ph_appAuthor {
                        continue
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
                // Silenzioso per robustezza nei build di test
            }
        }
    }
}
