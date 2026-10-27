# GraphEvo 2 — A4 graph separation

Status: owner-private implementation candidate, 2026-10-27. Read with the
[specification](graphevo-2-specification.md), [typed store](graphevo-2-typed-store.md)
and [hardware evidence](results/a4-native-membership-2026-10-27.md).

## Catalog and lifetime

`GraphDatabase` owns one runtime lease on a physical resource. It creates and
lists logical graphs and opens independent `GraphStore` leases. Closing the
catalog does not invalidate existing graph handles. All writes, including
native share operations, use the same resource owner's writer gate. Final close
waits for admitted native callbacks before detaching the store.

```swift
let database = try await GraphDatabase.open(at: databaseURL)
let first = try await database.createGraph()
let second = try await database.createGraph()
let ids = try await database.graphIDs()
try await database.close()
// first and second retain their own resource leases.
try await first.close()
try await second.close()
```

`openGraph` reports `missingGraph` when its ID is not currently present locally.
An imported root can appear before its complete membership. Catalog presence
and successful native opening do not certify graph integrity or import completion.
Typed reads validate membership and requested values, reporting incomplete or
invalid state instead of returning partially decoded models. There is no global
`isSynced` flag or inferred import-completion barrier.

## Candidate layout a4.1

The native model and its hashes remain unchanged. Persistent graph/node UUIDs
and the A3 value envelope remain unchanged. Logical membership uses existing
facades behind the typed adapter:

- Each graph has a hidden `__graphevo_v2.graph` Entity root.
- A hidden `__graphevo_v2.members` Action links the root as subject to every
  application Entity as object, including disconnected entities.
- Every application Action also includes the hidden root as a native subject.
  Typed snapshots exclude it, preserving valid empty application actions.
- A Relationship with both optional endpoints absent uses the root as a native
  subject sentinel. Typed snapshots expose both endpoints as absent. Edges with
  application endpoints already reach their graph's anchored entities.
- Existing property/tag/group relationships connect owned detail rows to their
  node. They are included in native membership inspection.

These links connect the entire native graph without requiring applications to
invent edges or expose a synthetic root. Typed edits maintain the links and
reject foreign graph IDs. The membership validator checks the exact Entity
membership set, root anchoring and empty-edge sentinels. Before native sharing
and inspection, all selected application records are also decoded and resolved.
Missing roots/members and invalid metadata fail visibly; this is an integrity
check on current local state, not a claim that no further import can arrive.

This is an alpha candidate, not a frozen schema. It adds per-operation indexing
and membership work; A7 must measure and improve query costs. Shared-store writes
and native assignment of new participant details require A5 verification rather
than an assumption that the owner-private insertion path generalizes.

## Native personal mirroring

`GraphDatabase.openMirrored(at:containerIdentifier:)` explicitly selects one
owner-private `NSPersistentCloudKitContainer` resource with history and remote
change notifications enabled. Entitlements, account availability and container
configuration belong to the host application. A local and a cloud configuration
cannot simultaneously own the same physical resource. The explicit cloud factory
has no silent local fallback. Native asynchronous setup/import errors can still
occur after the local store has opened; opening is not cloud readiness.

`prepareMirroring(for:)` validates the graph, durably records a request on its
root, then uses the public container `share(_:to:completion:)` API with a nil
share. The resulting share must be owner-only with public permission `.none`.
It then awaits `persistUpdatedShare`'s completion. No invitation is sent.

The durable request prevents a retry with unavailable native mapping from
creating another share. Existing mappings are reused. If the request exists but
its native share mapping is unavailable, `preparationPending` is returned.
A callback failure does not roll back an already committed request. Automatic
recovery of an ambiguous native request, including failure before assignment,
is deliberately still pending; retaining evidence and retrying a read must not
silently create another zone.

`GraphMirrorBoundary` exposes graph ID, opaque zone name and share record name
as transferable diagnostic values. This operation establishes a personal native
boundary; it does not certify object export or another device's data.
`inspectMirroring(for:)` observes the current root share mapping and every owned
native row's record mapping, returning native count, pending mapping count and
unexpected-zone count. Missing mappings remain pending. No save, permanent-ID
allocation or export request is performed by inspection. A zero mismatch count
with pending mappings is not complete membership evidence. Even all mappings
present only describes local metadata; compare exact application data on an
independent replica for recovery evidence.

Share creation is initiated on the root context queue through the native
callback API so the managed object never leaves that queue. Its callback is
bridged inside the admitted operation. Share persistence uses Apple's imported
async API directly. These operations return transferable values; application
transaction bodies remain synchronous and context-confined. Queued cancellation
prevents invocation; after a native operation starts, its actual completion is
awaited before releasing admission. Cloud failure/cancellation is not modeled as
an atomic rollback of local and remote changes.

Apple's [sharing guide](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
describes zone sharing and connected object graph membership. The library uses
those public container APIs; it does not write CloudKit records or implement a
custom sync engine. This does not promise selective graph downloading.

## Explicit local upgrade

A3 standalone factories continue to use `a3.1`. `GraphDatabase.open` does not
silently reinterpret an A3/v1 layout. For a closed, quiescent local A3 store,
`upgradeLocalA3Store(at:backupRoot:)` validates the old layout, backs up SQLite
and present sidecars, adds native membership and changes the root protocol to
`a4.1` in one local transaction. It preserves graph/node IDs, values and native
model hashes. Repetition on a4.1 is idempotent. A backup failure leaves a3.1
usable. A missing source is rejected without creating a new store.

This is an explicit local alpha protocol upgrade, not a cloud cutover or a
native model migration. V1 data migration remains mandatory and the coordinated
old-cloud-layout transition remains a separate A4/A5 workstream. Unsupported
legacy value codecs do not become supported through this upgrade.

## Scope and next boundary

This increment implements the personal owner-private path. A4's two-graph cloud
boundary can be tested with that one private store. Add the private/shared store
pair together with A5 participant routing and acceptance: the shared store has
no participant operation in this increment, and an untested second resource
must not imply working ownership exclusion or shared insertion. Native
multi-resource reservations, shared-store assignment of every detail row,
permissions, invite/leave/revocation and ambiguous-operation recovery are still
required before the user-sharing exit. Account changes and zone quotas also
remain release validation requirements.
