# GraphCK

GraphCK è un fork moderno e aggiornato della libreria [CosmicMind/Graph](https://github.com/CosmicMind/Graph), pensato per supportare Core Data in modo modulare e aprire la strada alla sincronizzazione via CloudKit.

---

## ✅ Stato attuale (Milestone M2 – CloudKit Container)

- Refactor modello (M1) completato: rimosso `Transformable` generico, introdotto `ValueTransformer` sicuro
- Sostituito `NSPersistentContainer` con `NSPersistentCloudKitContainer`
- Store SQLite rinominato automaticamente in `GraphCK_<name>.sqlite`
- Opzioni abilitate: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- Delegate `GraphCloudStatusDelegate` per notificare disponibilità iCloud (funziona anche senza entitlements, fallback locale)
- Fallback automatico su store locale se iCloud non disponibile/non configurato
- Costruttori `init(cloud:...)` deprecati ma reindirizzati al container CloudKit moderno
- **Configurazione CloudKit**: supporto a override runtime dell’identifier (`Graph.cloudKitContainerIdentifier`) o fallback Info.plist

---

## 📦 Requisiti

- iOS 16+
- Xcode 15.4+ (supportato anche Xcode 16 beta con `-strict-concurrency=minimal`)
- Swift Package Manager

---

## 🚧 Roadmap

| Milestone | Descrizione | Stato |
|----------|-------------|-------|
| **M0** | Pulizia codice, rimozione iCloud classico | ✅ Completato |
| **M1** | Refactor model, preparazione per CloudKit | ✅ Completato |
| **M2** | Supporto a CloudKit (sincronizzazione) | ✅ Completato |
| **M3** | Supporto sharing multi-account (CloudKit sharing) | 🔜 |

---

## 🧪 Test

- Il progetto builda correttamente su iOS 16+
- Le istanze di `Graph` funzionano come store locali
- Compatibilità piena con `Watcher`, `Search`, `Entity`, `Relationship`

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
