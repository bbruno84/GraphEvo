# GraphEvo 2 — Persistent History discovery and pending publication

Status: package-only implementation on `codex/v2-history-pending`, based directly
on reviewed #107. No CloudKit engine, public opener or background worker is
activated. The retained PH01 experiment is evidence, not merged implementation.
The native model remains [S03](graphevo-2-history-schema.md).

## Resource and state ownership

One GraphCoordinator owns one GraphSyncSession and one exclusive writable SQLite
store. Consumer leases share discovery and one active upload attempt. Creating a
coordinated store reserves `GraphEvo.v2.historySyncGraphID` in native store metadata.
Reopening requires that role and the exact graph. Unmarked older-alpha S03 stores
are refused by this path; they remain readable through their compatible local
APIs. There is no implicit adoption or conversion. The role reservation can
survive failed initial creation; it is neither queue progress nor an effect receipt.

Before native loading, mirrored single/pair openings reject a marked resource,
including a marked shared secondary. Generic local creation cannot add another
graph to it. Compatible local/read-only reading remains available. These guards
prevent the old backend exporting local checkpoint metadata after the coordinator
closes. They do not constitute cross-process locking or a supported external writer.

The hidden graph root holds one reserved `__graphevo_v2.syncCheckpoint` Data value:
local codec format, graph/store UUID binding, session epoch, secure history token,
transaction number and coalesced pending identities/operations/generations. This
is library bookkeeping, not consumer data versioning or a format registry.
Pending publication and token advancement share one runtime-owned Core Data save.
Native Data may use external storage; backups must retain the whole directory.
No sidecar queue or per-consumer-mutation interception is introduced.

## Discovery and failure behavior

Demand-driven collection reads the complete retained history cut after its token,
scoped to the sole native store. Authors are `GraphEvo.v2.local`,
`GraphEvo.v2.import` and `GraphEvo.v2.syncMetadata`. Metadata transactions are
excluded at fetch, avoiding an endless checkpoint-write/discovery loop. Imported
changes remain observable but do not create outgoing work. Unknown/nil authors,
unavailable history, invalid state and unresolved identities fail visibly without
resetting the cursor or clearing pending work. First activation requires retained
history starting at transaction 1; there is no inferred baseline after pruning.

S03 node tombstones supply graph/node identity. Live detail rows resolve their
owner; removed details use the complete cut and same-deletion-transaction owner
kind/relationship groups. This conservatively includes potentially affected
owners, including inverse updates. It is not a minimal semantic diff. Missing
correlation fails rather than dropping a change. Later transactions supersede
earlier pending operations; deletion wins within a transaction. Recreation of
the same logical identity supersedes an older deletion.

Explicit transaction/change/pending limits refuse the operation without partial
checkpoint publication. The first implementation fetches a whole cut before
count validation: these limits are not SQL-I/O, total memory/time or attachment
size bounds. There is no history pruning, pagination or automatic reset policy.

## Immutable attempts and controlled imports

`prepareSyncBatch` reconciles history and materializes at most the requested
record count under the local writer boundary. Save items contain detached current
GraphRecords; delete items contain identity/kind/generation only. Payload decode
or missing-save-body errors prevent publication. One active immutable attempt is
shared by the coordinator; concurrent sync commands report busy. Even an empty
batch must be acknowledged or abandoned.

Acknowledgement accepts the batch ID and successful identity subset, uses the
stored sent generations, and reconciles newly committed history before removing
exact matching pending entries. An older success cannot clear a newer edit.
Partial success finishes the attempt while unsuccessful records remain pending.
Abandonment drops only the in-memory attempt. Reopening retains pending work and
rejects old receipts. Retirement clears retained snapshots and prevents an
in-flight prepare from returning a batch after owner shutdown; admitted native
work still drains through the runtime.

The package-only incoming seam currently applies patches to existing records.
It reconciles outstanding local history first, rejects overlap with pending
identities (including inverse effects), and saves accepted patches with the
import author. Rejection rolls back both patch edits and checkpoint edits.
This is not full incoming insertion/deletion, conflict resolution or durable inbox
support. Native contexts, managed objects and history tokens never escape the
adapter; only secure token Data and Sendable values cross boundaries.

## Validation and open gates

The complete local suite passes 595 tests (331 legacy, 170 store, 71 runtime,
23 model). The selected iOS Simulator 26.5 run passes 35 test functions / 44
expanded cases: pending discovery, coordinator lifecycle and resource groups.
Seventeen new functions cover stale/partial acknowledgements, reopen/replay,
rollback before save, no metadata self-loop, imported observation/exclusion,
pending-import refusal, detail/topology/file changes and cascades, recreation,
limits, bad state/token/store binding, pruned history, unknown authors, independent
graph progress, retirement during prepare and persistent role guards.

Injected failure after native edits but before runtime save proves rollback and
replay, not a real process kill or power-loss boundary. Physical-device/custom
cloud delivery, actual crash ordering, history retention/rebaseline, resource
measurements, full incoming operations, account/conflict policy, engine state,
assets, pause/migration and cross-process coordination remain release gates.
See the [post-alpha checklist](graphevo-2-post-alpha-checklist.md) and
[transition sequence](graphevo-2-custom-sync-transition.md).
