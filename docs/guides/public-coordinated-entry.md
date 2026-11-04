# Coordinated GraphEvo 2 entry

The H01 entry is available on iOS 17/macOS 14 through `import GraphEvo`.
The application owns a `GraphContext()` and passes it to its features. There is
no default global context. Each context owns its manager; process-wide resource
and engine reservations reject overlapping owners across contexts.

## Local creation and reopening

Persist the GraphID in application bootstrap state before first creation. Use an
absolute URL to an exact `.sqlite` file; reopening never creates missing data.

```swift
let context = GraphContext()
let graph = try await context.createGraph(id: graphID, at: storeURL)
// On later launches: context.openGraph(id: graphID, at: storeURL)
let id = graph.makeNodeID()
try await graph.transaction { scope in
    try scope.insert(GraphRecord(id: id, type: "Note", properties: ["title": .string("Example")]))
}
try await graph.close()
```

Returned GraphStore handles use the existing typed models, queries, attachments
and observation APIs. Matching handles in one context share an owner. Closing one
releases only its lease. A failed final native close retains ownership and its
error; opening a second context is not a recovery bypass.

## Account checks without transport

A local-only graph does not query CloudKit. An account-bound graph starts account
observation on local opening, independently of cloud transport. Its handle is
observable but initially isolated until identity verification succeeds.

Use `graph.cloudAccountState` or `graph.observeCloudAccountState()` to adapt local
UI. A transient outage preserves local access only for a currently verified
identity. Logout/switch/restriction preserves data and blocks ordinary access.
Verified same-account return can restore local access without starting transport.
Observation refresh republishes local state; `context.refreshCloudAccounts()`
schedules network/account verification. Clear consumer cached UI on isolation.

The app forwards aggregate scene activity to
`try await context.setForegroundActive(isActive)`. The context starts inactive.
Foreground activation rechecks observed accounts and enables foreground work for
its connected sessions. Pausing/stopping transport does not disable account
observation. Background execution and APNs delivery are not guaranteed.

## Optional private cloud connection

```swift
let configuration = try GraphCloudConnectionConfiguration(
    containerIdentifier: containerIdentifier,
    environment: .development,
    directory: accountSessionDirectory)
let cloud = try await context.connectCloud(using: configuration)
let observation = try await cloud.observeState()
for await state in observation {
    if state == .ready { break }
    // Present verification, temporary unavailability, isolation or failure.
}
observation.cancel()
try await cloud.bindPrivateGraph(graph, zoneName: stableZoneName)
try await context.setForegroundActive(true)
try await cloud.requestSynchronization()
```

The example's readiness loop must handle cancellation/terminal failure in a real
UI rather than waiting indefinitely. Connection creation returns before account
verification finishes. `ready` is session readiness, not graph import, activation
or remote completion. `retry()` schedules a new startup check. Request and
notification operations schedule work, not a synchronization barrier.

Configuration uses explicit container/environment/account-bound directory and
existing default limits (4,096 events; 32 MiB engine document allowance). The
expected environment must match entitlements; it does not change the server
account or environment. No raw identity appears in observable connection failure
state. Operation errors preserve an underlying typed cause for diagnosis.

Matching connection leases in one context reuse the same engines. Final close
awaits transport drainage and keeps the durable session document and asset files.
Other contexts cannot acquire the same database while startup, use or quarantine
retains its reservation. For another account, explicitly select a separate graph,
store and session directory after closing the previous connection. There is no
automatic account partition discovery, merge, deletion or store relabeling.

## Supported v1 conversion

```swift
let request = GraphV1BootstrapRequest(
    sourceURL: stoppedSourceURL, destinationURL: newStoreURL,
    graphID: graphID, operationID: persistedOperationID,
    backupRoot: backupRoot, reason: "Selected v1 conversion")
let result = try await context.openGraph(convertingLocalV1: request)
let receipt = result.conversion.receipt
let graph = try result.opening.get()
```

Stop source writers first and use a distinct destination and complete native
source directory. The library uses native staged conversion with verified backup,
semantic validation and durable UUID mapping. Data stays Data; serialized arrays,
dictionaries and Codable values retain their payloads. Attachment optimization is
consumer-owned. Large ordinary Data may exceed cloud record limits; conversion
does not silently transform it. Perform an explicit, recoverable application
transformation before cloud activation when needed.

Retain the operation UUID and receipt/map. A conversion result proves durable
commit even when `opening` fails or `cleanupFailure` is present. Those failures do
not imply rollback. Resubmit the same request to recover uncertain bootstrap;
ordinary later launches open the converted destination directly. No automatic
incompatible-store migration, total-store size cutoff or custom bounded fallback
is selected by this public entry.

Cloud cutover remains explicit: call `prepareActivation`, `advanceActivation`
and `activationStatus` on a ready connection with a host cutover declaration.
The host selects the authoritative v1 source, reconciles old writes and prevents
returning old writers. Another device uses `openReplica` with the same GraphID
and private zone into an empty or already-marked target; it does not convert its
own v1 copy. Public invitation onboarding remains later work.

See [H01](../design/graphevo-2-public-entry.md) and
[the API reference](../api/public-api.md) for lifecycle and error distinctions.
