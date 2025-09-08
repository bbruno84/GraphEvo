# GraphCK

GraphCK è un fork moderno e aggiornato della libreria [CosmicMind/Graph](https://github.com/CosmicMind/Graph), pensato per supportare Core Data in modo modulare e aprire la strada alla sincronizzazione via CloudKit.

---

## ✅ Milestone M3 – Watchers & Remote Change

- Refactor modello (M1) completato: rimosso `Transformable` generico, introdotto `ValueTransformer` sicuro
- Supporto `NSPersistentCloudKitContainer` (M2)
- Store SQLite rinominato automaticamente in `GraphCK_<name>.sqlite`
- Opzioni abilitate: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- Delegate `GraphCloudStatusDelegate` per notificare disponibilità iCloud (fallback locale se non disponibile)
- Integrazione Watchers con supporto a notifiche locali e remote via **Persistent History Tracking**
- Notifica custom `GraphCKSimulatedRemoteChange` usata nei test per simulare cambiamenti da remoto
- **Configurazione CloudKit**: override runtime dell’identifier (`Graph.cloudKitContainerIdentifier`) o fallback Info.plist

---

## 📦 Requisiti

- iOS 16+
- Xcode 15.4+ (supportato anche Xcode 16 beta con `-strict-concurrency=minimal`)
- Swift Package Manager

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
