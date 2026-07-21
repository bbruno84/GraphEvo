# PR7 — Audit della suite di test

Data dell’ultima verifica: 21 luglio 2026

## Risultato

- 91 test eseguiti su iOS Simulator.
- 0 fallimenti.
- 0 test saltati.
- Suite ripetuta più volte senza dipendenze rilevate dall’ordine di esecuzione.
- Build `Release` completata correttamente.
- Copertura complessiva del modulo `Graph`: 81,54% (6.213/7.620 linee).

Comando di riferimento:

```text
xcodebuild -scheme Graph-Package \
  -destination 'platform=iOS Simulator,id=BCB500FA-49F0-4DC7-AA41-988B871D5019' \
  -enableCodeCoverage YES test
```

## Funzionalità coperte

La suite verifica con asserzioni comportamentali:

- apertura SQLite e in-memory, risoluzione dei percorsi, registry e aperture concorrenti;
- rifiuto di store incompatibili o illeggibili senza alterare percorso e nome dello store;
- metadata, versioning, backup e ledger delle migrazioni;
- ciclo di vita delle migrazioni, inclusi completamento preesistente, fallback, skip, errore e isolamento dello stato globale nei test;
- serializzazione sicura di valori primitivi, `Date`, `Data`, `URL`, immagini, PDF e wrapper Codable;
- ricerca, predicati composti, relazioni, azioni, tag, gruppi e deduplicazione;
- watcher locali e cambi simulati remoti;
- Persistent History locale/simulata, token, corruzione, filtro dell’autore e avanzamento del token;
- utility file, classificazione, path e inizializzatore compatibile di `NSPersistentContainer`.

## Copertura esclusa intenzionalmente

Le righe non coperte non sono state forzate con test privi di valore diagnostico:

- percorsi CloudKit reali, inclusi sincronizzazione, import/export e fallback dipendenti da account/entitlement; richiedono un dispositivo fisico e un ambiente CloudKit configurato;
- `Coordinator` e parti `Managed*` mantenute esclusivamente per compatibilità con il vecchio stack ubiquitous;
- diagnostica che produce soltanto output testuale, come `DeepPropertiesScan`, senza un risultato strutturato da poter verificare;
- codice di supporto interno non raggiungibile dal flusso moderno o generato da Core Data.

Queste esclusioni sono di perimetro, non test falliti né test mancanti per funzionalità locali di produzione.

## Criterio di chiusura

La PR7 può considerarsi completa per il perimetro locale/simulabile quando la suite resta verde, stabile e ogni residuo di copertura è riconducibile a una delle categorie sopra indicate. I test CloudKit reali restano da eseguire separatamente su dispositivo.
