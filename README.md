# GraphEvo

GraphEvo è una libreria Swift indipendente, evoluta dalla libreria
[CosmicMind/Graph](https://github.com/CosmicMind/Graph), che offre un modello a
grafo basato su Core Data con supporto alla persistenza locale e alla
sincronizzazione tramite CloudKit.

La libreria permette di modellare entità, relazioni e azioni, cercare i dati con
predicati leggibili e reagire ai cambiamenti attraverso watcher e notifiche.

## 📚 Documentazione

- [Reference completa delle API pubbliche](docs/api/public-api.md)
- [Istruzioni operative per agenti IA](AGENTS.md)
- [Indice della documentazione](docs/README.md)
- [Guida introduttiva](docs/guides/getting-started.md)
- [Modello a grafo](docs/concepts/graph-model.md)
- [Persistenza](docs/concepts/persistence.md)
- [CloudKit](docs/concepts/cloudkit.md)
- [Migrazioni](docs/migrations/overview.md)

---

## ✨ Funzionalità principali

- Modello a grafo basato su Core Data con `Entity`, `Relationship` e `Action`
- Supporto a `NSPersistentCloudKitContainer` e fallback locale
- Store SQLite compatibile con i percorsi esistenti `GraphEvo_<name>.sqlite`
- La configurazione a directory usa un percorso canonico indipendente dal backend; i vecchi percorsi `Local/...` e `Cloud/...` vengono riutilizzati automaticamente
- `Graph(storeURL:)` accetta sia una directory sia un file SQLite esistente, mantenendo invariato il percorso del file esplicito
- GraphEvo non esegue migrazioni automatiche tra modelli incompatibili: l’app deve migrare il proprio store e poi riaprirlo sul percorso originale
- Codifica sicura di valori eterogenei tramite `ValueTransformer`
- Opzioni abilitate: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- Delegate `GraphCloudStatusDelegate` per notificare disponibilità iCloud (fallback locale se non disponibile)
- Watcher e notifiche locali/remoto tramite **Persistent History Tracking**
- Configurazione CloudKit tramite override runtime o fallback Info.plist
- La precedenza CloudKit è: configurazione esplicita, override runtime, quindi `Info.plist`

---

## 📦 Requisiti

- iOS 16+
- Xcode 15.4+
- Swift Package Manager

Il modulo pubblico è `GraphEvo`:

```swift
import GraphEvo

let graph = Graph(configuration: configuration)
```

Il nome `Graph` resta quello della classe principale e dei concetti di dominio
dell'API.

Il prefisso `GraphEvo_` e i relativi percorsi e chiavi interni persistenti sono
quelli canonici della nuova release. Gli store creati dalle versioni di test
precedenti con prefisso `GraphCK_` non vengono migrati automaticamente.

GraphEvo non impone flag `-Xfrontend` o impostazioni di strict concurrency al
progetto che la integra. Questa scelta mantiene il prodotto consumabile anche
da target che usano CocoaPods o altre dipendenze SwiftPM con impostazioni
diverse. Se l'applicazione desidera abilitare il controllo di concorrenza,
può impostare `SWIFT_STRICT_CONCURRENCY` direttamente sui propri target.

---

## 🧪 Test

- Il progetto builda correttamente su iOS 16+
- I test coprono Watchers sia per notifiche locali che per simulazioni di cambiamenti remoti
- Compatibilità piena con `Entity`, `Relationship`, `Search`

---

## 📌 Note operative

### Migrazione applicativa dello store

GraphEvo verifica la compatibilità del file SQLite prima di aprirlo. Se il modello non è compatibile, espone `GraphStoreOpeningError.incompatibleStore` e lascia invariati percorso, nome e contenuto dello store. La migrazione tra il modello CosmicMind/Graph e quello GraphEvo deve essere eseguita dall’applicazione, che conosce il significato dei propri dati.

---

## ☁️ Configurazione CloudKit

Per abilitare la sincronizzazione con il database privato CloudKit, è necessario specificare un **container identifier**.

È possibile farlo in due modi:

1. **Override a runtime** (consigliato):
   ```swift
   Graph.cloudKitContainerIdentifier = "iCloud.com.tuodominio.laTuaApp"
   var configuration = GraphStoreConfiguration()
   configuration.name = "Main"
   let graph = Graph(configuration: configuration)
   ```

2. **Info.plist fallback** (opzionale):
   - Aggiungere una chiave `GraphCloudKitContainerIdentifier` di tipo `String` con valore `iCloud.com.tuodominio.laTuaApp`.

Se non viene specificato alcun identifier, lo store funziona comunque in modalità **locale** senza sincronizzazione.

## 📣 Stati, warning ed errori

GraphEvo non dipende da una piattaforma di logging dell'applicazione. Per
ricevere gli eventi importanti e gestirli con il logger dell'app, assegnare un
`GraphEventDelegate`:

```swift
final class GraphEvents: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        switch event {
        case .stateChanged(let state):
            appLogger.info("GraphEvo state: \(state)")
        case .warning(let warning):
            appLogger.warning(warning.localizedDescription)
        case .error(let error):
            appLogger.error(error.localizedDescription)
        }
    }
}

let graph = Graph(configuration: configuration)
let graphEvents = GraphEvents()
graph.eventDelegate = graphEvents
```

`GraphReadiness` descrive esclusivamente l'utilizzabilità tecnica dello store
e del relativo contesto Core Data. Un errore di una migrazione applicativa viene
inviato come `GraphFailure.migration`, ma non porta automaticamente la
readiness a `.failed` se lo store è comunque utilizzabile.

Gli eventi vengono consegnati sul main thread. Gli stati e gli errori emessi
durante l'apertura dello store vengono accodati fino all'assegnazione del
delegate. Le API esistenti (`whenReady`, `GraphCloudStatusDelegate` e le
completion di `sync`) restano disponibili per compatibilità.

Gli stati, i warning e gli aggiornamenti di avanzamento non vengono stampati
automaticamente su stdout: l'applicazione è responsabile del loro logging.
Gli errori non recuperabili restano disponibili anche su stdout come supporto
diagnostico minimo.

La scrittura del file JSONL delle migrazioni è disabilitata per default. Se
necessario per un caso di diagnostica, l'app può abilitarla esplicitamente con
`GraphMigrationLogger.fileLoggingEnabled = true`.
