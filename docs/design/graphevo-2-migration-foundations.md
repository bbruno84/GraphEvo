# GraphEvo 2 — migration foundations roadmap

Status: [MF01](graphevo-2-local-maintenance.md) supplies the package-only baseline
for prerequisites 1–2, integrated with T08 through #120 into `codex/graphevo-2`.
Development started from reviewed T08 at `8dda893`, as explicitly requested.
The combined checkpoint passed after corrective review; the maintainer authorized
merge on success. [MF02](graphevo-2-backup-packages.md) integrates the step-2a
compressed package/export/import baseline in #121 after corrective review and
CI. [MF03](graphevo-2-shared-ledger.md) delivers the bounded shared-control ledger
in #122 after corrective review and full CI checkpoint #303. Independent cross-user
graph activation and remaining executor steps stay
open. Future branches start from `codex/graphevo-2`.

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
| 2a | Compressed portable backup packages | MF02/#121 supplies compressed `.geb` files, manifest listing and async package export/import, with retained legacy directory reads. Physical/production-scale and independent cross-user graph activation gates remain open. |
| 3 | Independent graph control metadata | MF03/#122 supplies bounded shared ledger/control transport. A durable local JSON journal and dedicated CloudKit control records accompany the graph outside its application primitives/Core Data schema. The migration ledger is the first use; allow future graph-related control information. |
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

### Compressed local packages and portability — next backup increment

The filesystem and per-backup manifest are authoritative. Do not require a
central registration database: a copied/imported package must be discoverable.
An optional future index is disposable and rebuildable from manifests. Listing
reads bounded manifests without extracting payloads; it is not full verification.

The maintainer selected **`.geb`** (GraphEvo Backup). The
[MF02 baseline](graphevo-2-backup-packages.md), integrated in #121, implements compressed local files,
manifest-first listing and async package export/import using a versioned container
and SDK zlib. MF01 directory backups remain readable. Package import and
independent cross-user graph activation are distinct: the latter still needs
identity/reference and activation design, rather than blindly reusing a raw store.

Completed local backups should contain a compressed payload, with their manifest
readable without full extraction. Stage the coherent native snapshot, release
graph-local/cloud snapshot reservations once that immutable copy and required
recovery evidence have been captured, then compress and verify asynchronously.
Publish the complete manifest/payload package atomically only after successful
verification. Cancellation or failure must preserve the source and previously
published backups; incomplete owned stages remain recoverable. Distinguish
coherent source copying, atomic package visibility and power-loss durability.

Export produces one transportable package from the completed local backup,
reusing the compressed payload rather than repeating snapshot/compression work.
Choose the archive/container layout with manifest consistency and retention in
mind; MF02 selects the versioned manifest-first container and raw
DEFLATE after local comparisons. Continue measuring
database-heavy and already-compressed media fixtures for size, latency, memory
and temporary disk usage. Keep compression/decompression streaming and bounded;
validate cancellation, truncated archives, unsafe paths, expansion limits and
checksum/native reopen before declaring an import/restoration successful.

Packages use relative references and contain all library-owned content needed
for the supported restore. Verify movement to another device explicitly.
Import for another user creates an independent graph with fresh graph/cloud
ownership and no inherited share participation, account binding, transport
cursors or upload work. Define identity remapping and attachment/reference
preservation before implementing this route; it is distinct from same-graph
recovery. Informational recovery evidence is not authority to reactivate a
previous user's session. Cross-user import is not implemented by MF01.

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
operations. [MF03](graphevo-2-shared-ledger.md) implements the package-only baseline: full
current and previous operation, 32 compact significant events, bounded consumer
JSON, explicit revision conflicts and a dedicated zone control record. Retries
update the current attempt counter without growing history. Session format 6
refuses incompatible alpha documents; native S03 is unchanged. Foreground control
reconciliation continues during data pause. A local-only unmirrored journal and
actual migration executor remain separate work.

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
custom-sync implementation. [MF04](graphevo-2-migration-workspace.md) defines the proposed working-copy/PH
execution contract and ordered implementation/test plan for step 4. It remains
documentation-only; step-5 original-store publication/recovery needs its own
concrete contract before activation. Beta/stable gates stay in the
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).
