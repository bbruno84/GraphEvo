# CloudKit

GraphEvo can use `NSPersistentCloudKitContainer` to synchronize a private
CloudKit store. Synchronization is optional: without a container identifier,
the graph remains local.

## Configuration

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
configuration.cloudKitContainerIdentifier = "iCloud.com.example.app"

let graph = Graph(configuration: configuration)
```

A runtime override is also available:

```swift
Graph.cloudKitContainerIdentifier = "iCloud.com.example.app"
```

As a fallback, GraphEvo reads `GraphCloudKitContainerIdentifier` from
Info.plist. Precedence is explicit configuration, runtime override, then
Info.plist.

## When CloudKit is unavailable

GraphEvo can open a regular local store as a fallback. The app receives
`GraphWarning.cloudStoreFallback` and a matching `GraphPersistenceMode` state.
This keeps the app usable, but data created during fallback is not necessarily
synchronized.

Observe states through `GraphEventDelegate` and, when needed for the legacy
contract, `GraphCloudStatusDelegate`.

## Remote store purge

Administrative tools can ask GraphEvo to delete the Core Data zone from the
private CloudKit database:

```swift
graph.purgeCloudStore { result in
    switch result {
    case .success:
        // The app must reopen or recreate the local store and
        // clear local tokens and Persistent History.
        break
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

The API operates only on an `NSPersistentCloudKitContainer` actually loaded
with a CloudKit-configured store. It does not delete SQLite files, recreate the
store, or purge during tests or on a local fallback. Local reset and token/
history management remain the app's responsibility.

## CloudKit import completion

The app can observe completed imports through `GraphCloudSyncDelegate`:

```swift
final class SyncDelegate: GraphCloudSyncDelegate {
    func graph(_ graph: Graph, didCompleteCloudImport event: GraphCloudImportEvent) {
        guard event.succeeded else {
            // Handle event.error without treating the import as successful.
            return
        }
        if event.isInitialImport {
            // Optional app-specific post-import operation.
        }
    }
}

let syncDelegate = SyncDelegate()
graph.cloudSyncDelegate = syncDelegate
```

`NSPersistentCloudKitContainer` does not expose a distinct native event for
the first sync. GraphEvo identifies the first import by combining the initial
local replica state (an empty store with no local objects) with the first
completed `.import` event for that store. Only completed events count; `.setup`
and `.export` do not trigger callbacks. The callback is delivered on the main
queue, deduplicated by `event.identifier`, and does not guarantee that later
imports will not arrive. The app may use this signal for controlled post-import
operations such as explicit deduplication; GraphEvo performs no automatic
deduplication.

## Application requirements

An app integrating GraphEvo must configure in Xcode:

- the iCloud/CloudKit capability;
- a valid container identifier;
- the correct CloudKit environment;
- permissions and a model compatible with the data.

GraphEvo cannot replace the app's capability configuration.

## Remote changes

CloudKit changes pass through Persistent History, are merged into the observed
context, and are then forwarded to watchers with `GraphSource.cloud`. See
[Persistent History](../migrations/persistent-history.md).

In production, keep callbacks idempotent and verify behavior across multiple
devices: local and remote notifications may arrive at different times.
