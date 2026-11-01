# MF04a — logical graph emptying

Status: implementation candidate on `codex/v2-migration-workspace`, directly
based on MF03/#122 (`5b22750`) for integration into `codex/graphevo-2` through #123.
This supplies graph emptying, not the MF04 workspace or migration executor.

## API and local contract

```swift
@discardableResult
func GraphStore.removeAll(maximumRecords: Int = 10_000) async throws -> Int

@discardableResult
func GraphMutation.removeAll(maximumRecords: Int = 10_000) throws -> Int
```

The store operation owns one normal local transaction. The mutation operation
participates in its enclosing transaction, allowing emptying and repopulation in
one save. The returned count is the number of selected logical application records,
including attachments. Emptying an empty writable graph returns zero without a
new data transaction. Invalid/nonpositive limits throw `GraphRemovalError.invalidLimit`;
a larger selected inventory throws `recordLimitExceeded` before destructive edits.

The record limit is not a bound on total native resource inventory, payload memory,
SQL I/O, elapsed time or remote work. Existing identity/tombstone/PH transport
limits remain authoritative; the operation does not silently increase them.

Build one scoped inventory and preflight all selected records before deletion.
Validate structure/encoded values, attachment ownership/content and native sharing
permissions. Remove all application Entities, Relationships, Actions, their
properties/tags/groups and owned attachment records. Keep GraphID, the catalog,
hidden membership controls, conflict policy and sync/transport metadata.

The historical ManagedEntity deletion path also deletes connected Actions.
Explicitly detach the retained membership control and application-action inverses
before deleting entities; never destroy/recreate the hidden graph controls.
Cross-graph dependencies are refused, not followed into another graph. Other
graphs in a common native resource remain intact.

Use Node facades within the existing runtime writer gate. No SQL batch delete,
store destruction, independent context save or CloudKit operation occurs inside
the mutation. Pre-save cancellation/failure rolls back; after successful save,
return the committed outcome. Runtime read-only, local-write reservations,
participant permissions, retired/closed handles and pending native-operation
fences are unchanged. Observations receive their normal post-commit invalidation.
Exported files/backups remain caller-owned; physical external-storage reclamation
is Core Data work, not a synchronous secure-erasure promise.

## Persistent History and cloud

History-sync coordinators record all removed logical IDs under the existing
local author and retain their deletion evidence. Reusing a deleted ID is refused
under existing delete-wins rules, including reuse in the same transaction. Fresh
IDs can repopulate the empty graph. Other local layouts retain their existing
single-record deletion identity policy; no implicit layout/protocol upgrade is
introduced by this API.

The existing PH reducer discovers tombstones and emits ordinary pending deletes.
Do not reset its token, acknowledgement epoch, deleted-ID set or frozen batch.
A late success for an older save must not recreate a record or acknowledge its
newer pending delete. Partial cloud success removes only acknowledged generations;
failed deletes remain pending and survive reopen. Imports of remote deletions
must not feed uploads.

The existing ContextManager/CKSyncEngine path sends per-record deletes in its
normal bounded batches (default 100). Preserve zone, CKShare, graph ledger and
other graphs. Read-write participants use existing permission admission;
read-only participants cannot empty their replica as an application mutation.
Revocation/leave remains the distinct T08 lifecycle.

Success certifies the local commit, not cloud convergence. The operation removes
the records currently in the local graph: it neither discovers unknown cloud
records nor prevents concurrent remote insertions. It is not a global atomic
cloud reset or distributed lock. A migration workspace remains isolated until
its later publication to the protected original.

S03, application cloud-node/asset formats and session format 6 are unchanged.
No new queue, engine, persistent format or migration registry is introduced.

## Validation and workflow

Cover all primitive kinds and a 2-MiB file, root/catalog/control preservation,
standalone and multi-graph current/native layouts, fresh-ID repopulation, raw PH
delete discovery, rollback, pre-save cancellation, limits, corruption, local
reservations, read-only stores/participants and observed-query refresh. Exercise
more than 100 records, partial delete failures/restart and late frozen-save success
through the existing transport. Keep injected transport evidence distinct from
actual CloudKit/device tests. Use fresh zones without container reset; keep the
owner alive through independent participant observation and verify exact native
inventories, sharing and ledger continuity.

Implementation and local/device checks precede review/corrections, then any
requested full CI checkpoint and authorized merge. Laboratories remain local.
The MF04 workspace, seal/recovery and post-validation backup/publication flow
remain design-only in the separate contract.
