# GraphEvo 2 — transition to explicit CloudKit synchronization

Status: selected direction, 2026-10-30. CS01 is a successful bounded feasibility
experiment. Its implementation stays on `codex/v2-custom-sync-experiment` and is
not merged. New production increments start directly from `codex/graphevo-2`.
This contract supersedes M05's NSPersistentCloudKitContainer-only direction and
the owner-only-share workaround in D05/D10 for the new implementation.

## Ownership

The ContextManager is the internal orchestrator. It owns the CloudKit engines
for a configured container/account session in the process responsible for sync:
one for the private database and one for the shared database when needed.
It routes zone changes to GraphCoordinators. Do not allocate one CKSyncEngine
per graph or per open GraphStore lease. Apple's production guidance explicitly
prohibits multiple engines targeting the same database. Database scope, container,
account and environment bind engine state; never reuse state across accounts.

One GraphCoordinator manages one graph: its local Core Data store, logical graph
identity, zone binding, operation lifecycle, migration and durable per-graph sync
work. Multiple consumer handles must share that owner through the existing
resource-ownership safeguards. The new local store is not an
NSPersistentCloudKitContainer. Existing multi-graph GraphDatabase resources are
legacy input, not an exclusive per-graph store merely because a controller opens
only one GraphStore. Their conversion requires an explicit supported path.

| Responsibility | Owner |
|---|---|
| CloudKit engine lifecycle, shared scheduling and account invalidation | ContextManager |
| Zone-to-graph routing and exclusive registration | ContextManager |
| One graph's native store, reads/writes, migration and queued work | GraphCoordinator |
| Local data access | Existing typed scopes and value/model contracts |
| Application meaning and consumer transformations | Consumer |

These are implementation responsibilities, not new public API signatures.
Keep CloudKit types internal except where platform invitation/UI integration
needs them. The public product remains GraphEvo.

## Zones, sharing and pause

An owner-private graph uses a distinct custom zone in the private database with
no share. Sharing creates a zone-wide CKShare in that same zone when requested;
the owner continues through the private engine, while the participant accesses
the owner's zone through the shared engine. Graph identity and zone identity are
separate bindings. Preserve ge2GraphID/ge2NodeID and graph integrity; no native
model change or beta/schema freeze follows from selecting this architecture.

A graph-level pause gates that graph's outgoing work and application of incoming
changes, then drains admitted application operations before migration. It must
not stop unrelated graphs by cancelling their shared engine. Retain incoming
bodies durably if shared engine progress can advance while a graph is paused;
never discard fetched records and then persist a cursor past them. Engine
cancellation alone is not an operation-completion barrier. Journal/outbox/inbox
and store recovery must preserve acknowledged local commits across interruption.
Account change is a session-wide condition; do not hide it behind a graph pause.

The manager must retain engine ownership while any participating graph depends
on it. Closing one graph or cancelling one consumer must not destroy shared
transport state. Read-only widget access stays a local consumer; synchronization
process ownership and cross-process migration coordination retain their gates.

## Cleanup and implementation order

1. **Merged #105:** isolate the old native mirroring implementation from local
   runtime ownership/transactions. Keep its existing explicit alpha entry points
   operational during replacement. Move native share/open/assignment code under
   `Persistence/LegacyMirroring`; move runtime native setup/notifications into
   `GraphEvoRuntime/LegacyMirroring`. These paths are transitional and receive
   correctness fixes only. This is isolation, not retirement or new cloud sync.
2. Implement exclusive per-graph local ownership and ContextManager registration.
   The [first package-only increment](graphevo-2-graph-coordinator.md) supplies
   this local foundation; public activation remains later work.
   Reuse typed CRUD, values/codecs, attachments, queries, observation and registry
   safeguards. Avoid rewriting them solely because transport changes.
3. M18 selects Persistent History discovery and [S03](graphevo-2-history-schema.md)
   deleted-identity preservation, rather than a consumer mutation journal.
   Implement durable local change discovery and outgoing publication, incoming
   persistence/application and recovery. Verify interruption boundaries before
   building the rest of sync on top of them; this is the first alpha acceptance
   increment, not another general-purpose experiment branch.
4. Implement shared private/shared engine ownership, zone routing, automatic sync
   and graph-level pause/resume. Exercise in-flight operations and restart.
5. Complete conflicts, deletes, assets and sharing lifecycle through reviewed
   alpha increments; retain production hardening gates for beta.
6. Remove transitional v2 native mirroring APIs, assignment ledgers/adapters and
   paired-store assumptions once replacement callers/tests exist. Preserve v1
   source conversion, historical evidence and the legacy reader needed for v1
   data migration. Do not convert or erase an existing mirrored store implicitly.

The first increment changes no public signatures, native schema, store URL or
wire format. No custom production CKSyncEngine, GraphCoordinator or new
ContextManager is claimed implemented by moving the old code. The current local
GraphDatabase still supports multiple logical graphs; step 2 supplies the new
one-controller/one-store invariant explicitly.

## Evidence and gates

[CS01 result on the retained experiment branch](https://github.com/bbruno84/GraphEvo/blob/3242707/docs/design/results/cs01-custom-sync-2026-10-30.md)
records eleven passing stages, per-graph private zones, selective sharing,
paused native migration with disjoint peer edits, fresh recovery and independent
physical Core Data inspection. Scheduling was manual and queueing fixture-driven.
It is not production change discovery, crash recovery or automatic sync acceptance.
Earlier NSPersistentCloudKitContainer results retain their actual historical
scope; they do not certify the new transport. Mandatory v1 data migration,
backup/recovery and account/sharing acceptance remain release requirements.

CKSyncEngine requires at least iOS 17/macOS 14. Select the supported deployment
matrix before activating the new backend; this cleanup keeps current floors.

Apple references:
[one engine per database](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database),
[cancellation semantics](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/canceloperations()),
[engine state persistence](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate).
