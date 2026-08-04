# Getting started

Questa guida mostra il percorso minimo per usare GraphEvo in un’app iOS o macOS.

## 1. Aggiungere il package

Aggiungere il package Swift al progetto e importare il modulo:

```swift
import GraphEvo
```

GraphEvo richiede iOS 16+ o macOS 12+ secondo il `Package.swift`.

## 2. Creare una configurazione

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
```

Con questa configurazione GraphEvo crea o apre uno store SQLite con nome
`GraphEvo_Main.sqlite` nella directory predefinita. Per un percorso dedicato:

```swift
configuration.location = File.applicationSupportDirectoryPath!
    .appendingPathComponent("MyApp/Graph", isDirectory: true)
```

Per i dettagli sulla differenza tra directory e file SQLite vedere
[Persistenza](../concepts/persistence.md).

## 3. Aprire il graph

```swift
let graph = Graph(configuration: configuration)

graph.whenReady { result in
    switch result {
    case .success(let graph):
        print("Graph pronto: \(graph.name)")
    case .failure(let error):
        print("Apertura fallita: \(error.localizedDescription)")
    }
}
```

`Graph` può iniziare l’apertura durante il proprio inizializzatore, quindi
`whenReady` è il modo più chiaro per coordinare la UI o il caricamento iniziale.

## 4. Creare e salvare dati

```swift
let user = Entity("User", graph: graph)
user["name"] = "Ada Lovelace"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
note["title"] = "Prima nota"
user.is(relationship: "writes").of(note)

graph.sync { success, error in
    if let error {
        print(error.localizedDescription)
    } else if success {
        print("Dati salvati")
    }
}
```

Le completion di `sync` e `async` vengono consegnate sul main thread. Le
modifiche sono eseguite sul contesto del graph.

## 5. Cercare dati

```swift
let notes = Search<Entity>(graph: graph)
    .where(.type("Note"))
    .where(.has(tags: "important"))
    .sync()
```

Per query più articolate consultare [Search e Predicate](search-and-predicates.md).

## 6. Ricevere eventi

```swift
final class Events: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        print("GraphEvo: \(event)")
    }
}

let events = Events()
graph.eventDelegate = events
```

Il delegate va mantenuto in vita dall’applicazione. Gli eventi vengono
consegnati sul main thread; quelli emessi prima dell’assegnazione vengono
accodati.

## 7. Cancellare o resettare

```swift
graph.clear() // cancella i nodi e salva
graph.reset() // resetta il contesto senza cancellare lo store dal filesystem
```

`clear()` è un’operazione sui dati. `reset()` riguarda il contesto Core Data e
non va usato come sostituto della cancellazione del file SQLite.
