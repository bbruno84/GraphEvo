# MF03 — bounded shared graph ledger

Status: package-only candidate on `codex/v2-shared-ledger`, directly from #121
(`d17676d`) to `codex/graphevo-2`. This implements the graph-control metadata
foundation, not a consumer migration executor or a distributed lock.

## Shape and ownership

The ledger retains one complete current operation, one complete previous
operation and at most **32 compact significant events**. Starting a new operation
moves the completed current state to previous; an interrupted/running operation
must be explicitly resumed/completed first. Older completed detail is replaced,
while the compact event ring evicts its oldest entries. Migration-run eligibility
and application compatibility remain consumer decisions, not history lookups.

Graph owns operation UUID, origin client UUID, state, dates, revision, attempt
counter and event rotation. The consumer supplies kind/phase labels, summaries
and its own JSON information through separate mutations. JSON objects are bounded
to 16 KiB each (global/current/previous), depth 8 and 1024 values; keys and labels
have explicit byte limits. They are canonicalized without domain decoding.
Current/previous details include phase, attempts, last consumer-reported failure,
timestamps and consumer information. Summaries are at most 256 UTF-8 bytes and
failures at most 2048. Retry increments the current counter and updates its error;
it does not append events. Significant start/phase/interruption/resume/finish
events carry compact identity/state/date/attempt/summary only.

The shared payload is capped at 128 KiB. Local state is at most 512 KiB per enabled
graph, including one coalesced pending value, bounded in-flight evidence and an
optional conflicting remote value. There is no event-per-retry outbox. Existing
session event/byte limits and reserved control headroom bound the total collection.
Unresolved migration-data recovery journals are separate future executor work;
rotating diagnostic history never authorizes their deletion.

## Local persistence and API

The session's local JSON holds the ledger outside Core Data and application
primitives. Session format **6** adds a durable local client UUID and enabled
ledger entries bound to graph/zone/participation generation. Incompatible alpha
documents, including format 5, are refused without modification. S03, GraphRecord
and application-node/asset wire formats remain unchanged.

This first shared-control surface requires a registered CloudKit zone/session.
An unmirrored local graph's standalone migration journal is not activated by this
increment. First status/observation/mutation/reconciliation use explicitly opts
that binding into the control path. Status and bounded newest-value observation
remain available after graph handles close while the session remains open.

ContextManager package-only operations:

- `graphLedger(for:configuration:)` and `observeGraphLedger`;
- `updateGraphLedger(...expectedRevision:mutation:)` for begin/progress/retry,
  interruption/resume/finish and global/current-operation consumer JSON;
- `reconcileGraphLedger(...acceptCloud:)` for explicit network reconciliation or
  explicit acceptance of the remote state after a conflict.

Optional expected revision and required operation IDs reject stale local commands.
No arbitrary consumer body is replayed. No-op patches preserve revision/dates.
An owned operation still running at restart is locally marked recovery-required;
the library does not publish a false completion or infer interruption from age.
Explicit resume/interruption/finish clears that local admission flag. A foreign
client's running operation is not declared crashed because another app restarted.
These controls never automatically pause or change application data.

## Cloud transport and concurrency

One `GraphEvoControl` CKRecord named `graphevo.control` lives in the graph's own
custom zone. Its format-1 envelope carries the graph identity and bounded ledger.
Zone-wide sharing gives it the same scope/permissions as the graph; a participant
can observe it read-only. Native sharing membership remains the permission
authority. A control record deletion/missing record is not access-revocation
evidence; T08 verifies membership before participant destruction.

Native fetch/save operations run under the session's existing per-database gate
and stop drainage, as sharing commands do. There is no engine per graph or new
CKSyncEngine; ContextManager still owns one per scope. Saves use
[`ifServerRecordUnchanged`](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged).
The [zone-wide sharing contract](https://developer.apple.com/documentation/cloudkit/shared-records)
also applies to these control records. The graph zone must already exist; metadata
does not recreate a missing/deleted graph zone.

A mutation first persists the latest desired projection locally. Repeated offline
edits coalesce while retaining the last confirmed base revision. Before save,
persist the exact in-flight projection. After a successful send, acknowledge only
that revision; newer local edits remain pending and rebase on the confirmed one.
An ambiguous save can be recovered when a subsequent fetch matches that exact
in-flight revision and complete body. No consumer attempt/event is synthesized
by transport retry.

Concurrent remote revisions are preserved as a visible conflict alongside local
work. They are never silently overwritten/replayed. Explicit cloud acceptance
discards pending control work; it does not undo application data. Native tag-only
collisions with the same logical base permit at most one targeted save retry;
further collisions/errors stay visible and pending. Device wall clocks annotate
events but never resolve concurrency or establish global ordering.

## Foreground lifecycle, isolation and recovery

The existing finite control worker supplies per-scope turn-taking, 60-second
reconciliation and bounded busy/network backoff. Consumer changes/remote hints
request an earlier turn; coalesced hints do not enqueue snapshots. Control work
continues during graph-data pause and does not read PH or import application
payloads. Manual activation/reconciliation remains explicit; background/APNs
delivery is not certified. Inactivity suspends new automatic work; stop drains
admitted native requests and terminates feeds without retaining the manager.

Control records are filtered before application inbox validation/limits and node
decoding. Their engine callbacks are hints to fetch the exact control record;
they are never uploaded as Graph primitives or fed into PH. Network fetch/ack
bookkeeping does not schedule another upload. Conflicting/read-only pending
control work still permits incoming metadata refresh. Application inbox saturation
does not bypass sticky account/identity/stop fences; reserved bounded ledger
headroom allows existing control entries to progress.

Revocation/leave blocks ledger access, terminates old observations and removes
that generation's local control work with T08 cleanup. Late callbacks cannot edit
a replacement entry; a new invitation has a fresh local generation and no old
pending publication. Its current remote ledger can be read after access is
verified. Backup recovery evidence captures only that graph's local ledger state;
restoring `.geb` never reinstates a session/ledger or replays pending control work.

## Validation and workflow

The [candidate result](results/shared-ledger-2026-11-01.md) records 808 macOS
functions, 476 selected iOS functions and the six-stage iPad/XR physical protocol.
It retains the distinction between injected recovery/concurrency tests and actual
cross-account control transport while graph data is paused.


Cover ring rotation, thousands of retries, complete previous state, consumer JSON
limits/no-ops, stale commands, restart/recovery flag and durable failures. Inject
offline/ambiguous sends, edits in flight, conflicts, duplicate notifications,
read-only access, pause, app inactivity, stop/drain, account change and generation
removal. Verify control separation from PH/app inbox and graph-scoped backup
evidence. Test the native codec and new record on fresh real-device zones without
resetting the container, keeping physical evidence separate from injected tests.

Update package API/status/post-alpha gates and deliver a direct PR. Review and
corrections precede one remote CI checkpoint and authorized merge. Local-only
graphs, migration-data execution/publication, independent-user restore, broad
fault/scale and background guarantees remain separate gates.
