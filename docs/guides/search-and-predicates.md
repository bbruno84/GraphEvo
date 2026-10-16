# Search and predicates

`Search<T>` runs typed searches over graph objects. `Predicate` provides a
compact language for filters without manually building `NSPredicate` strings.

## Basic search

```swift
let users = Search<Entity>(graph: graph)
    .where(.type("User"))
    .sync()
```

The generic type must be a supported node (`Entity`, `Relationship`, or
`Action`). Without a predicate, the search returns an empty array.
Use `.where(.type("*"))` to select all types in the chosen node family.

## Available filters

```swift
.type("User")
.exists("email")
.has(tags: "active")
.member(of: "staff")
```

Functions also accept arrays and combinations of strings. Property comparisons
use natural syntax:

```swift
"name" == "Ada"
"age" >= 18
"createdAt" <= someDate
```

Strings are compared case- and diacritic-insensitively.

## Combining predicates

```swift
let filter = (.type("User") && .has(tags: "active")) || .type("Admin")
let visible = Search<Entity>(graph: graph).where(filter).sync()
```

`&&`, `||`, and the prefix `!` are available.

```swift
let notArchived = !("isArchived" == true)
```

## Important: successive `where` calls

The current implementation of `Search.where` combines predicates added by
successive calls with OR. To express AND conditions, build one predicate with
`&&`.

## Synchronous and asynchronous results

```swift
let result = Search<Entity>(graph: graph)
    .where(.type("Note"))
    .sync()

Search<Entity>(graph: graph)
    .where(.type("Note"))
    .async { notes in
        updateUI(with: notes)
    }
```

`sync()` waits for the fetch and returns the array. Its optional completion runs
on the main thread. `async()` schedules the search on the graph's context queue;
an ordinary Graph uses a main-queue context, so this is not a background-context
fetch. With an available context, its completion is delivered on the main
thread; without a context it immediately returns `[]` to the caller's queue.
Result nodes remain bound to their owning context.

## Fetch batching and offsets

`Graph` exposes `batchSize` and `batchOffset`, applied to subsequent searches as
Core Data's `fetchBatchSize` and `fetchOffset`:

```swift
graph.batchSize = 20
graph.batchOffset = 40
let remainingNotes = Search<Entity>(graph: graph).where(.type("Note")).sync()
```

`batchSize` controls fetch batching, not the maximum number of returned nodes.
The example skips 40 matching rows and can return more than 20 nodes. Searches
do not set a fetch limit or sort descriptors, so these properties do not provide
stable page-based pagination. `batchSize = 0` uses Core Data's default batching.

## Combining searches

```swift
let users = Search<Entity>(graph: graph).where(.type("User"))
let admins = Search<Entity>(graph: graph).where(.type("Admin"))
let both = (users + admins).sync()
```

Both searches must belong to the same `Graph`.
