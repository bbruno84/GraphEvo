# Public native CloudKit sharing (H02 alpha)

Use an application-owned GraphContext and GraphCloudConnection as described in
[coordinated entry](public-coordinated-entry.md). The sharing surface requires
iOS 17/macOS 14. CKSharingSupported must be true in the host Info.plist, with the
normal CloudKit entitlements, container and expected environment configured.
Production rollout must deploy the GraphEvoGraph record type/fields as well as
existing node/asset/control schemas. Development creation is not Production deployment.

## Owner presentation

Bind and, where required, finish authoritative activation of the owner graph.
On the main actor, prepare and retain the native adapter:

```swift
let presentation = try await connection.prepareSharing(for: graph, title: "Household")
try presentation.present(from: presenter)
// iOS: presenter is a visible UIViewController; macOS: a visible NSView.
```

GraphEvo creates/validates the fixed `graphevo.graph` record, persists share-create
intent, then prepares the zone-wide CKShare. The system UI selects recipients;
no account-identity exchange or custom invitation file is required. Private sharing
and read-only/read-write are supported. CKShare.publicPermission stays none.

Before handing control to Apple's UI, the confirmed share identity and pending
presentation are persisted. After a restart, preparing the same graph reconciles
that state. Confirmed absence of a previously acknowledged share can complete
an interrupted stop; absence after an ambiguous first create still reports
metadataPending and never invents another share.

Retain the adapter until its UI completes and call `close()` to await cleanup or
inspect errors. The adapter retains an independent connection and graph lease;
closing another connection does not abandon its presentation. On macOS, a close
waits for the native sharing service to complete; it cannot programmatically
cancel an out-of-process Apple panel. No native scope/Core Data transaction is
held while waiting for user input. Same-graph sharing edits are reserved, and
pause drainage waits for this admitted presentation; other graphs remain eligible.

## Participant callback and identity discovery

Forward native CKShare.Metadata from the platform callback, including cold-launch
scene connection options. Alternatively pass an Apple sharing URL:

```swift
let join = try await connection.acceptInvitation(metadata)
let state = try await join.state
// Wait/observe/retry until state.phase is ready and graphID is present.
let graph = try await connection.openReplica(for: join, at: selectedSQLiteURL)
```

The returned join represents durable intent, not guaranteed acceptance success.
Observe `join.observeState()`; `retry()` resumes its exact native operation.
Acceptance may have succeeded before network failure. The same share is inspected
on retry rather than blindly accepted again. Initial metadata failure throws
before an intent exists; failures after intent publication remain queryable on
its handle. Exceptions from later explicit retry retain the durable phase.

After native acceptance the library directly fetches the graph descriptor from
the exact shared zone. GraphID is public routing identity, not an access credential.
Even an empty graph has a descriptor. No node scan, property decoding, asset read
or engine checkpoint advance is needed to discover it. Missing metadata remains
pending; a wrong/unsupported descriptor is an error, never a new graph identity.

Choose the exact absent SQLite URL after discovery. Retrying an interrupted
opening may reuse only its matching native join marker/store and generation.
The marker/account claim is committed in the initial creation transaction, so
recovery can recognize a stopped replica before membership publication. Existing
unrelated stores are refused and preserved. Application access stays blocked
until account and membership checks allow it. An opened replica can still be
empty while import proceeds: join completion is not synchronization completion.

## Relaunch, cancellation and access loss

Persist host workspace selection before opening. Reconnect to the same session
directory and use `pendingInvitations()` to recover join handles. Joined entries
are retained so interrupted host bookkeeping can recover the existing replica.
For an existing membership, `registerSharedReplica(id:at:)` supplies its current
runtime path for control/purge recovery; it does not create a missing file or
promise access. Then use the ordinary coordinated local opener.

`discardInvitation` cancels an invitation before a replica exists. Once joined,
use `leaveSharedGraph`: it destroys the local replica, owned attachments and
unpublished work, preserving a remote leave command if offline. Observe membership
status to distinguish local removal from remote completion. Host UI must confirm
this destructive action before calling it. Owner `stopSharing` preserves owner
records. Confirmed access loss uses the same protected T08 purge; network failure,
read-only downgrade and account change alone never authorize deletion.

Use `participants`, `setPermission`, `removeParticipant`, `sharingStatus`,
`observeSharing` and `refreshSharing` for lifecycle presentation. Participant IDs
come from native snapshots and may be absent. Status/observations do not retain a
graph handle or certify live server authorization. Observations finish when their
connection closes. Clear detached cached application values on access loss.

A newly joined replica may contain only account/membership metadata before its
first import. History initialization accepts that complete metadata-first cut,
retains a native token and emits no application writes for bookkeeping. Existing
joined empty replicas can resume without another invitation or a replacement
store. This does not admit a missing or purged initial history.

## Alpha compatibility

The cloud descriptor uses format 1 with canonical UUID `graphID` and numeric
`format`. Optional future fields are tolerated within a 16 KiB record-archive
limit; unsupported formats fail. Descriptor edits cannot rebind an established
replica or authorize purge. MF10 activation metadata remains independent.
Private same-account recovery validates and excludes the descriptor and native
zone-wide CKShare from application rows and seed digests; their presence does
not create outgoing application changes.

The session document is format 9. Format 8 requires explicit configuration
`allowsSessionUpgradeFromV8: true`; validation and owned-asset checks precede an
atomic conversion preserving engine bytes, bindings, pending work and receipts.
Default false refuses format 8 unchanged. Other historical formats are refused.
An older runtime cannot consume format 9 or the new cloud control record: stop
old participating writers before adopting this alpha protocol. This is a host
cutover prerequisite, not a distributed old-client fence. Existing owner zones
receive a descriptor only through explicit native sharing preparation; there is
no automatic participant adoption of an old descriptor-less zone.

Public API/injected tests and physical Apple UI/two-account acceptance are separate
evidence. No background delivery, production cutover or beta readiness is implied.

## Workspace retirement after participant removal

After native purge and durable remote intent settlement, an idle context releases
its graph claim so a distinct GraphContext can own a fresh replica of the same
graph. The retired context remains blocked; its old handles are not reusable.
A pending remote leave retains the claim, and failed native detachment retains
its quarantined owner. Consumers switching workspace close the prior leases and
create a new explicit GraphContext after settling pending removal commands.
This does not change invitation acceptance or certify content synchronization.
