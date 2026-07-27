# GraphCK

GraphCK è un fork moderno e aggiornato della libreria [CosmicMind/Graph](https://github.com/CosmicMind/Graph), pensato per supportare Core Data in modo modulare e aprire la strada alla sincronizzazione via CloudKit.

---

## ✅ Milestone M3 – Watchers & Remote Change

- Refactor modello (M1) completato: rimosso `Transformable` generico, introdotto `ValueTransformer` sicuro
- Supporto `NSPersistentCloudKitContainer` (M2)
- Store SQLite rinominato automaticamente in `GraphCK_<name>.sqlite`
- La configurazione a directory usa un percorso canonico indipendente dal backend; i vecchi percorsi `Local/...` e `Cloud/...` vengono riutilizzati automaticamente
- `Graph(storeURL:)` accetta sia una directory sia un file SQLite esistente, mantenendo invariato il percorso del file esplicito
- GraphCK non esegue migrazioni automatiche tra modelli incompatibili: l’app deve migrare il proprio store e poi riaprirlo sul percorso originale
- Opzioni abilitate: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- Delegate `GraphCloudStatusDelegate` per notificare disponibilità iCloud (fallback locale se non disponibile)
- Integrazione Watchers con supporto a notifiche locali e remote via **Persistent History Tracking**
- Notifica custom `GraphCKSimulatedRemoteChange` usata nei test per simulare cambiamenti da remoto
- **Configurazione CloudKit**: override runtime dell’identifier (`Graph.cloudKitContainerIdentifier`) o fallback Info.plist
- La precedenza CloudKit è: configurazione esplicita, override runtime, quindi `Info.plist`

---

## 📦 Requisiti

- iOS 16+
- Xcode 15.4+
- Swift Package Manager

GraphCK non impone flag `-Xfrontend` o impostazioni di strict concurrency al
progetto che la integra. Questa scelta mantiene il prodotto consumabile anche
da target che usano CocoaPods o altre dipendenze SwiftPM con impostazioni
diverse. Se l'applicazione desidera abilitare il controllo di concorrenza,
può impostare `SWIFT_STRICT_CONCURRENCY` direttamente sui propri target.

---

## 🚧 Roadmap

| Milestone | Descrizione | Stato |
|----------|-----------------------------------------------|-------|
| **M0**   | Pulizia codice, rimozione iCloud classico     | ✅ Completato |
| **M1**   | Refactor model, preparazione per CloudKit     | ✅ Completato |
| **M2**   | Supporto a CloudKit (sincronizzazione)        | ✅ Completato |
| **M3**   | Supporto Watchers con notifiche remote        | ✅ Completato |
| **M4**   | Supporto sharing multi-account (CloudKit sharing) | 🔜 |

---

## 🧪 Test

- Il progetto builda correttamente su iOS 16+
- I test coprono Watchers sia per notifiche locali che per simulazioni di cambiamenti remoti
- Compatibilità piena con `Entity`, `Relationship`, `Search`

---

## 📌 Note operative

### Migrazione applicativa dello store

GraphCK verifica la compatibilità del file SQLite prima di aprirlo. Se il modello non è compatibile, espone `GraphStoreOpeningError.incompatibleStore` e lascia invariati percorso, nome e contenuto dello store. La migrazione tra il modello CosmicMind/Graph e quello GraphCK deve essere eseguita dall’applicazione, che conosce il significato dei propri dati.

- In produzione verificare il comportamento delle notifiche con CloudKit:
  - Possibili **doppie callback** del delegato (locale + remoto) da analizzare.
  - Necessario investigare l'**autore delle modifiche** (transaction author) per discriminare le modifiche provenienti da CloudKit rispetto a quelle locali.
- Questi aspetti sono monitorati e verranno documentati in modo esteso quando emergeranno in scenari reali.

---

## ☁️ Configurazione CloudKit

Per abilitare la sincronizzazione con il database privato CloudKit, è necessario specificare un **container identifier**.

È possibile farlo in due modi:

1. **Override a runtime** (consigliato):
   ```swift
   Graph.cloudKitContainerIdentifier = "iCloud.com.tuodominio.laTuaApp"
   let graph = Graph(name: "Main")
   ```

2. **Info.plist fallback** (opzionale):
   - Aggiungere una chiave `GraphCloudKitContainerIdentifier` di tipo `String` con valore `iCloud.com.tuodominio.laTuaApp`.

Se non viene specificato alcun identifier, lo store funziona comunque in modalità **locale** senza sincronizzazione.

## 📣 Stati, warning ed errori

GraphCK non dipende da una piattaforma di logging dell'applicazione. Per
ricevere gli eventi importanti e gestirli con il logger dell'app, assegnare un
`GraphEventDelegate`:

```swift
final class GraphEvents: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        switch event {
        case .stateChanged(let state):
            appLogger.info("GraphCK state: \(state)")
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

Gli eventi vengono consegnati sul main thread. Gli stati e gli errori emessi
durante l'apertura dello store vengono accodati fino all'assegnazione del
delegate. Le API esistenti (`whenReady`, `GraphCloudStatusDelegate` e le
completion di `sync`) restano disponibili per compatibilità.
