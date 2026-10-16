# Getting started

This guide shows the minimum path for using GraphEvo in an iOS or macOS app.

## 1. Add the package

Add `https://github.com/bbruno84/GraphEvo.git` as a Swift package dependency
and select the `GraphEvo` product. See the
[installation instructions](../../README.md#-installation-and-first-use)
for the `1.0.0` version requirement and a `Package.swift` example. Import the module:

```swift
import GraphEvo
```

GraphEvo requires iOS 16+ or macOS 12+, as declared by `Package.swift`, with a
Swift 5.9+ package manifest.

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
way to coordinate UI or initial loading. Run the following data operations only
after `.success`, on the graph's context queue (normally the main queue for an
ordinary Graph). Keep the Graph alive while using its nodes and watchers.

If migrations must succeed before the graph becomes ready, set
`configuration.waitsForApplicationMigrations = true` before initialization.
See [Migrations](../migrations/overview.md#safety-rules).

## 4. Create and save data

```swift
let user = Entity("User", graph: graph)
user[dynamicMember: "name"] = "Ada Lovelace"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
note[dynamicMember: "title"] = "First note"
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
    .where(.type("Note") && .has(tags: "important"))
    .sync()
```

This returns notes tagged `important`. Successive `where` calls combine their
conditions with OR; use a single compound predicate for AND. To fetch all nodes
of a family, use `.where(.type("*"))`; a search without a predicate returns no
results. See [Search and predicates](search-and-predicates.md).

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
