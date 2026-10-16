# Persistence and store URLs

GraphEvo uses Core Data to persist data. SQLite is the default backend; an
in-memory store is also available for tests and temporary scenarios.

## Minimal configuration

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
let graph = Graph(configuration: configuration)
```

When `location` is a directory, the name produces the canonical
`GraphEvo_Main.sqlite` file.

## Directory or file?

`location` is interpreted as an explicit file only when its extension is
`.sqlite`, case-insensitively. Otherwise it is treated as a directory. An
explicit file need not exist yet; GraphEvo creates it at the supplied path.

```swift
// Directory: GraphEvo builds the final name.
configuration.location = URL(fileURLWithPath: "/tmp/MyApp/Graph", isDirectory: true)
// /tmp/MyApp/Graph/GraphEvo_Main.sqlite

// File: the complete path is preserved.
configuration.location = URL(fileURLWithPath: "/tmp/MyApp/custom.sqlite")
// /tmp/MyApp/custom.sqlite
```

Use `URL(fileURLWithPath:)` for local paths. Do not concatenate `file://`
strings manually or pass HTTP URLs to Core Data.

## URL properties

- `resolvedLocation` is the working directory after any App Group resolution.
- `storeURL` is the canonical path calculated from the configuration.
- `resolvedStoreURL` is the path GraphEvo will actually open.

CloudKit-backed directory stores resolve their build environment automatically.
Development stores use a `-dev` suffix, while Production keeps the existing
filename. The environment is independent of the user's iCloud account status.
Use `try configuration.resolvingEnvironment()` before inspecting these paths,
or inspect `graph.configuration`, which contains the resolved environment.
The original configuration value is not mutated by Graph initialization.

`Graph(storeURL:)` opens local persistence and ignores runtime/Info.plist
CloudKit identifiers. Use `Graph(configuration:)` when CloudKit is required.

The difference matters when a legacy store exists. The canonical path may not
exist while `resolvedStoreURL` points to a reused legacy path.

## Legacy stores

For directory-based configuration, GraphEvo checks layouts such as these in
addition to the canonical path:

```text
<directory>/Graph.sqlite
<directory>/Local/<name>/GraphEvo_<name>.sqlite
<directory>/Cloud/<name>/GraphEvo_<name>.sqlite
```

An explicit `.sqlite` file does not trigger this search; that file is the
application's authoritative choice. CloudKit Development directory stores also
skip legacy lookup to avoid opening a Production store. For eligible directory
stores, an existing canonical file wins, followed by the preferred legacy route,
`Graph.sqlite`, then the alternate route.

## App Group

When `appGroupIdentifier` is set and `location` is a directory, GraphEvo uses
the App Group container and the `CosmicMind/Graph/` path. If the system cannot
resolve the App Group, the configured directory is retained.

An explicit SQLite file always takes precedence and is not moved to the App
Group automatically.

## In-memory backend

```swift
configuration.backend = .inMemory
```

The database exists only in memory. URL properties are still calculated for
consistency, but they do not identify a file that will be retained.

## Readiness and errors

`GraphReadiness` describes the technical state:

- `.initializing`: opening is in progress;
- `.ready`: the store and context are usable;
- `.failed(error)`: opening failed.

The main errors are `incompatibleStore`, `unreadableStore`, and
`failedToLoadStore`. For an incompatibility, GraphEvo does not modify the file.
CloudKit environment and registry conflicts can also prevent opening. A
throwing `preflight`, or a migration failure when
`waitsForApplicationMigrations` is enabled, reports `applicationMigrationFailed`.
With the default migration policy, migration failures are diagnostic events
and do not automatically fail a usable store. See
[Migrations](../migrations/overview.md#safety-rules).

## Saving

- `sync()` saves synchronously;
- `async()` schedules a save on the graph's context queue;
- `clear()` deletes objects and saves;
- `reset()` resets the context without deleting the file.

For background work, use `newBackgroundContext()` and respect the Core Data
context's concurrency queue. An ordinary Graph uses a main-queue view context,
so `async()` does not create a background context. Save completions run on the
main thread. `reset()` discards unsaved changes and invalidates context objects;
refetch nodes before continuing.
