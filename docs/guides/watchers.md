# Watchers and change events

`Watch<T>` receives notifications when nodes of a given type change. It is
useful for updating a UI or reacting to data from another context or CloudKit.

## Create a watcher

Watchers are typed and initially stopped:

```swift
final class EntityEvents: GraphEntityDelegate {
    func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
        print("Inserted \(entity.type) from \(source)")
    }
}

let entityEvents = EntityEvents()
let watch = Watch<Entity>(graph: graph)
watch.delegate = entityEvents
watch.where(.type("Note"))
watch.resume()
```

The app must keep the delegate alive. `Watch<Entity>` uses
`GraphEntityDelegate`; use `GraphRelationshipDelegate` or
`GraphActionDelegate` for the other node types.

## Lifecycle

- `resume()` starts observation;
- `pause()` suspends it and removes observations;
- `clear()` removes the filter;
- deallocating the watcher automatically removes observations.

Reuse a watcher by calling `pause()`, changing its filter, and calling `resume()`.

## Callback types

The three delegates cover node insertion, update, and deletion; property
addition, modification, and removal; tag addition and removal; and entering
and leaving groups. For a relationship or action, the main parameter changes
type but the callback shape remains the same.

## Change source

`GraphSource.local` indicates a change observed in the local context.
`GraphSource.cloud` indicates a change processed through Persistent History
from another context or CloudKit.

Do not assume that every Cloud change produces exactly one callback: transaction
authors and ordered merges reduce duplicates, but the app must keep callbacks
idempotent.

## Filters

```swift
watch.where(.type("User"))
watch.where(.has(tags: "active"))
```

As with `Search`, successive `where` calls are combined with OR. Build one
`Predicate` when an explicit AND is required.
