# MF04 — isolated migration workspace and PH change set

Status: MF04c is implemented on `codex/v2-workspace-seal-recovery`, directly from
integrated MF04b/#124 (`7c2b5a9`), pending final review/checkpoint/integration.
Preparation, bounded PH reduction/sealing, explicit restart recovery and
ownership-checked close/discard are package-only. **Original-store publication,
its backup/executor journal and participant workspaces remain separate work.**
The [MF04a logical-emptying API](graphevo-2-logical-emptying.md) remains available.
S03, application cloud formats and shared-session format 6 are unchanged.

## Implemented surface and durable boundaries

- `GraphContextManager.prepareMigrationWorkspace(for:at:) async throws` prepares
  the isolated mutable GraphStore with owned source write/cloud-data holds.
- `GraphMigrationWorkspace.seal(limits:) async throws -> GraphMigrationChangeSet`
  rejects new writers, drains admitted work, temporarily drains readers and
  validates the complete graph/files in one privileged workspace transaction.
  It reuses the normal PH primitive reconstruction with an explicit independent
  range, then writes the identity/operation manifest into reserved root metadata
  **in the same transaction**. The native marker is authoritative. No JSON/native
  dual commit, whole-graph diff, original PH cursor or payload snapshot is used.
- A successful seal retains a write fence; reads continue. The facade also checks
  the durable marker before consumer mutation, including after interruption before
  the runtime installed its in-memory fence/result. Repeated seal returns the
  same result. Cancellation before save rolls back; after save returns success.
- `GraphContextManager.openMigrationWorkspace(for:at:limits:) async throws`
  reacquires source holds and validates the current source/store/descriptor,
  retained baseline anchor and full working graph before exposing any handle.
  An editable copy remains editable; a sealed copy restores the original manifest
  and write fence. No consumer body is replayed. Unsupported/incomplete/corrupt
  alpha workspace documents are refused unchanged.
- `close()` drains and disables working access, releases only its owned source
  holds and retains files. `discard()` additionally reacquires an exclusive
  cleanup owner, detaches natively and retains registry/global gateway claims
  through filesystem cleanup. Failed cleanup retains its owner and files for
  retry; another opener cannot use the detach/delete gap. Old handles stay fenced.
  Deinit only schedules close, never deletion/publication.

The destination for preparation must be absent with an existing parent. Copying
uses a private sibling stage and the native complete-copy path. Application
identities, values, timestamps, deletion evidence and internal files are preserved;
only copied operational checkpoint/transport authority is cleared. Participant
sources (including read-write participants) remain refused. No backup, ledger
operation or network publication is performed by preparation/sealing/recovery.

Descriptor **format 2** uses fixed relative `Graph.sqlite`, workspace/GraphID,
schema, native UUID/token boundaries and physical source/working file identities.
Format-1 alpha workspaces are not silently upgraded. The source boundary has a
fresh opaque token; its numeric transaction is absent. A unique setup author on
the working store anchors the numeric baseline and secure token. Anchor retention
is checked through supported PH author queries; opaque token serialization is
never interpreted and dates are not used as cuts. Source history is bounded and
must show no application effects: known metadata bookkeeping may progress, but
its reconstructed primitive set must be empty, regardless of its author label.
Unknown/local/import application changes, replaced stores and unavailable history
refuse recovery. Source queues and policy are never rewound from the copy.

Reopening supplies current URLs and supports same-volume directory/file moves
with preserved physical identities. Copying/replacing the SQLite file is refused,
even if its native UUID and bytes match. Cross-device or cross-volume workspace
adoption is not implemented; portable `.geb` backups remain a separate contract.
Every activation has a fresh process-local native owner nonce and an atomically
rotated 36-byte `activation` file. Stale controls cannot delete a newer activation,
even after the newer control closes. Native ownership excludes concurrent
activations across managers/registries. No absolute sandbox path, account, pending
cloud state or engine serialization is persisted.

`GraphMigrationWorkspaceLimits` defaults to 4096 transactions, 100,000 native
changes, 10,000 final logical changes and 4 MiB encoded manifest. Explicit hard
ceilings are 100,000 / 1,000,000 / 100,000 / 8 MiB; invalid limits are refused.
Transient insert-then-delete identities are omitted; repeated touches coalesce
without a semantic diff, including changes later restored to their original
values. Surviving action edits and cascade/file deletions retain normal identity.
The manifest contains workspace/graph, baseline/end evidence and sorted logical
ID/kind/save-or-delete entries, never file bodies or raw native object IDs.

Tokens are limited to 64 KiB and descriptors to 256 KiB. Discard preflights at
most 100,000 filesystem entries and 32 levels, refusing links/replacement objects
and checking native purpose, physical identities, activation/owner and descriptor.
These limits are not total memory, SQL-I/O, attachment-size, time or disk bounds.
Complete structural/file validation retains its existing costs. Native faults,
power loss, external-process writers, hostile concurrent filesystem mutation,
production scale and participant/source-publication acceptance remain gates.

A failure before directory publication removes only a successfully detached,
still-owned stage. Failed cleanup exposes `GraphMigrationWorkspaceCleanupFailure`
and preserves native claims/files. Failure after atomic directory publication
retains the directory. A complete descriptor/baseline is required for explicit
reopen; incomplete stages are never automatically adopted. A seal is recovered
from the native marker without depending on a separately updated descriptor.
Its post-end PH tail must contain exactly its sealing transaction and no later
work. Missing/pruned history is refused, never silently restarted from zero.

Apple documents [author-filtered history and expired-token refusal](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes).
No PH pruning is introduced by GraphEvo workspace operations.

## Purpose and boundary

Give the consumer an ordinary mutable `GraphStore` containing a complete local
working copy. Use Persistent History to discover the logical primitives touched
since preparation. Seal that copy before returning a bounded change set.

MF04 starts from a coherent copy of the protected original. It neither transforms
the original nor publishes changes. Acquire owned local-write and graph-data-sync
holds before copying and retain them during consumer editing and validation.
Ordinary source reads and the independent shared ledger remain available.

The agreed full flow is request, drain local/cloud work, copy and capture the
working PH baseline, consumer editing, seal/validate, create and verify a backup
of the original, then publish. Do not create/compress a backup merely to prepare
a working copy that may be discarded. The complete coherent copy remains necessary.
The later executor owns ledger transitions, the pre-publication backup/retention
and original-store publication/recovery. Backup failure forbids publication.
A prepared workspace alone does not certify migration completion.

The consumer owns the transformation, its eligibility and domain correctness.
Graph owns structural validity, file/resource ownership, PH boundaries and truthful
lifecycle outcomes. There is no application-format registry, snapshot diff or
replay of an arbitrary consumer body.

## Identities and native isolation

Keep GraphID, logical node IDs, relationships/actions and attachment ownership.
The copy belongs to the same logical graph, not a new independent-user import.
The original and editable working files are physically distinct, including all
native external content. A later pre-publication backup is also independent and
immutable. Do not modify, hard-link or write into the original as an optimization.

Assign a new workspace UUID and record a native working-purpose marker. A copied
store can retain the original native store UUID and historical tokens: neither
identifies this new working instance by itself. Bind the workspace descriptor and
PH bookmark to workspace UUID, GraphID, schema and the actual working store.
Never interpret a token captured on the original as the working-copy baseline.

Ordinary runtime openings must reject a working-purpose store. Only the explicit
workspace route admits the exact workspace UUID; the marker is not a schema
version. Enforce the distinction at native runtime admission so opening through
another ordinary manager/database cannot activate the copy accidentally. A
workspace cannot register a cloud zone or start a sync session. It exposes no
ContextManager through which the consumer could attach it to the original route.

The returned GraphStore supports normal transactions, queries, observations and
attachment operations. Its adapter has no active sync session. Remove copied
operational cloud binding/attempt/inbox-effect/checkpoint/access authority from
the editable copy before exposing it. Preserve application content and logical
identity; retain original recovery evidence only as inert provenance when needed.
A copied participant marker must not silently grant the original new permissions.
Opening a workspace never changes permission or availability on the original.

For the first MF04 activation, support local/owner sources. Refuse a
participant source before exposing a writable graph, preserving the source. Participant workspaces need explicit live participation-generation
tracking, permission reduction and T08 revocation/purge integration before they
can be enabled. Removing an access marker must not become a workaround for that
missing lifecycle. This gate is separate from the ability to export a backup.

No Core Data entity/attribute/index, cloud-node/asset format or shared-session
format change is selected. Use reserved local metadata for working purpose.
Native objects and contexts remain confined to the adapter/runtime.

## Preparation and ownership

Implemented package-only preparation entry point under ContextManager:

```swift
func prepareMigrationWorkspace(
    for graphID: GraphID,
    at destination: URL
) async throws -> GraphMigrationWorkspace
```

1. Validate source eligibility and an empty safe destination. Retain the exact
   source coordinator generation and acquire owned cloud-pause/local-write holds;
   await already admitted synchronization and local writers. Other graphs progress.
2. Allocate a workspace UUID and an owned hidden staging directory outside the
   source. Reuse the native coherent-copy mechanism from MF01, including complete
   external content, under temporary exclusive maintenance admission. Release
   only that snapshot's exclusive read fence after copying; keep the migration's
   source write/cloud holds. No backup package is created at this stage.
3. Validate the copied graph, mark its working purpose and strip operational
   authority in the copy only. Preserve all application primitives and files.
4. Capture a fresh PH boundary on the prepared working store after setup. Bind
   source native identity and an explicit freshness boundary as well. Persist a
   bounded descriptor before making a consumer handle available.
5. Detach staging stores successfully, publish the whole prepared directory to
   the empty destination, then open through the explicit workspace admission.
   Never move or remove a store while it remains attached.
6. Return the ordinary graph handle and workspace control object. Preparation
   failure/cancellation releases only its own source holds and preserves the
   original; no consumer body has run or been replayed.

Use relative resource names. The descriptor contains format/workspace/graph and
source/working store identities, schema, preparation state and PH boundaries,
never sandbox URLs, CloudKit accounts or engine serialization. Caller bootstrap
supplies current URLs when reopening. A moved workspace must validate its complete
identity and resource ownership again; an existing replacement is not adopted.

Failed detachment retains native ownership and the owned stage, with a visible
cleanup failure. Do not delete attached files or report cleanup success. Unknown
or corrupt ownership markers are refused. A caller-created backup/export remains
outside workspace cleanup. Once later publication begins, its backup retention
must follow that executor's recovery obligations, not workspace deinitialization.

## Persistent History boundary and reduction

Apple provides [token-bounded history requests](https://developer.apple.com/documentation/coredata/nspersistenthistorychangerequest/fetchhistory(after:)-3rmfm)
and a [current token for specified stores](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/currentpersistenthistorytoken(fromstores:)).
Capture the boundary on the working store, with no consumer writes admitted.
Persist its secure value representation and transaction/lineage evidence; the
exact native capture/retention checks must be verified in implementation tests.
Do not invent a date-based boundary, transfer managed objects or inspect SQLite
internals. No PH pruning is introduced on workspaces.

Reuse/factor the existing PH primitive reconstruction without weakening its cloud
queue semantics. The workspace range is a separate explicit input: it does not
inherit the original pending queue, receipt state, acknowledgement epoch or
checkpoint. Reading workspace changes must not advance the original sync cursor,
feed an upload queue or persist a cloud acknowledgement.

The reducer correlates primitive/detail rows and deletion tombstones, preserving
logical Graph identities for Entity, Relationship and Action. Attachment changes
use their normal graph primitive identity. Include cascaded deletes and implicit
changes to surviving actions. Exclude hidden catalog/control rows and setup or
bookkeeping transactions. Unknown authors, unresolved owners, corrupt identities,
missing/expired baseline history or invalid structure cause explicit refusal.
Never silently restart history from zero or return an empty successful change set
when the requested range cannot be proven available.

Reduce repeated touches to the final save/delete intent per logical primitive.
A value changed and later restored may remain touched: PH records mutations,
not semantic equivalence. Do not add a full-graph diff to eliminate such entries.
For a newly inserted then deleted identity, retain enough PH origin evidence to
avoid treating it as deletion of a baseline record. No ID reuse is authorized.

## Supported logical emptying

Provide `GraphStore.removeAll(maximumRecords:)`, also available on GraphMutation
inside an enclosing transaction. This operation applies to operational local/cloud
graphs as well as a future workspace. The intended workspace call is:

```swift
try await workspace.graph.removeAll()
// Repopulate workspace.graph with ordinary Graph transactions and fresh node IDs.
```

This removes every application Entity, Relationship, Action, property/tag/group
and owned attachment. It preserves GraphID, hidden catalog/control structure,
workspace identity, PH baseline/history, deletion identities and lifecycle state.
It does not destroy/recreate SQLite, prune history, reset a cursor, delete a
CloudKit zone or recreate a share. Arbitrary physical store replacement is refused.

Use Graph's supported mutation/deletion path, including ownership, dependency,
cascade and attachment checks. Complete preflight and apply within one native
transaction under the normal writer gate; no independent saves or raw batch-delete
shortcut bypassing graph metadata are selected. Cancellation/failure before commit
rolls back the entire emptying operation. After commit it reports the committed
outcome. Refuse explicit work/identity/history limits without partial emptying or
silently raising budgets. Emptying an already empty graph is a no-op.

The workspace's runtime write fence serializes/refuses emptying against
seal/close/discard and rejects it on sealed or closed workspaces. It affects only the working copy; source holds remain in force and
no network transfer starts. Query observations follow normal committed changes.

PH reduction retains deletions of baseline records and final inserts made after
emptying, including attachment/edge identities. An inserted-then-deleted identity
within the working range must not become a deletion of a baseline record. Deleted
identities cannot be reused, consistently with delete-wins; preserving an existing
identity requires updating that record instead of deleting and reinserting it.
The later publisher applies these logical deletes/saves to the original. Its PH
feeds normal cloud batches. Other devices are not promised an atomic whole-graph
replacement; the shared ledger remains coordination information for the consumer.

## Sealing and change-set shape

Implemented package-only control surface:

```swift
actor GraphMigrationWorkspace {
    nonisolated let id: UUID
    nonisolated let graph: GraphStore
    func seal(limits: GraphMigrationWorkspaceLimits) async throws -> GraphMigrationChangeSet
    func close() async throws
    func discard() async throws
}
```

Serialize these lifecycle commands. Sealing rejects new working-graph writes and
drains already admitted/queued writers across aliases. Ordinary reads may continue.
Do not bypass this fence through attachment operations or a privileged native path.
Then capture one coherent final view and its PH end boundary, validate structure
and compute the bounded set of changed logical identities. The consumer can no
longer modify a successfully sealed graph. Duplicate seal returns the same result;
it neither recaptures a later cut nor reexecutes the consumer.

The change set is an immutable, workspace-bound manifest of logical identity,
kind and final operation, plus provenance and start/end range evidence. It is
not a bag of native object IDs, cloud records or an unbounded snapshot of all
attachment bodies. Later publication reads final records/files from the sealed
workspace in explicitly bounded batches. Change counts do not certify a total
memory, SQL-I/O or attachment-size bound.

Use explicit transaction/native-change/logical-change limits, initially aligned
with the existing PH discovery defaults (4096 / 100,000 / 10,000), plus a bounded
encoded descriptor/change-set size. Refuse limits atomically without partial
success or implicit budget increases. A failed seal preserves the working data
and original; release only the failed seal's own temporary reservation. The consumer
may inspect/correct data or explicitly retry with suitable limits. Missing history
is not repairable by replaying its body.

Close drains the workspace and invalidates its handles/observations through the
existing lifecycle. It preserves files and successful seal information, and ends
only its own in-process source reservations. Explicit reopen must reacquire source
holds and validate source freshness before continuing. Deinitialization may arrange
best-effort close, never publication or automatic discard. Discard first completes
detachment, then removes only the verified workspace's owned files and releases
its source holds. Failed cleanup remains repeatable and visible. Stale releases
or callbacks cannot affect a replacement workspace or another caller's holds.

## Restart and later publication

Reopen is explicit with current workspace and source locations. Validate marker,
descriptor, GraphID, schema, native ownership and retained PH before permitting
writes or reporting a successful seal. An interrupted preparation remains an
owned incomplete stage, not an editable graph. Recover completed sealed state
without replay; an incomplete seal must be validated/retried under the write
fence. Define the durable seal marker/descriptor commit recovery before activation
rather than assuming SQLite and JSON commit together.

During an active migration, the original remains protected by owned local/cloud
holds. Closing/crashing releases in-process reservations; reopening the source
does not magically restore that guarantee. Recovery must reacquire holds and
reject a changed source using its bound native identity and retained application
history boundary. Do not compare only dates or silently accept a replaced store.

Only after final working-copy validation, create and verify the complete backup
of the still-protected original, retaining it for publication/recovery. A failed
validation or abandoned workspace requires no backup. The later executor must
retain the appropriate source fences through publication, preserving manual and
other callers' holds. It must refuse stale-source recovery instead of overwriting
new application changes.

Publication must apply final changed primitives/deletions through the original
store's normal native transaction/PH path, not replace its SQLite file or transplant
working PH tokens. A durable original-store commit marker reconciles its journal
after interruption. The original ledger/session cannot be rewound from the backup.
Source freshness, bounded batch atomicity/recovery and truthful local-vs-cloud
outcomes belong to the next publication contract. Nothing in MF04 authorizes an
unsafe provisional publication route.

## Implementation order

| Step | Deliverable | Evidence before the next step |
|---|---|---|
| 1 | Workspace identity/descriptor and native opening fence | Normal manager/database openings refuse marked copies; wrong workspace UUID and replacement store refused; S03 unchanged. |
| 2 | Protected original and owned coherent copy | Source write/cloud holds compose correctly, complete native attachment copy, no backup before validation, cancellation/cleanup and failed-detachment preservation. |
| 3 | Working GraphStore activation, logical emptying and fresh PH boundary | Normal transactions/queries/files and removeAll work locally; no cloud binding/queue; pre-copy history and pending original changes excluded. |
| 4 | Bounded PH reduction and seal | Entity/edge/action/file changes, cascades, implicit action edits, no-op and repeated edits, full rejection on missing history/unknown authors/limits. |
| 5 | Explicit close/reopen/discard and interrupted seal recovery | Old handles closed, moved locations, process restart at durable boundaries, source holds released by the correct owner and stale-source recovery refused. |
| 6 | Review and direct PR delivery | Contract/API/status/checklist match actual scope; local macOS/iOS validation passes; corrections precede any requested CI checkpoint and authorized merge. |

Keep the preparer and reducer under the existing ContextManager/runtime ownership
model. Do not introduce a general migration registry, second graph data queue,
per-graph CloudKit engine or application resolver.

## Test matrix and acceptance limits

- Start from an empty graph and a populated graph with Entity, Relationship,
  Action, tags/groups, null/UUID/binary/encoded values and an external-size file.
  Include a source with pending sync metadata and retained recovery evidence.
- Validate source preservation; the same logical IDs in physically separate
  files; isolation of attachment replacement/deletion and native sidecars.
- Confirm workspace write/read/observation behavior and cloud-admission refusal,
  including another manager and aliases. A participant source must be
  refused before writable activation until its revocation-aware lifecycle exists.
- Verify emptying plus repopulation, duplicate emptying/no-op, cancellation and
  rollback, attachments/cascades, rejected ID reuse, retained baseline/tombstones,
  sealed/closed refusal and exact logical delete/save output. Include bounded
  refusal before partial changes and unchanged original/pending sync work.
- Verify fresh baseline, no-op transformation, repeated edits, insert→delete,
  detail-only edits, cascades, surviving actions, complete file ownership and
  stable repeated seals. Validate frozen final state without a snapshot diff.
- Reject foreign/reused tokens, replaced stores, purged history, unknown authors,
  corrupt descriptors, wrong working purpose and every explicit limit without
  damaging original or prior seal evidence.
- Verify copy preparation and failed validation create no backup package. For the
  later executor, require a verified original backup before any publication.
- Exercise cancellation, concurrent emptying/seal/close/discard, readers and admitted writers,
  cancellation/close during attachment I/O, failed native cleanup and replacement
  generation safety. Resume from each durable preparation/seal boundary.
- Verify new local fixtures on macOS and iOS Simulator. Any physical CloudKit test
  belongs to later original-store publication: workspace isolation does not claim
  cloud convergence or distributed locking.

No beta/stable gate closes at design time. The implementation must report which
rows passed and retain broader power-loss, external-process writer, production
scale, source-publication and mandatory v1-conversion gates separately.
