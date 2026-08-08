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

`sync()` returns the array immediately. Its optional completion runs on the
main thread. `async()` starts the search in the background.

## Pagination

`Graph` exposes `batchSize` and `batchOffset`, applied to subsequent searches:

```swift
graph.batchSize = 20
graph.batchOffset = 40
let page = Search<Entity>(graph: graph).where(.type("Note")).sync()
```

Set `batchSize = 0` to remove the limit.

## Combining searches

```swift
let users = Search<Entity>(graph: graph).where(.type("User"))
let admins = Search<Entity>(graph: graph).where(.type("Admin"))
let both = (users + admins).sync()
```

Both searches must belong to the same `Graph`.
