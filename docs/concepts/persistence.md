# Persistenza e URL degli store

GraphEvo usa Core Data per persistere i dati. Il backend predefinito è SQLite;
per i test e gli scenari temporanei è disponibile anche uno store in-memory.

## Configurazione minima

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
let graph = Graph(configuration: configuration)
```

Il nome produce il file canonico `GraphEvo_Main.sqlite` quando `location` è una
directory.

## Directory o file?

`location` è interpretata come file esplicito solo se la sua estensione è
`.sqlite`. Altrimenti viene trattata come directory.

```swift
// Directory: GraphEvo costruisce il nome finale.
configuration.location = URL(fileURLWithPath: "/tmp/MyApp/Graph", isDirectory: true)
// /tmp/MyApp/Graph/GraphEvo_Main.sqlite

// File: il percorso completo viene mantenuto.
configuration.location = URL(fileURLWithPath: "/tmp/MyApp/custom.sqlite")
// /tmp/MyApp/custom.sqlite
```

Usare `URL(fileURLWithPath:)` per percorsi locali. Non concatenare manualmente
stringhe `file://` e non passare URL HTTP a Core Data.

## Le proprietà URL

- `resolvedLocation` è la directory di lavoro dopo l’eventuale risoluzione App
  Group.
- `storeURL` è il percorso canonico calcolato dalla configurazione.
- `resolvedStoreURL` è il percorso che GraphEvo aprirà davvero.

La differenza è importante quando esiste uno store legacy. Il percorso canonico
può non esistere, mentre `resolvedStoreURL` può puntare a un vecchio percorso
riutilizzato.

## Store legacy

Con una configurazione a directory GraphEvo controlla, oltre al percorso
canonico, layout precedenti come:

```text
<directory>/Graph.sqlite
<directory>/Local/<name>/GraphEvo_<name>.sqlite
<directory>/Cloud/<name>/GraphEvo_<name>.sqlite
```

Un file esplicito `.sqlite` non attiva questa ricerca: quel file è la scelta
autoritativa dell’applicazione.

## App Group

Se `appGroupIdentifier` è valorizzato e `location` è una directory, GraphEvo
usa il container dell’App Group e il percorso `CosmicMind/Graph/`. Se il sistema
non riesce a risolvere l’App Group, viene mantenuta la directory configurata.

Un file SQLite esplicito ha sempre la precedenza e non viene spostato nell’App
Group automaticamente.

## Backend in-memory

```swift
configuration.backend = .inMemory
```

Il database vive solo in memoria. Le proprietà URL continuano a essere
calcolate per coerenza, ma non rappresentano un file che verrà conservato.

## Readiness ed errori

`GraphReadiness` descrive lo stato tecnico:

- `.initializing`: apertura in corso;
- `.ready`: store e contesto utilizzabili;
- `.failed(error)`: apertura fallita.

Gli errori principali sono `incompatibleStore`, `unreadableStore` e
`failedToLoadStore`. In caso di incompatibilità GraphEvo non modifica il file.

## Salvataggio

- `sync()` salva in modo sincrono;
- `async()` salva in background;
- `clear()` cancella gli oggetti e salva;
- `reset()` resetta il contesto senza cancellare il file.

Per i lavori in background usare `newBackgroundContext()` e rispettare la
concurrency queue del contesto Core Data.
