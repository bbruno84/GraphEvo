# MF05 — protected original-store publication

Status: implementation on `codex/v2-migration-publication`, based on MF04c/#125.
This package-only increment completes the local publication boundary, not the
consumer's migration policy, public executor or mandatory v1 conversion.

## Ordering and ownership

`GraphContextManager.publishMigrationWorkspace(_:backupsIn:reason:limits:)`
seals/validates the working graph, validates original freshness and the pending
sync allowance, reads only the selected final primitives under explicit limits,
then creates and verifies a complete original `.geb` backup. Preparation and
failed validation create no backup. The caller may supply the recorded reason.

Publication uses one drained original-store maintenance transaction. It applies
final records and deletes through normal scoped Node operations, preserves
identities, creation dates and working modification dates, validates structure
and files, and commits a native receipt with all application effects. The
original SQLite, PH, queue/checkpoint, frozen transport and control metadata are
retained. Working PH is discovery evidence; it is never transplanted. No graph
diff or consumer-body replay occurs. Surviving endpoints are applied before
cascading deletions; effects outside the sealed manifest cause rollback.

The capability is restricted to the exact history-sync source graph and an
exclusive drained reservation. It cannot publish through a workspace capability,
native mirrored store, participant store or another manager's reservations.
Commands are serialized per graph. Before-save cancellation rolls back; after
save, return the committed result. Close waits for an admitted publication.
Success releases only the workspace's original holds, leaving independent
manual reservations intact. The working graph stays sealed and readable.

## Recovery and backup retention

The workspace stores an immutable, bounded `publication.json` intent (format 1,
16 KiB maximum), atomically renamed into place without overwriting. It binds
workspace/graph/seal digest, selected count, backup UUID and reason; never paths.
Retries reuse the same verified backup and refuse corrupt or mismatched evidence.
Its reason is fixed after intent creation. Current backup/store URLs are supplied
again after restart. This is atomic visibility, not a power-loss/fsync guarantee.

The original keeps the latest native receipt (format 1, maximum 4096 bytes),
committed in the same transaction as the data. Reopening checks this proof before
requiring original freshness. A lost result can therefore be recovered without
reapplying the transformation, overwriting subsequent edits or taking another
backup. A later migration supersedes this single receipt: recovery of older
workspaces may explicitly refuse stale evidence. No unbounded receipt history
or claim of indefinite recovery is introduced.

The verified backup is durably pinned to the workspace before publication. A
failure keeps it protected across restart. Successful commit releases that pin;
release failure is reported as `backupRetentionPending`, not a failed commit.
The result's `backupURL` uses the supplied current root and is not persisted.
Abandoned failed workspaces can leave retained backups; explicit inspection and
release use the existing central backup service. Automatic orphan collection and
production retention costs remain acceptance work.

## Bounds and truthful outcomes

One atomic publication defaults to 10,000 selected records and 32 MiB weighted
logical payload. Record allowance cannot exceed 10,000; payload hard maximum is
512 MiB. Payload charging includes typed content, file bytes, names, endpoints,
tags/groups and fixed primitive overhead; it is not a total heap, disk, native
I/O or network bound. Preflight projects existing pending IDs plus manifest IDs
against the normal 10,000-item sync limit. The final native transaction, including
receipt metadata, must fit normal 100,000-change PH discovery. Refusals roll back
without raising downstream limits. Larger locally staged publication is separate
work, rather than a hidden partial commit.

`GraphMigrationPublicationResult.receipt` proves local commit and identifies the
backup. `selectedChanges` counts the manifest, not uploads. Cloud delivery runs
through ordinary local-author PH and transport after release of the owned pause;
old batch acknowledgements cannot clear newer generations. Neither this receipt
nor an empty local queue certifies globally atomic/compatible cloud migration.
Consumers coordinate other devices and shared ledger information explicitly.

S03, cloud node/asset formats, session format 6 and workspace descriptor format 2
are unchanged. Participant execution, distributed exclusion, physical power-loss,
external-process writers, large media and mandatory v1 conversion remain open.
