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

## Exact lookups for application identifiers

For a literal, case- and diacritic-sensitive string comparison, use the
Graph-scoped lookup. It returns every matching entity, including duplicates:

```swift
let bills = graph.entities(type: "Bolletta", property: "codice_bolletta",
                           exactly: "Ä*?_[%]")
let selected = graph.entities(type: "Bolletta", matchingIDs: billIDs)
let edges = graph.relationships(type: "classified", subjectIDs: billIDs,
                                objectIDs: categoryIDs)
```

The exact type and property name narrow the native fetch. Property values use
Core Data's transformable storage, so the final value comparison is in Swift;
this is not a SQL value index. Physical IDs resolve through the current store's
Core Data coordinator without fetching the whole entity type. Relationship
endpoint filters become native object-ID predicates. Pass `nil` for an
unrestricted edge direction or an empty array to match nothing. These lookups
ignore `batchOffset`
so that a duplicate is not lost to pagination.

Legacy `Node.id` omits store identity. Use IDs only with the owning Graph; a
same-valued ID from a different store cannot be distinguished. ID resolution
requires the permanent SQLite-style `p<digits>` URI component. The current
context's pending inserts are visible, while `readSnapshot` sees committed rows
and `transaction` sees its scoped context. Return values from those scopes, not
Node facades.

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
