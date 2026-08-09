# Getting started

This guide shows the minimum path for using GraphEvo in an iOS or macOS app.

## 1. Add the package

Add the Swift package to the project and import the module:

```swift
import GraphEvo
```

GraphEvo requires iOS 16+ or macOS 12+, as declared by `Package.swift`.

## 2. Create a configuration

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
```

With this configuration GraphEvo creates or opens an SQLite store named
`GraphEvo_Main.sqlite` in the default directory. For a dedicated path:

```swift
configuration.location = File.applicationSupportDirectoryPath!
    .appendingPathComponent("MyApp/Graph", isDirectory: true)
```

For the distinction between directories and SQLite files, see
[Persistence](../concepts/persistence.md).

## 3. Open the graph

```swift
let graph = Graph(configuration: configuration)

graph.whenReady { result in
    switch result {
    case .success(let graph):
        print("Graph ready: \(graph.name)")
    case .failure(let error):
        print("Opening failed: \(error.localizedDescription)")
    }
}
```

`Graph` may begin opening during initialization, so `whenReady` is the clearest
way to coordinate UI or initial loading.

## 4. Create and save data

```swift
let user = Entity("User", graph: graph)
user["name"] = "Ada Lovelace"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
note["title"] = "First note"
user.is(relationship: "writes").of(note)

graph.sync { success, error in
    if let error {
        print(error.localizedDescription)
    } else if success {
        print("Data saved")
    }
}
```

`sync` and `async` completions are delivered on the main thread. Mutations are
performed in the graph's context.

## 5. Search data

```swift
let notes = Search<Entity>(graph: graph)
    .where(.type("Note"))
    .where(.has(tags: "important"))
    .sync()
```

For more advanced queries, see [Search and predicates](search-and-predicates.md).

## 6. Receive events

```swift
final class Events: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        print("GraphEvo: \(event)")
    }
}

let events = Events()
graph.eventDelegate = events
```

The app must keep the delegate alive. Events are delivered on the main thread;
events emitted before assignment are queued.

## 7. Clear or reset

```swift
graph.clear() // Deletes nodes and saves.
graph.reset() // Resets the context without deleting the filesystem store.
```

`clear()` operates on data. `reset()` concerns the Core Data context and must
not be used as a replacement for deleting the SQLite file.
