# MF04 — isolated migration workspace and PH change set

Status: design and implementation plan, based on integrated MF03/#122
(`5b22750`). This contract precedes the implementation of migration-roadmap step 4.
No API below is implemented by this document. A focused MF04 branch returns
directly to `codex/graphevo-2`; no experiment/integration branch stack is needed.

## Purpose and boundary

Give the consumer an ordinary mutable `GraphStore` containing a complete local
working copy. Use Persistent History to discover the logical primitives touched
since preparation. Seal that copy before returning a bounded change set.

MF04 starts from an explicit, verified backup. It neither transforms the original
nor publishes changes. The later executor owns source reservations, backup
retention across the complete migration, ledger transitions and the final
publication/recovery protocol. A prepared workspace alone does not certify that
the original is still unchanged or that a migration has completed.

The consumer owns the transformation, its eligibility and domain correctness.
Graph owns structural validity, file/resource ownership, PH boundaries and truthful
lifecycle outcomes. There is no application-format registry, snapshot diff or
replay of an arbitrary consumer body.

## Identities and native isolation

Keep GraphID, logical node IDs, relationships/actions and attachment ownership.
The copy belongs to the same logical graph, not a new independent-user import.
The original, immutable backup and editable working files are physically distinct,
including all native external content. Do not modify, hard-link or write into the
backup/original as an optimization.

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

For the first MF04 activation, support local/owner sources. Refuse a copied
participant-access marker before exposing a writable graph, preserving the backup
and source. Participant workspaces need explicit live participation-generation
tracking, permission reduction and T08 revocation/purge integration before they
can be enabled. Removing an access marker must not become a workaround for that
missing lifecycle. This gate is separate from the ability to export a backup.

No Core Data entity/attribute/index, cloud-node/asset format or shared-session
format change is selected. Use reserved local metadata for working purpose.
Native objects and contexts remain confined to the adapter/runtime.

## Preparation and ownership

Proposed package-only entry point under ContextManager:

```swift
func prepareMigrationWorkspace(
    from backup: URL,
    at destination: URL
) async throws -> GraphMigrationWorkspace
```

1. Validate the complete backup through the central backup service, including
   native reopen, schema/identity and attachment bytes. Refuse an occupied or
   unsafe destination before changing it; never replace a live store.
2. Allocate a workspace UUID and durable retention ownership on that backup.
   Materialize the complete store into an owned hidden staging directory outside
   the backup. The source backup and other retention owners remain untouched.
3. Validate the copied graph, mark its working purpose and strip operational
   authority in the copy only. Preserve all application primitives and files.
4. Capture a fresh PH boundary on the prepared working store after setup.
   Persist a bounded descriptor before making a consumer handle available.
5. Detach staging stores successfully, publish the whole prepared directory to
   the empty destination, then open through the explicit workspace admission.
   Never move or remove a store while it remains attached.
6. Return the ordinary graph handle and workspace control object. Failure or
   cancellation never replays transformation code; no consumer body has run yet.

Use relative resource names. The descriptor contains format/workspace/backup/graph
identities, schema, preparation state and working PH boundary, never sandbox URLs,
CloudKit accounts or engine serialization. Caller bootstrap supplies current URLs
when reopening a workspace. A moved workspace must validate its complete identity
and resource ownership again; an existing replacement file is not adopted.

Failed detachment retains native ownership and the owned stage, with a visible
cleanup failure. Do not delete attached files or release backup retention as if
cleanup succeeded. Unknown/corrupt ownership markers are refused. Backup retention
is released only by a completed explicit discard or by the later executor after
its recovery obligations finish. Consumer-made exports remain consumer-owned.

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

## Sealing and change-set shape

Proposed package-only control surface:

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
and backup; release only the failed seal's own temporary reservation. The consumer
may inspect/correct data or explicitly retry with suitable limits. Missing history
is not repairable by replaying its body.

Close drains the workspace and invalidates its handles/observations through the
existing lifecycle. It preserves files, backup retention and successful seal
information for explicit reopen/recovery or later publication. Deinitialization
may arrange best-effort close, never successful publication or automatic discard.
Discard first completes detachment, then removes only the verified workspace's
owned files and releases its backup retention. Failed cleanup remains repeatable
and visible. Stale releases/callbacks cannot affect a replacement workspace.

## Restart and later publication

Reopen is explicit with current workspace and backup locations. Validate marker,
descriptor, GraphID, schema, native ownership and retained PH before permitting
writes or reporting a successful seal. An interrupted preparation remains an
owned incomplete stage, not an editable graph. Recover completed sealed state
without replay; an incomplete seal must be validated/retried under the write
fence. Define the durable seal marker/descriptor commit recovery before activation
rather than assuming SQLite and JSON commit together.

The original can have changed after backup creation. MF04 makes no promise of a
migration-long freeze. The later executor must acquire source local/cloud holds
before its baseline/backup and keep the appropriate fences through publication,
or explicitly reject a stale source on recovery. A crash releases in-process
reservations; reopening a source does not magically restore that guarantee.

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
| 2 | Verified backup materialization, retention and owned preparation | Source checksums unchanged, complete attachment recovery, cancellation/failure cleanup and failed-detachment preservation. |
| 3 | Working GraphStore activation and fresh PH boundary | Normal transactions/queries/files work locally; no cloud binding/queue; pre-backup history and pending original changes excluded. |
| 4 | Bounded PH reduction and seal | Entity/edge/action/file changes, cascades, implicit action edits, no-op and repeated edits, full rejection on missing history/unknown authors/limits. |
| 5 | Explicit close/reopen/discard and interrupted seal recovery | Old handles closed, moved locations, process restart at durable boundaries, retention preserved/released by the correct owner. |
| 6 | Review and direct PR delivery | Contract/API/status/checklist match actual scope; local macOS/iOS validation passes; corrections precede any requested CI checkpoint and authorized merge. |

Keep the preparer and reducer under the existing ContextManager/runtime ownership
model. Do not introduce a general migration registry, second graph data queue,
per-graph CloudKit engine or application resolver.

## Test matrix and acceptance limits

- Start from an empty graph and a populated graph with Entity, Relationship,
  Action, tags/groups, null/UUID/binary/encoded values and an external-size file.
  Include a source with pending sync metadata and retained recovery evidence.
- Validate source/backup preservation; the same logical IDs in physically separate
  files; isolation of attachment replacement/deletion and native sidecars.
- Confirm workspace write/read/observation behavior and cloud-admission refusal,
  including another manager and aliases. A participant-origin backup must be
  refused before writable activation until its revocation-aware lifecycle exists.
- Verify fresh baseline, no-op transformation, repeated edits, insert→delete,
  detail-only edits, cascades, surviving actions, complete file ownership and
  stable repeated seals. Validate frozen final state without a snapshot diff.
- Reject foreign/reused tokens, replaced stores, purged history, unknown authors,
  corrupt descriptors, wrong working purpose and every explicit limit without
  damaging original, backup or prior seal evidence.
- Exercise cancellation, concurrent seal/close/discard, readers and admitted writers,
  cancellation/close during attachment I/O, failed native cleanup and replacement
  generation safety. Resume from each durable preparation/seal boundary.
- Verify new local fixtures on macOS and iOS Simulator. Any physical CloudKit test
  belongs to later original-store publication: workspace isolation does not claim
  cloud convergence or distributed locking.

No beta/stable gate closes at design time. The implementation must report which
rows passed and retain broader power-loss, external-process writer, production
scale, source-publication and mandatory v1-conversion gates separately.
