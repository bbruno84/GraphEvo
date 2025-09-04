# GraphCK

GraphCK è un fork moderno e aggiornato della libreria [CosmicMind/Graph](https://github.com/CosmicMind/Graph), pensato per supportare Core Data in modo modulare e aprire la strada alla sincronizzazione via CloudKit.

---

## ✅ Stato attuale (Milestone M0 – Bootstrap Clean)

- Rimosso completamente il supporto a **iCloud Ubiquitous Store**
- I costruttori `init(cloud:...)` sono **deprecati**
- Ogni istanza di `Graph` usa ora uno **store locale SQLite**
- Delegate legacy relativi al cloud sono **deprecati** e in no-op
- Supporto a `Graph(name:)`, `Graph(name:locate:)` completamente funzionante

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
| **M1** | Refactor model, preparazione per CloudKit | 🔜 |
| **M2** | Supporto a CloudKit (sincronizzazione) | ⏳ |
| **M3** | Supporto sharing multi-account (CloudKit sharing) | ⏳ |

---

## 🧪 Test

- Il progetto builda correttamente su iOS 16+
- Le istanze di `Graph` funzionano come store locali
- Compatibilità piena con `Watcher`, `Search`, `Entity`, `Relationship`

---

## 📖 Licenza

MIT License – © CosmicMind / Fork a cura di [@bbruno84](https://github.com/bbruno84)