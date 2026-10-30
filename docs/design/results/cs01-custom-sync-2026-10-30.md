# CS01 — explicit CloudKit sync, graph zones and migration pause (2026-10-30)

Outcome: all **11 one-use device stages passed** on owner iPadOS 27.0 and a
different-account iPhone XR on iOS 18.7.11. The bounded prototype demonstrates
private graphs in distinct unshared zones, sharing A in place, explicit per-zone
routing into exclusive local stores, a persisted pause across local native model
migration, independent B progress, and fresh recovery on both accounts.

This is evidence for a possible implementation path, not production sync
acceptance. The experiment stays on `codex/v2-custom-sync-experiment`, without a
PR or merge. Integration `codex/graphevo-2` remains at `b95ab1f`; its default
NSPersistentCloudKitContainer implementation and selected S02 model are unchanged.
The experiment does not reopen or integrate GI01 or MC01.

## Provenance and scope

The [CS01 protocol](../../../Experiments/CustomSyncProbe/README.md) was built from
`a86883dd10b033e45e466965480a8ef50db694ce` with Xcode 27.1 / Swift 6.4, using a
disposable Debug demo host. Actual signed entitlements select only Development
`iCloud.com.valerioburiani.GraphCKDemo`. The configured source demo was not edited.
Private evidence includes executable/library/source SHA-256, launch receipts,
reports, transports, journals, complete store directories and model archives.
No store, identity transport, invitation, token, native log or signing file is
committed. Existing native mirror zones and prior fixtures were not erased.

Each stage was launched once with a new ticket, acknowledged by its actual PID
and active scene; its separate report matches run, stage, ticket and PID. No
seed, share creation, migration or mutation was replayed. Writers remained alive
through independent peer observation. Only fixture/invitation transports moved
between devices; fresh replicas received no copied SQLite or sync journal.

The graph controllers use plain local Core Data stacks. CKSyncEngine owns explicit
CloudKit transport and its persisted serialization. Automatic scheduling is
**disabled**. Outgoing fixture changes are explicitly queued; the prototype does
not discover arbitrary application changes via Persistent History. Transport is
one GE2CS01Node record per application node with a bounded Data payload and
native CKRecord system fields. The fixture has two Entities, one Relationship
and one Action per graph. Application values, IDs and endpoints are checked.

## Device results

| Stage | Observation |
|---|---|
| prepare / identity | Isolated run directory and protected different-account recipient transport prepared. |
| seed-share | A and B each have four acknowledged records in distinct private zones, initially both without shares. A then gains a zone-wide share in its original zone. B remains private without a share. Outbox empty; eight fetched application rows. |
| peer-baseline | XR accepts A and recovers its exact four records and topology. No B store is created. |
| pause-migrate | A has a queued edit before pause. A sync admission is refused; its closed directory is backed up and its local model migrates 1→2. The migrated root edit remains queued. B exports a separate progress property, verified by a direct server record read, while A stays paused. B's baseline fields remain intact. |
| peer-paused-edit | XR still sees A's baseline root, proving the migrated root has not been published at this observation. XR changes a different child record and acknowledges its export. |
| owner-paused-check | Relaunch restores A's pause and one pending record. Its local migrated root remains; the remote child edit has not been applied. |
| resume | A publishes its migrated root and receives the peer's child edit. Exact identity, four-record topology and B controls pass; outbox empty. |
| peer-final | XR independently observes both the migrated root and its child update; outbox empty. |
| peer-fresh | Strictly new shared replica recovers those four final records with a new local store and new engine state; no B store. |
| owner-fresh-A | Strictly new private replica registers only A, despite B's existing private zone. It recovers only A's four final records; no B store. |

All engine stages report zero unexpected zone events and no retained sync failure.
The original owner A store uses `GraphEvo.CS01.local.2`; B and the peers retain
`GraphEvo.CS01.local.1`. Version 2 adds only an optional native diagnostic String
attribute. The cloud envelope stays unchanged: the native Core Data model
migration does not require a CloudKit schema change, and model-1 peers still read
the changed application data. This does not establish compatibility for arbitrary
application-format changes or a v1 cloud cutover.

## Independent physical inspection

After final independent observations, the acknowledged probe processes were
terminated and their absence checked. Complete case directories were copied to
protected external evidence. Separate disposable inspection copies were opened
with a **Core-Data-only reader with no GraphEvo dependency**. It opens exactly one
read-only SQLite resource, disables automatic migration, checks model metadata
and hashes, sets affectedStores on every fetch and verifies returned native
object IDs belong to that exact store. Generic NSManagedObject model bindings
prevent Graph managed subclass loading. No private SQL tables were parsed.

| Physical resource | Native lab model | A fixture rows | B fixture rows |
|---|---:|---:|---:|
| Original owner A | 2 | 4 | 0 |
| Original owner B | 1 | 0 | 4 |
| Closed pre-migration A backup | 1 | 4 | 0 |
| Original participant A | 1 | 4 | 0 |
| Fresh participant A | 1 | 4 | 0 |
| Fresh private A-only reader | 1 | 4 | 0 |

All present fixture identities match exactly. Hidden catalog/membership records
are outside these application counts. This confirms physical placement for the
tested fixture, beyond filtering Graph query results. The public Graph checks
separately verify values and Relationship/Action endpoints. Process disappearance
is not a clean native-detachment certificate; retained original artifacts remain
separate from inspection copies.

## Validation and limits

- `swift package dump-package`, `git diff --check` and the full suite passed:
  **558 tests** (331 legacy, 138 store, 66 runtime, 23 model).
- A new local regression verifies known graph identity, null/UUID/Data wire
  round-trip, closed model migration and exact data/topology after reopen;
  normal public native openers refuse these lab files.
- Disposable device host and independent reader builds passed. Initial host
  compilation exposed an iOS-26-only participant overload, a renamed share
  constant, legacy operator inference and isolation issues; these were corrected
  before any mutating device stage. No device stage failed or needed replay.
- The first slice exercises **idle pause with pending work**, explicit scheduling
  and ordered disjoint peer edits. Apple documents that cancelOperations may
  return before operations finish; the prototype additionally gates admission
  and waits for admitted manual/application work. It does not certify pause
  during automatic or in-flight work, background lifecycle or arbitrary concurrent
  callers. Actor reentrancy/application serialization still need implementation.
- Atomic recovery between application saves, outbox/inbox and serialized engine
  state is not complete. Crash/power-loss injection, retries/backoff, token expiry,
  zone deletion, account changes and generalized conflict resolution remain open.
  Deletion is explicitly unsupported and incoming pending conflicts fail visibly.
- Attachments/CKAsset, arbitrary payload scale, quotas, large graphs, revocation,
  leave/reinvite and full sharing lifecycle are not covered. This is not a full
  replacement of NSPersistentCloudKitContainer or a performance comparison.

A reasonable next experiment is durable change discovery/publication and failure
recovery, followed by in-flight pause and record conflicts/deletes/assets. Develop
a production implementation separately if this direction is chosen; preserve this
branch and its actual scope rather than merging the prototype.

## Apple API references

- [Manual versus automatic CKSyncEngine scheduling](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/automaticallysync)
- [Cancellation is not a completion barrier](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/canceloperations())
- [Delegate fetch scope selection](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8/nextfetchchangesoptions(_:syncengine:))
- [CloudKit sharing](https://developer.apple.com/documentation/cloudkit/ckshare)
- [Persisted engine state updates](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate)
