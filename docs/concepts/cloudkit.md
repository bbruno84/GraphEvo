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
