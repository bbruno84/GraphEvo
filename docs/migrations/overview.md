# Migrazioni

Una migrazione è una trasformazione applicativa dei dati già salvati. GraphEvo
fornisce il lifecycle e il ledger, ma non decide come interpretare i dati
dell’applicazione.

## Quando serve

Serve una migrazione quando cambia il significato dei dati, il formato delle
proprietà, il modo di identificare un’entità o la struttura delle relazioni.
Un cambio incompatibile del modello Core Data non viene migrato automaticamente.

## Contratto

Implementare `GraphMigration`:

```swift
struct AddNoteStatus: GraphMigration {
    let id = "add-note-status"
    let version = 1

    func needsRun(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: inout GraphMigrationContext?
    ) -> Bool {
        phase == .postMigration
    }

    func handlePhase(
        _ phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        completion: @escaping (GraphMigrationResult) -> Void
    ) {
        // trasformare i dati...
        completion(.done)
    }
}
```

Le altre funzioni del protocollo consentono di definire backup, gestione dei
cambiamenti remoti, riconoscimento di completamenti legacy e reset dello stato.

## Fasi

- `.preInit`: prima dell’apertura completa del graph;
- `.postInit`: dopo l’inizializzazione;
- `.postMigration`: fase dedicata alle migrazioni;
- `.ready`: graph pronto per l’uso normale.

Registrare le migrazioni prima di creare il graph:

```swift
GraphMigrationManager.registerMigration(AddNoteStatus())
```

La registrazione avviene una sola volta per `id` e l’esecuzione segue l’ordine
di registrazione.

## Risultati e stato

La completion riceve `GraphMigrationResult`:

- `.done`: migrazione completata;
- `.error(Error)`: fallimento;
- `.fallback`: usare un percorso alternativo;
- `.skipped`: non necessaria.

Il ledger espone `GraphMigrationRecord` e gli stati `started`, `done` e `failed`.
Un errore applicativo viene emesso come `GraphFailure.migration`; non implica
automaticamente che il graph sia inutilizzabile.

## Contesto

`GraphMigrationContext` permette di passare dati tra fasi. La proprietà
`previousMigrationRecord` espone il record precedente quando disponibile.

## Regole di sicurezza

1. Fare un backup prima di trasformare dati persistenti.
2. Rendere la migrazione ripetibile o controllare il ledger prima di eseguirla.
3. Non cancellare lo store originale prima di aver verificato il risultato.
4. Registrare errori e versione della migrazione.
5. Testare sia successo sia ripristino dopo un fallimento.
