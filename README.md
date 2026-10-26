# GraphEvo

[![CI](https://github.com/bbruno84/GraphEvo/actions/workflows/ci.yml/badge.svg)](https://github.com/bbruno84/GraphEvo/actions/workflows/ci.yml)
[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-orange?logo=swift&logoColor=white)](https://www.swift.org/documentation/package-manager/)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%7C%20macOS%2013%2B-blue?logo=apple&logoColor=white)](Package.swift)
[![License MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)
[![Release](https://img.shields.io/github/v/release/bbruno84/GraphEvo?display_name=tag)](https://github.com/bbruno84/GraphEvo/releases)

GraphEvo is an independent Swift library evolved from
[CosmicMind/Graph](https://github.com/CosmicMind/Graph). It provides a Core
Data graph model with local persistence and CloudKit synchronization.

The library models entities, relationships, and actions, queries data with
readable predicates, and reacts to changes through watchers and notifications.

The companion demonstration app is maintained separately in the
[GraphEvoDemo repository](https://github.com/bbruno84/GraphEvoDemo).

## 📚 Documentation

- [Complete public API reference](docs/api/public-api.md)
- [Operational instructions for AI agents](AGENTS.md)
- [Documentation index](docs/README.md)
- [Getting started guide](docs/guides/getting-started.md)
- [Graph model](docs/concepts/graph-model.md)
- [Persistence](docs/concepts/persistence.md)
- [CloudKit](docs/concepts/cloudkit.md)
- [Migrations](docs/migrations/overview.md)

---

## ✨ Main features

- Core Data graph model with `Entity`, `Relationship`, and `Action`
- `NSPersistentCloudKitContainer` support with local fallback
- SQLite stores compatible with existing `GraphEvo_<name>.sqlite` paths
- Directory-based configuration with separate CloudKit Development and Production filenames; eligible legacy paths are reused automatically
- `Graph(storeURL:)` accepts a directory or SQLite file, including a file not yet created, preserves an explicit file path, and always opens it as local persistence
- No automatic migration between incompatible models: the app must migrate its store and reopen it at the original path
- Secure encoding of heterogeneous values through `ValueTransformer`
- Enabled options: `NSPersistentHistoryTrackingKey`, `NSPersistentStoreRemoteChangeNotificationPostOptionKey`
- `GraphCloudStatusDelegate` for iCloud availability notifications, with local fallback when unavailable
- Local and remote watchers/notifications through **Persistent History Tracking**
- CloudKit configuration through a runtime override or an Info.plist fallback
- CloudKit precedence: explicit configuration, runtime override, then `Info.plist`

---

## 📦 Requirements

- iOS 16+
- macOS 13+
- Xcode 16+ on the v2 development line
- Swift 6+ package manifest and compiler
- Swift Package Manager

## 📦 Installation and first use

In Xcode, add a package dependency using
`https://github.com/bbruno84/GraphEvo.git` and select the `GraphEvo` product.
Select an Up to Next Major Version requirement starting at `1.0.0`.

For a Swift package, add the dependency and product to the relevant target:

```swift
dependencies: [
    .package(url: "https://github.com/bbruno84/GraphEvo.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "GraphEvo", package: "GraphEvo")
    ])
]
```

Import the public module and wait for the store to be ready before creating data:

```swift
import GraphEvo

var configuration = GraphStoreConfiguration()
configuration.name = "Main"
let graph = Graph(configuration: configuration)

graph.whenReady { result in
    switch result {
    case .success(let graph):
        let user = Entity("User", graph: graph)
        user[dynamicMember: "name"] = "Ada"
        graph.sync { success, error in
            if !success { print(error?.localizedDescription ?? "Save failed") }
        }
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

`Graph` remains the name of the main class and the domain concepts exposed by
the API. Keep the graph alive for as long as the application uses its nodes,
queries, and watchers. See [Getting started](docs/guides/getting-started.md).

The `GraphEvo_` prefix and its persistent internal paths and keys are
canonical for the new release. Stores created by earlier test versions with
the `GraphCK_` prefix are not migrated automatically.

GraphEvo does not impose `-Xfrontend` flags or strict-concurrency settings on
the integrating project. Applications can configure `SWIFT_STRICT_CONCURRENCY`
on their own targets. Graph and Node operations must respect their Core Data
context queues; context-bound objects must not be passed between queues.

The v2 development line now includes an internal `GraphEvoRuntime` target
compiled in Swift 6 language mode. The existing facade and its tests remain
temporarily in Swift 5 language mode; this is not yet full-library Swift 6
adoption. The public product remains `GraphEvo`. See the
[A1 store runtime increment](docs/design/graphevo-2-store-runtime.md) for scope,
ownership rules and verification.

---

## 🧪 Tests

CI builds and tests the package on iOS Simulator and macOS. Tests cover the
public graph API, store opening, migrations, transactions, watchers, and
simulated remote history. The separate
[package consumer fixture](IntegrationTests/PackageConsumer/README.md) runs
on PRs targeting `master` and pushes to `master`.

These checks do not establish live CloudKit synchronization across devices or
coverage of every supported OS version. See the
[CloudKit verification scope](docs/concepts/cloudkit.md#verification-scope).

---

## 📌 Operational notes

### Application-level store migration

GraphEvo checks SQLite compatibility before opening a store. If the model is
incompatible, it exposes `GraphStoreOpeningError.incompatibleStore` and leaves
the store path, name, and contents unchanged. Migration between the
CosmicMind/Graph model and the GraphEvo model must be performed by the app,
which understands the meaning of its own data.

---

## ☁️ CloudKit configuration

To enable synchronization with the private CloudKit database, provide a
**container identifier**.

1. **Per-store configuration**:

   ```swift
   var configuration = GraphStoreConfiguration()
   configuration.name = "Main"
   configuration.cloudKitContainerIdentifier = "iCloud.com.yourdomain.yourApp"
   let graph = Graph(configuration: configuration)
   ```

2. **Runtime fallback**: set `Graph.cloudKitContainerIdentifier` before opening
   graphs that do not specify their own identifier.

3. **Info.plist fallback**: add a `String` key named
   `GraphCloudKitContainerIdentifier` with a value such as
   `iCloud.com.yourdomain.yourApp`.

Without an identifier, the store still works in **local** mode without
synchronization.

The app must configure its CloudKit capabilities and signing. Read the
[CloudKit guide](docs/concepts/cloudkit.md) for environment selection, local
fallback, and synchronization diagnostics.

## 📣 State, warnings, and errors

GraphEvo does not depend on an application logging platform. To receive
important events and route them to the app logger, assign a `GraphEventDelegate`:

```swift
final class GraphEvents: GraphEventDelegate {
    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        switch event {
        case .transactionDiagnostic(let trace):
            appLogger.info("Transaction diagnostic: \(trace.diagnosticID), phase: \(trace.phase.rawValue)")
        case .stateChanged(let state):
            appLogger.info("GraphEvo state: \(state)")
        case .warning(let warning):
            appLogger.warning(warning.localizedDescription)
        case .error(let error):
            appLogger.error(error.localizedDescription)
        }
    }
}

let graph = Graph(configuration: configuration)
let graphEvents = GraphEvents()
graph.eventDelegate = graphEvents
```

By default, application migration errors are delivered as `GraphFailure.migration`
without failing readiness when the store remains usable. Applications that
require migrations to succeed before use can set
`configuration.waitsForApplicationMigrations = true`; migration failures then
fail readiness. A throwing `preflight` also rejects opening. See
[Migrations](docs/migrations/overview.md#safety-rules).

Events are delivered on the main thread. States and errors emitted while the
store is opening are queued until a delegate is assigned. Existing APIs
(`whenReady`, `GraphCloudStatusDelegate`, and `sync` completions) remain
available for compatibility.

States, warnings, and progress updates are not printed automatically to
stdout; the application is responsible for logging them. Unrecoverable errors
remain available on stdout as minimal diagnostic support.

Migration JSONL file logging is disabled by default. For diagnostics, the app
can enable it explicitly with
`GraphMigrationLogger.fileLoggingEnabled = true`.

## License and attribution

GraphEvo is derived from [CosmicMind/Graph](https://github.com/CosmicMind/Graph),
which is distributed under the MIT License. The original copyright and license
notice are preserved in [`LICENSE.md`](LICENSE.md).

GraphEvo and its modifications are released under the MIT License. Copyright
for GraphEvo modifications belongs to the GraphEvo contributors.

GraphEvo includes substantial changes and extensions to the original project,
including the `GraphEvo` module, updated persistence behavior, migrations,
CloudKit handling, tools, and documentation. GraphEvo is not affiliated with
or endorsed by CosmicMind.
