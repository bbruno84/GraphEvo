# MF01 — local reservations and verified graph backups

Status: package-only candidate on `codex/v2-migration-foundations`, based on
reviewed T08 #120. This implements the first two prerequisites of the
[migration roadmap](graphevo-2-migration-foundations.md). No public graph opener,
consumer migration executor, shared ledger, v1 conversion or in-place cloud
restoration is activated. S03 and cloud/session formats are unchanged.

## Admission and lifetime

`GraphContextManager.suspendLocalWrites(for:)` returns an owned reservation.
New transactions and native writers on that resource fail immediately; ordinary
reads remain available. Already admitted writers, including queued writers, finish
before acquisition returns. Restrictions cover every alias sharing the native
owner. Separate graphs progress independently. Release is awaited/idempotent;
deinitialization schedules release. Cancellation while acquiring removes only
that request. Retained leases prevent a close/reopen gap and late releases cannot
unlock a new runtime generation.
Participant permission getters use read admission, so aliases can reopen and
nest write reservations without accidentally requiring a write. Confirmed T08
removal also sets a terminal runtime block: stale metadata reads or reservation
release cannot reenable the retiring generation, even while its marker write
is deferred by maintenance.
Snapshot admission also respects the data-access fence: an unverified or removed
participant cannot obtain a backup through privileged maintenance admission.

The runtime additionally has an exclusive maintenance reservation. It rejects
new reads/writes, drains admitted readers/writers and permits only the owned
snapshot operation. A second maintenance acquisition reports busy. Maintenance
release invalidates observations so recoverable busy reads can refresh. Neither
mode is a cloud pause, a consumer write queue or a cross-process writer fence.
Uncoordinated external/legacy writers must be stopped; app/widget, protected-data
and suspension acceptance remains open. These operations are for the application
owner; no extension-side migration or new writable-widget route is introduced.

New public error cases are `GraphStoreError.writesSuspended` and
`GraphStoreError.resourceReserved`. Automatic sync and sharing control treat
these temporary admission errors as busy with a one-second retry rather than
permanently blocking the graph.

## Central backup service

Each ContextManager owns a `GraphBackupManager`. Its package surface includes:

- `createBackup(for:in:reason:artifacts:)` on ContextManager;
- `backups.list(in:)`, `verify(at:)`, `restore(at:to:)`, `remove(at:)`;
- `retain(at:owner:)`, `retentionOwners(at:)`, `releaseRetention(at:owner:)`;
- `discardIncomplete(in:)` for owned interrupted stages.

The consumer supplies an already accessible local backup directory, an optional
free-text reason (nonempty when supplied, at most 4096 UTF-8 bytes), and optional
immutable local journal/artifact snapshots. Names are single relative components;
the `__graphevo_` namespace is reserved. Provider coordination/exports are separate
from this local service. The v1 `MigrationBackupManager` remains unchanged; it
does not gain attachment completeness from this increment.

ContextManager retains the graph, acquires a graph-scoped cloud-pause hold, then
an exclusive local maintenance reservation. Pause holds compose: cleanup never
resumes a manual pause requested before/during backup or another hold. Only
backup-owned restrictions are released on success, error or cancellation.

The native coordinator [copies the store using `replacePersistentStore`](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/replacepersistentstore(at:destinationoptions:withpersistentstorefrom:sourceoptions:oftype:)).
The service inventories the resulting bundle, including native external content,
without deriving private Core Data storage paths. A 2 MiB attachment fixture checks
actual content recovery and preserved PH, not just successful file copying.

## Bundle and verification

Format 1 bundles contain `payload/Graph.sqlite` and its complete native companion
resources, optional `artifacts/`, a manifest and an operation ownership marker.
The manifest stores backup/graph/native-store identities, schema, creation date,
reason, relative inventory, byte sizes and SHA-256 values. Library manifests and
bindings generate no persisted sandbox paths; caller artifacts remain opaque.
Whole unretained bundles can move or be renamed.
These MF01 bundles are currently uncompressed directories. The
[next backup increment](graphevo-2-migration-foundations.md#compressed-local-packages-and-portability--next-backup-increment)
will add compressed local payloads, inexpensive manifest discovery and async
export/import; portable cross-user import is not a current capability.

New bundles are built in a hidden owned staging directory and become visible by
same-parent directory publication only after verification. Checks reject missing,
extra, altered, symbolic/hard-linked or unsafe paths and unsupported metadata.
Native reopen/graph validation runs on a disposable copy, because even read-only
SQLite access may create/change sidecars. Attachment bodies/digests are checked.
The original backup is hashed again afterward. Failed native detachment retains
the disposable validation files/claims rather than deleting an attached store.

Defaults bound the inventory to 100,000 entries, 64 GiB of file bytes, depth 64 and
a 4 MiB manifest. These are verification limits, not peak-memory, copy-time or
temporary-disk-space guarantees. Native graph validation still has its existing
whole-inventory costs; production-scale/media measurements remain open.

Registered active cloud sessions contribute graph-specific identity, binding,
membership, retained inbox and receipt evidence with a capture timestamp. Other
graphs and opaque engine serialization are excluded. This is recovery evidence,
not an atomic SQLite/JSON checkpoint or an instruction to restore a session.
Unregistered journal files must be supplied as immutable artifacts; they cannot
be discovered from arbitrary consumer paths. Future migration journal capture
and commit reconciliation remain executor work.

## Retention, interruption and restoration

Finite root file locks exclude competing service/process file operations. No
retention lock stays open for the migration lifetime. Retention owners are
recorded atomically as bounded relative-root metadata, survive a crash and are
visible to another manager. A migration can use its known operation UUID to
recover/release retention. The convenience reservation and its deinitialization
perform best-effort release; I/O or lock contention leaves the backup
conservatively retained for explicit throwing `releaseRetention` recovery.
Consumers must not move/delete a retained artifact outside the service.

Incomplete owned stages can be discarded after restart under the root lock.
Unknown ownership/corrupt markers are refused; committed backups and unrelated
consumer files are preserved. This is process-interruption recovery, not a
power-loss/fsync or secure-erasure certificate.

Restore verifies and materializes the whole bundle into a **new empty local
directory**. Existing destinations are refused, including dangling links. Its
returned store is not registered, activated or bound to CloudKit automatically.
Restoration keeps the source backup/original intact and can be retried after
discarding an interrupted stage. It does not replace a live graph, restore an
old shared session/ledger or undo published changes in CloudKit. Those operations
require the migration executor's admission/reconciliation protocol.

If a failure occurs after directory publication but during source cleanup, a
valid backup can already exist; listing/verification is the recovery evidence.
No retry overwrites an existing bundle or replays a consumer transformation.

## Validation and remaining gates

Deterministic coverage exercises writer/reader drainage, queued writes, aliases,
overlapping reservations, cancellation, reopen generation and unrelated progress;
complete attachment/PH restore, reasons, corruption, missing native content,
symlinks/traversal, occupied destinations, moved bundles, interrupted-stage
cleanup, durable retention, graph-only cloud evidence and pause ownership.
See the [MF01 local results](results/local-maintenance-2026-11-01.md) for the
verified scope and remaining acceptance limits.

Keep local/simulator results distinct from physical/cloud acceptance. No remote
CI is requested before review. The selected workflow remains one combined
checkpoint with #120, then authorized integration into `codex/graphevo-2`.
