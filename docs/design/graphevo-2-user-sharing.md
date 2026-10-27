# GraphEvo 2 — A5 user sharing

Status: implementation candidate. Read with the [specification](graphevo-2-specification.md),
[A4 membership](graphevo-2-graph-separation.md) and the
[retained hardware report](results/a5-native-sharing-2026-10-27.md).
Native model hashes remain unchanged; this is still an alpha API and protocol.

## One owner for both physical stores

```swift
let database = try await GraphDatabase.openMirrored(
    privateStoreAt: privateURL,
    sharedStoreAt: sharedURL,
    containerIdentifier: containerIdentifier)
```

The runtime resolves both explicit SQLite URLs, checks that they are different
resources and reserves every canonical key before loading. One native
`NSPersistentCloudKitContainer` owns the private/shared descriptions with the
same container identifier. Independent openers cannot overlap either file,
including swapped roles, aliases, a different primary file with the same shared
file, or a legacy/native owner. Both inode identities and topology participate
in compatibility checks; secondary keys remain fixed after resolution.

Opening waits for every native load callback. An error after partial loading
detaches all loaded stores before releasing claims. If detachment fails, the
failed native owner and both claims remain quarantined. Final close drains
admitted work before removing stores. All graph handles keep independent leases.
No operation claims distributed locking or coordination with another process.

## Local readiness and native setup

A load callback establishes local store readiness. `cloudSetupStatus()` reports
completed public native setup events for the owner's stores, using an observer
installed before loading. It does not certify import, object export, current
account authorization or graph completeness. Native setup failures retain only
a domain/code diagnostic. Successful setup and later metadata availability are
still separate observations.

Share creation records its durable request only after its read-only metadata
preflight succeeds. `metadataUnavailable(underlying:)` before that request is
safe to retry as a preflight. An existing request with missing native metadata
remains `preparationPending`, and never creates another zone. Do not infer
absence from missing share mappings or rewrite an old request heuristically.

Native share creation still uses a callback to start work on the source
context's queue without escaping its managed objects. Share persistence,
participant lookup, acceptance and leaving use Apple's imported async APIs.
Native operations retain admission and the local writer gate through completion;
queued cancellation prevents invocation, while a started native operation awaits
its actual result. Cloud work and local changes do not form one atomic rollback.

## Invitations and access

`sharingIdentity()` produces a sensitive opaque recipient value. The host binds
its transfer to the intended account/container. `invite(_:to:permission:)`
requires a prepared owner-private boundary, resolves only that recipient and
persists an owner-only private invitation. Its `GraphInvitation` value is a
capability: protect transport and never log it. Codable input rejects empty
recipient identifiers and non-HTTPS invitation URLs before native lookup.
Acceptance verifies the current recipient and native container identifier,
accepts only pending metadata and does not replay an already accepted invitation.
Acceptance completion does not imply that the graph has been imported.

`sharingStatus(for:)` distinguishes store scope, current-user role, permission,
acceptance, metadata availability and pending structural work. No global
synchronized Boolean is provided. A missing locally imported graph does not
establish permanent denial. A current local snapshot is not authorization proof.

The owner can `setPermission(_:for:in:)` or `revoke(_:from:)` for the named
participant. `leaveGraph(_:)` accepts only an accepted private-user participant
in the explicit shared store and purges that exact native share zone. It cannot
purge an owner-private store. Pending originating-device structural intent must
be resolved before leaving. Access reduction and status lookup use the root's
identity/layout rather than requiring application payloads to decode successfully;
grants and share preparation retain complete graph validation.

Library writes require accepted read/write metadata and positive native update
advice. Deletion also honors native delete advice. These are local checks;
server permission changes can race a save. The library's rejection of a known
read-only write is distinct from testing server enforcement against arbitrary
native writes. Cached data/account-change policy remains an explicit beta topic.

## Participant edits and native assignment

Ordinary scoped transactions can edit existing detail values, remove details,
change endpoints among existing entities, or delete existing members. Creating
new shared nodes, properties, tags or groups through that synchronous scope
throws `sharedInsertionRequiresPreparation` before editing. A scope cannot
suspend for a native share operation.

Use awaited operations outside a transaction body:

```swift
let nodeID = try await graph.insertShared(applicationModel)
let ids = try await graph.insertShared(detachedRecords)
let record = try await graph.patchShared(
    GraphRecordPatch(id: nodeID,
                     properties: ["nickname": .set("Ada".graphValue)],
                     addingTags: ["active"]))
```

`insertShared` validates identities, references and all values before reserving
local intent. It builds unconnected node components through the public facades,
assigns every new node/property/tag/group row to the shared persistent store,
then invokes one native existing-share assignment for the whole batch. It checks
all returned local mappings against the root's share zone before linking the
members to their live graph and clearing staging markers in a local transaction.
Known staged IDs also participate in duplicate checks.

`patchShared` stages an unlinked facade of the same native kind with the required
detail rows. After assignment it transfers only missing property/tag/group rows
to the existing target through a context-confined Node adapter, applies only the
requested patch, and deletes the staging facade. Existing unknown fields and the
target's creation date remain intact. The returned detached `GraphRecord` can be
decoded explicitly by the application; this low-level operation does not promise
application-model validation before committing. Ordinary typed patch retains its
existing pre-mutation decoding contract for supported synchronous edits.

Reserved metadata names are rejected for both property sets and removals. An
attempt to remove graph identity/format metadata cannot damage the graph even
when the caller catches the error inside its transaction.

## Durable local intent and recovery

Structural work is recorded beside its originating shared store:

```text
<shared-store>.graphevo-operations/<graph-UUID>/insertion.json
```

The journal uses atomic file replacement, restrictive permissions and iOS file
protection. It contains versioned value envelopes and application identities;
it does not persist CloudKit mapping guesses or invitation capabilities. Version
1 records insertion intent; version 2 records a patch delta and staging payload.
It is a local recovery record, not a shared-root distributed lock. Different
participants do not overwrite one another's root journal field. One pending
operation blocks additional local writes to that graph; other processes/devices
remain external writers.

Staged nodes carry an operation UUID and stay outside application snapshots.
They must be unanchored: an existing anchored member cannot be silently hidden
by attaching a staging marker. Pending status also detects imported staging
objects from another device. Incomplete imports can therefore report pending
or integrity errors while later native changes arrive.

`pendingSharedOperations()` returns payload-free local intent descriptors and
remains readable while the native writer awaits its callback, or after access
to the graph disappears. `recoverSharedOperation()` never replays share
assignment. It finalizes only when the recorded objects and their mappings are
present in the intended boundary. Missing mapping remains pending. An interrupted
post-commit cleanup is idempotent when current graph values satisfy the recorded
intent. Divergent/ambiguous state remains visible for reconciliation; it is not
silently overwritten. A journal-cleanup failure after a successful local commit
does not turn that committed mutation into a failed insertion.

`MigrationBackupManager` now includes the optional operation-ledger directory
with the SQLite files. Back up/restore both group resources and their ledgers
from a quiescent local source; closing is not a cloud synchronization barrier.
V1 source conversion and coordinated cloud cutover remain mandatory separate
work. This increment does not automatically migrate a legacy cloud layout.

## Validation and remaining gates

Local checks cover group overlap, aliases/replacement, partial-load cleanup and
quarantine, journal preservation/backup, value/delta round trips and metadata
protection. Physical checks use actual GraphEvo Entity/Relationship/Action and
detail rows on the authorized iPad/XR accounts; injected fixtures do not count
as CloudKit evidence. See the [probe procedure](../../Experiments/A5NativeProbe/README.md).
The Debug-only recovery control pauses after real native assignment; its
internal seam is absent from Release builds. Normal stages use public APIs.

Still open before stable release: comprehensive crash/partial-error combinations,
simultaneous structural writes and conflicting property additions, account
changes/access-cache policy, old-cloud-layout cutover and returning old devices,
zone quotas, larger performance envelopes and native sharing UI adapters. The
host controls presentation and invitation transport. Current polling probes do
not certify live observation or selective graph download.
