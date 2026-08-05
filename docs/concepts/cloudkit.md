# CloudKit

GraphEvo può usare `NSPersistentCloudKitContainer` per sincronizzare lo store
privato CloudKit. La sincronizzazione è opzionale: senza un container identifier
il graph resta locale.

## Configurazione

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
configuration.cloudKitContainerIdentifier = "iCloud.com.example.app"

let graph = Graph(configuration: configuration)
```

È possibile usare anche l’override runtime:

```swift
Graph.cloudKitContainerIdentifier = "iCloud.com.example.app"
```

Come fallback, GraphEvo legge `GraphCloudKitContainerIdentifier` da Info.plist.
L’ordine di precedenza è configurazione esplicita, override runtime e Info.plist.

## Cosa succede se CloudKit non è disponibile

GraphEvo può aprire un normale store locale come fallback. L’app riceve un
`GraphWarning.cloudStoreFallback` e uno stato `GraphPersistenceMode` coerente.
Questo consente di mantenere l’app utilizzabile, ma significa che i dati creati
durante il fallback non sono necessariamente sincronizzati.

Per osservare gli stati usare `GraphEventDelegate` e, se serve il contratto
legacy, `GraphCloudStatusDelegate`.

## Purge remoto dello store

Per gli strumenti amministrativi l’app può chiedere a GraphEvo di eliminare
la zona Core Data dal database CloudKit privato:

```swift
graph.purgeCloudStore { result in
    switch result {
    case .success:
        // L'app deve riaprire o ricreare lo store locale e
        // azzerare token e persistent history locali.
        break
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

L’API opera solo su un `NSPersistentCloudKitContainer` realmente caricato con
uno store configurato per CloudKit. Non cancella file SQLite, non ricrea lo
store e non esegue il purge durante i test o su un fallback locale. Il reset
locale e la gestione dei token/history restano responsabilità dell’app.

## Completamento degli import CloudKit

L’app può osservare gli import completati tramite `GraphCloudSyncDelegate`:

```swift
final class SyncDelegate: GraphCloudSyncDelegate {
    func graph(_ graph: Graph, didCompleteCloudImport event: GraphCloudImportEvent) {
        guard event.succeeded else {
            // Gestire event.error senza considerare l'import riuscito.
            return
        }
        if event.isInitialImport {
            // Eventuale operazione post-import dell'app.
        }
    }
}

let syncDelegate = SyncDelegate()
graph.cloudSyncDelegate = syncDelegate
```

`NSPersistentCloudKitContainer` non espone un evento nativo distinto per il
primo sync. GraphEvo identifica il primo import combinando lo stato iniziale
della replica locale (store vuoto e senza oggetti locali) con il primo evento
`.import` completato per quello store. Sono considerati solo eventi terminati;
`.setup` ed `.export` non generano callback. Il callback è consegnato sulla
coda principale, viene deduplicato per `event.identifier` e non garantisce che
non arrivino ulteriori import successivi. L’app può usare questo segnale per
avviare operazioni post-import, come una deduplicazione esplicitamente
controllata, ma GraphEvo non esegue alcuna deduplicazione automatica.

## Requisiti applicativi

L’app che integra GraphEvo deve configurare in Xcode:

- capability iCloud/CloudKit;
- container identifier valido;
- ambiente CloudKit corretto;
- permessi e modello compatibili con i dati.

GraphEvo non può sostituire la configurazione delle capability dell’app.

## Cambiamenti remoti

I cambiamenti provenienti da CloudKit passano attraverso Persistent History,
vengono fusi nel contesto osservato e poi inoltrati ai watcher con
`GraphSource.cloud`. Vedere [Persistent History](../migrations/persistent-history.md).

In produzione mantenere callback idempotenti e verificare il comportamento con
più dispositivi: notifiche locali e remote possono avere tempi diversi.
