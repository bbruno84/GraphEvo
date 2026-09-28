# CloudKit

GraphEvo can use `NSPersistentCloudKitContainer` to synchronize a private
CloudKit store. Synchronization is optional: without a container identifier,
the graph remains local. GraphEvo derives the signed build environment
internally and keeps Development and Production stores, ledgers, and KVS
projections separate; the application continues to provide only a
`GraphStoreConfiguration`.

When the explicit CloudKit environment entitlement is unavailable in a signed
iOS product, GraphEvo derives Development from `get-task-allow = true` and
Production from a distribution signature, after verifying that the signed
iCloud services include CloudKit. Simulator builds remain Development. The
application does not configure this distinction.

While a migration-enabled Graph is alive, GraphEvo observes external KVS
changes for that normalized store. Entries include the logical store scope and
publication/observation timestamps. Conflicts are ordered deterministically by
generation, pseudonymous installation ID, then operation ID. Remote state is
made available to migrations as an observation and never replaces the local
ledger projection directly.

Migration publication is tracked independently from observation. The
per-store ledger persists both the last projection accepted by the local KVS
store and a pending projection to retry. External notifications trigger
reconciliation through the same environment-aware scope; legacy completion
keys are promoted only for Production and are ignored in Development.

## Configuration

Developer tooling can inspect `try configuration.resolvingEnvironment()` before
opening a store. The returned copy exposes its read-only `environment` and
environment-aware URLs. Reject an unexpected environment before any mutation;
do not infer CloudKit Development from the filename or APNs entitlement.
This resolves configuration, not account availability or actual mirroring mode.

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

For a user-requested rebuild **from** CloudKit, use the separate pre-open
`Graph.resetLocalStore(configuration:beforeReset:)` API after arranging a
verified backup and durable one-shot intent. It destroys only the local replica
through Core Data, without a CloudKit container or remote purge. Registered
Graphs and SQLite writer locks prevent reset; errors are not forced through.
Reopen the same CloudKit configuration afterward and allow its normal import.
The app must prevent old migration backups from repopulating the rebuilt store.
See Apple's [local-store destruction API](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/destroypersistentstore(at:type:options:))
and [unsafe force-destruction option](https://developer.apple.com/documentation/coredata/nspersistentstoreforcedestroyoption),
which this wrapper explicitly disables.

Administrative tools can ask GraphEvo to delete the Core Data zone from the
private CloudKit database:

```swift
graph.purgeCloudStore { result in
    switch result {
    case .success:
        // Reload cached domain objects; the same graph can save again.
        // Keep SQLite files and their synchronization metadata.
        break
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

The API operates only on an `NSPersistentCloudKitContainer` actually loaded
with a CloudKit-configured store. It does not delete SQLite files, recreate the
store, or purge during tests or on a local fallback. Apple's operation deletes
the corresponding managed objects as well as remote records. On success the
view context is reset and the temporary write gate is released before completion.
While purge runs, saves and transactions fail with `writesBlockedDuringPurge`.
On failure the gate is also released. Callers must stop their own raw-context
writers during purge and reload cached domain objects after success. No lock is
held across the asynchronous operation, and no extra file deletion or history
erasure is required by this wrapper.

`NSPersistentCloudKitContainer` does not expose a distinct native event for
the first sync. GraphEvo identifies the first import by combining the initial
local replica state (an empty store with no local objects) with the first
completed `.import` event for that store. The `.started` and `.finished`
updates are delivered through `GraphEventDelegate` on the main queue and are
deduplicated by `event.identifier`. The `isInitialImport` flag remains
available on `GraphCloudImportEvent` for the completed import state.
The app may use this signal for controlled post-import operations such as
explicit deduplication; GraphEvo performs no automatic deduplication.

Import lifecycle diagnostics are also available through `GraphEventDelegate`,
using the same start/finish API as uploads:

```swift
func graph(_ graph: Graph, didReceive event: GraphEvent) {
    guard case .stateChanged(.cloudImport(let importState)) = event else { return }

    switch importState {
    case .started(let importEvent):
        print("CloudKit import started: \(String(describing: importEvent.identifier))")
    case .finished(let importEvent):
        print("CloudKit import finished: \(importEvent.succeeded)")
    }
}
```


## CloudKit upload diagnostics

The same native container event stream also reports CloudKit exports (uploads).
GraphEvo forwards their lifecycle through `GraphEventDelegate`:

```swift
func graph(_ graph: Graph, didReceive event: GraphEvent) {
    guard case .stateChanged(.cloudUpload(let uploadState)) = event else { return }

    switch uploadState {
    case .started(let upload):
        print("CloudKit upload started: \(upload.identifier)")
    case .finished(let upload):
        print("CloudKit upload finished: \(upload.succeeded)")
    }
}
```

`started` is emitted when the export event has no `endDate`; `finished` is
emitted when the same event receives an `endDate`. Notifications are
deduplicated by event identifier and delivered on the main queue. This is an
informational diagnostic signal: Core Data does not expose a reliable upload
percentage or record count through `NSPersistentCloudKitContainer.Event`.

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

When `Graph.watchReportCompletion` is configured for `.cloud`, the same
reconstructed events are also delivered as one non-empty report for each
Persistent History processing cycle. GraphEvo persists the history token after
filtering and merging, before materializing and delivering the report. The
completion is not an acknowledgment: delivery never delays or rewinds the
Persistent History processing token. Materialization failures for surviving objects are
retryable and leave the separate batch-delivery token unchanged; legacy Watch
callbacks retain their existing best-effort behavior.

In production, keep callbacks idempotent and verify behavior across multiple
devices: local and remote notifications may arrive at different times.


Report materialization also checks the persisted structure of surviving event
owners. Unresolved dependencies within the bounded validation scope retain the
batch-delivery token under the same retry policy. This does not establish that
all remote links have arrived. See [Structural validation](../guides/structural-validation.md).


Confirmed remote deletions that lack a reconstructable owner or payload are
included in `GraphWatchReport.unmaterializedDeletions`. Consumers must inspect
that collection even when `events` is empty. These references preserve deletion
evidence and do not block the delivery cursor waiting for removed data.

## Node record identity

Recover the complete CloudKit identity of a main graph node on demand:

```swift
let identity = try graph.cloudRecordID(for: entity)
let identities = try graph.cloudRecordIDs(for: [entity, relationship, action])
```

The receiving Graph and nodes must share a context, and the caller must use its
queue. In a transaction or snapshot, fetch the nodes through the supplied scoped
Graph and call its identity methods. These facades share access to the existing
container; no additional store or container is opened. The APIs do not read
`Node.id`, whose getter can obtain permanent object IDs.

The batch returns one optional per input position, retaining order and duplicates.
Local/fallback mode, unsaved nodes, pending deletion and absent Apple mappings
produce `nil`. Invalid contexts or mismatched ownership throw typed
`GraphCloudRecordIdentityError` values, including in local mode. The wrapper
never saves, requests export, performs network requests or caches an absent
mapping. Call again when the application needs a fresh result.

`CKRecord.ID` includes record and zone identity. It does not contain the
container, Development/Production environment, database scope or account.
Compare identities only within a matching operational context. Identity presence
is not an export acknowledgement, synchronization barrier or graph completeness
check. A pinned read snapshot does not imply pinned CloudKit identity metadata.
GraphEvo adds no deduplication or application selection policy.

Apple documents [single-record identity lookup](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/recordidformanagedobjectid:)
and [batch identity lookup](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/recordidsformanagedobjectids:).
These APIs are available on iOS 13/macOS 10.15 and later, within GraphEvo's
supported deployment targets.

### Verification scope

`GraphCloudRecordIdentityTests` tests all three node families, ordered partial
batches, duplicate inputs, refreshed mappings, unsaved temporary/permanent IDs,
local mode, context/container errors, transaction/snapshot propagation and
preservation of pending changes and saved values. Mapping-positive cases use
an injected reader with a non-mirroring SQLite container: they are simulated,
not evidence of a successful CloudKit export. A separate test calls Apple's
reader on that non-mirrored store and expects no mapping. The local fallback
test covers its effective plain-container behavior, not a real account failure.
The public API is also compiled without `@testable` access.

A real-device acceptance check remains necessary:

1. Use the same CloudKit container, environment, private database and account on
   two devices; create and save a node on the first device.
2. Allow normal synchronization and find that same imported node on the second
   device using application data independent of its local Graph ID.
3. Query its identity on each owning context. If unavailable, retry later via
   application policy without forcing an export from the lookup API.
4. Compare complete `CKRecord.ID` values (record name and zone), and confirm they
   match even when the local Graph IDs differ. Repeat for all three node families.

The automated tests do not claim this two-device acceptance check has run.
