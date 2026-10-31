# GraphEvo 2 — migration foundations roadmap

Status: agreed direction and ordered prerequisites, not an implemented API or a
completed specification. Work starts from reviewed T08 PR #120 (`8dda893`) on
`codex/v2-migration-foundations`, as explicitly requested by the maintainer.
T08 remains unmerged. Billing availability defers remote CI to one combined
checkpoint after local validation and review; no merge or release is implied.

## Responsibility boundary

The consumer defines the transformation, application compatibility and
coordination between devices. GraphEvo provides protected local execution,
durable recovery, backups, observable control information and synchronization.
There is no application format registry or mandatory per-record versioning.
Native schema evolution remains internal library work. Mandatory v1 conversion
and its agreed coordinated cutover remain separate acceptance work.

## Ordered implementation prerequisites

| Order | Work | Required behavior |
|---|---|---|
| 1 | Local write admission | Reversibly refuse new consumer writes on the original graph, then await already admitted writes. All handles of that resource share the gate; unrelated graphs progress. Use owned reservations so one caller cannot release another's restriction. |
| 2 | Central BackupManager | ContextManager obtains the appropriate cloud/local reservations; the backup service creates, inventories, verifies and restores complete graph backups. A verified backup is a prerequisite for migration. |
| 3 | Independent graph control metadata | A durable local JSON journal and dedicated CloudKit control records accompany the graph outside its application primitives/Core Data schema. The migration ledger is the first use; allow future graph-related control information. |
| 4 | Isolated working graph and PH range | Give the consumer an ordinary mutable working Graph, isolated from live cloud transport. Use an explicit PH baseline to discover its changes; do not introduce a library-wide snapshot diff or domain reconciliation. |
| 5 | Publication and recovery | Apply the changed final primitives/deletions to the protected original, with durable commit evidence, truthful outcomes and restart recovery. Do not replace an original SQLite file as a shortcut to cloud publication. |
| 6 | Representative v1 conversion | Use the protected executor and backup service to implement and validate the required v1 data/source conversion and cloud cutover. API compatibility remains optional. |

### Local write admission

T05 pauses graph data synchronization and drains admitted synchronization work;
it does not block consumer transactions. The runtime serializes writers and T08
has an internal application-availability gate affecting both reads and writes.
Neither is the proposed reversible write-only reservation.

During a write-only reservation, ordinary reads may continue while the original
store remains attached. A backup/restore step requiring store closure,
replacement or exclusive native access must additionally drain reads and prevent
new admission. Define the privileged publication boundary explicitly; ordinary
handles must not bypass the reservation. Cancellation, nested callers, late
releases and close/reopen must not reopen a newer owner's gate. The app/widget
process boundary needs an explicit supported policy and its own validation;
an actor alone does not exclude another process.

### BackupManager

The service is centralized under ContextManager; each operation is scoped to one
graph. Include the complete native store/content, internal attachments and the
graph-owned journal/recovery artifacts needed for restoration. Record a manifest
with graph/store identity, supported formats, relative resource references and
checksums. Verify inventory, bytes and supported reopen before declaring success.
SQLite/WAL/SHM copying alone is not a complete attachment backup.

The caller supplies a descriptive reason, persisted in the manifest and exposed
in backup listings. Use open text rather than a closed reason enumeration. The
migration manager supplies the migration and operation IDs automatically. The
consumer chooses destination and retention; required recovery artifacts cannot
be discarded while an operation still depends on them.

Creation/restoration must recover after interruptions and preserve the source on
failure. Restoration must not rewind the shared engines, another graph's state,
or the cloud ledger. Define how graph-specific transport/recovery state is
reconciled with the current session instead of copying an entire multi-graph
session document back. Local restoration after publication is not cloud rollback;
a cloud-visible reversal is a new compensating operation. Reuse/replacement of
the existing v1 backup helper must be assessed without weakening v1 behavior.

### Graph control metadata and shared ledger

The ledger is outside application nodes and the native Core Data model. Use a
local JSON artifact for durable operation state and a dedicated CKRecord control
representation for the shared projection. This path must remain operational
while graph application-data synchronization is paused. Reuse ContextManager
orchestration and engine ownership; no per-graph engine is selected.

Publish migration start/state/outcome so peers can observe them according to
CloudKit latency. Consumers decide how to respond. This is synchronized control
information, not a distributed lock or evidence that all application data has
arrived. Keep graph control information extensible for later uses such as sharing
descriptions; actual permissions/participants remain verified by native sharing
operations. Record layout, concurrency/merge rules, access scope and delivery
mechanism still need a concrete design before implementation.

JSON and graph data cannot commit in one transaction. Write an operation commit
marker with the application effects in the original graph transaction, using
existing reserved metadata. Reconcile the JSON journal from committed evidence
after interruption; do not add a native version column to solve this boundary.

## Remaining executor details to settle

- Working-copy identity, complete file isolation and cleanup; the consumer uses
  normal Graph APIs while the source stays protected. PH tokens belong to the
  specific working store and baseline, not an arbitrary copied history stream.
- Final-state publication of changed primitives, endpoints, deletions and
  attachments, with explicit bounds and original identity/transport metadata
  preservation. Validate library structure; application meaning stays consumer-owned.
- Cancellation and crash classification before/after commit, with no automatic
  replay of an arbitrary consumer body. Preserve backups and uncertain work.
- Observable local preparation/publication/recovery outcomes and a separate cloud
  delivery outcome. Resume retained remote work through the normal sync path;
  the consumer owns application-level coordination and compatibility policy.

## Validation and documentation

Test all aliases, unrelated-graph progress, overlapping reservations, admitted and
queued operations, cancellation, close/reopen and process restrictions. Exercise
whole-content backups, moved locations, corrupt/incomplete backups and interrupted
restore. Verify ledger activity during a data pause, bounded persistence,
duplicate delivery and concurrent control updates without claiming global locks.
Test PH baselines/no-ops, all primitive kinds, files/deletes and commit-before-JSON
recovery. Keep hardware evidence and its exact source pins separate from unit
coverage; do not replay consumed probe mutations or reset cloud implicitly.

The [historical manager plan](graphevo-2-migration-manager.md) retains M1/M2a
evidence. Its native-mirroring/import-version assumptions do not define this new
custom-sync implementation. Update the execution contract before implementing
steps 4–5. Beta/stable gates stay in the
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).
