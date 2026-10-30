# GI01 — physical isolation of one logical graph per native store

Date: 2026-10-30. **The tested recipe does not preserve physical per-graph
isolation.** Dedicated files/native owners initially seeded with one graph each
recover multiple graphs through the same CloudKit container and database scope,
even when those graphs have distinct share zones. This is a counterexample to
that recipe, not a rejection of the 1 controller : 1 logical Graph abstraction.

This is an experiment-only branch, `codex/v2-graph-store-isolation-experiment`,
based directly on integration `b95ab1f`. The measured host revision is
`1733b0fcda7956ec16c3f5bc0e68aa27a881131e`. No production source, native model,
default opening path or integration document is changed. No PR or merge is
requested. Use this result to inform a separately designed implementation; do
not merge the laboratory as the migration/controller architecture.

## Question and configuration

Can a controller that owns one S02 private SQLite store, or its own private/shared
pair, keep only its intended logical graph when another controller uses the same
model and iCloud container? Test import and fresh recovery, not just the data that
an application-facing graph handle chooses to display.

The [GI01 protocol](../../../Experiments/GraphStoreIsolationProbe/README.md) uses
only public GraphEvo APIs. Each GraphDatabase has distinct URLs and a separate
native resource owner. Original A creates/writes graph A only; original B
creates/writes graph B only. Each graph contains a root, child, directed edge and
action, with exact run-bound properties and endpoints. Both get distinct
owner-only share zones before recipient invitations are issued.

All public cloud openers select S02, `GraphEvo.v2.schema.2`, in the authorized
Development test container. Nothing resets or purges existing cloud data. Existing
unrelated graphs were present; reported counts distinguish them without exposing
IDs. Graph-specific creation is not an import-filter configuration.

## Environment and provenance

- Xcode 27.1 (27A9275); Swift 6.4; disposable Debug host referencing unchanged
  integration library code. Actual signed Development container is checked.
- Owner: physical iPad 10th generation, iPad13,18, iPadOS 27.0 (24A437).
- Participant: physical iPhone XR, iPhone11,8, iOS 18.7.11 (22H384), different account.
- Both devices were unlocked. The configured demo checkout was not modified.
- Protected external evidence retains host/executable hashes, source revision,
  run-bound transports, active-scene launch receipts, PID/ticket-bound reports,
  stopped-process receipts, complete collected case directories and offline
  inspector source/output. Account identities/invitations/stores/raw logs remain
  outside Git. Host source hash is retained in the build manifest and checked
  against the measured source snapshot.

## Results

All five stages executed successfully; the isolation hypothesis failed. A report's
`succeeded` means the stage executed and its intended baseline was recovered,
not that the resources were isolated. `physicalIsolationCounterexample` records
positive observation of a complete foreign graph.

| Resource | Complete A | Complete B | Meaning |
|---|---|---|---|
| Owner original A, initial sample | Yes | Yes | The original resource had already imported B |
| Owner original B, initial sample | No | Yes | Temporary absence of A did not demonstrate isolation |
| Owner fresh private A | Yes | Yes | New resource intended for A recovered both graphs |
| Owner fresh private B | Yes | Yes | New resource intended for B recovered both graphs |
| XR pair A | Yes | Yes | Both accepted graphs available through pair A |
| XR pair B | Yes | Yes | Both accepted graphs available through pair B |
| XR fresh pair A | Yes | Yes | Accepted shares recovered into a new pair, both graphs present |
| XR fresh pair B | Yes | Yes | Same counterexample in a second new pair |

Each complete observation validates exact root/child values, directed endpoints,
action endpoints and full graph integrity (four application records). Header or
catalog presence alone does not count. Owner A/B have distinct native share
boundaries, so the result is not explained by initially mixing their cloud zones.

Only recipient identity, fixture and invitation transports were transferred
between devices. No source SQLite/native sidecar entered a fresh replica. The
original owner processes stayed alive through independent recipient observation
and fresh recovery. Mutation stages were not replayed. Only the acknowledged
probe processes were stopped after the observations.

### Physical-file confirmation without CloudKit

Collected whole case directories were inspected separately on the Mac through
public `GraphDatabase.openReadOnly(..., schema: .nativeIdentity)` and ordinary
Graph reads/integrity checks. This path starts no mirrored container.

- Both owner fresh-private SQLite files contain complete A **and** complete B.
- Both original owner SQLite files contain complete A and B by collection time.
  Original B's initial missing A was an observation-timing effect, not durable
  exclusion.
- All four inspected XR shared SQLite files (two initial pairs, two fresh pairs)
  contain complete A and B.
- The two fresh XR private SQLite controls contain neither owner's fixture graph,
  consistent with the different account/private scope. Data was in their shared
  resources, not merely in a combined in-memory catalog.
- Public Core Data metadata confirms fourteen collected S02 stores, with fourteen
  distinct store UUIDs. Different owners were not accidentally aliases of one file.

The committed [offline inspector](../../../Experiments/GraphStoreIsolationProbe/Inspector.swift)
and its preparer reproduce these read-only checks on owned closed evidence copies.
An initial external inspector build attempted an awaited check inside a Boolean
short-circuit autoclosure; it was corrected to await the count first, before any
file inspection. No library change or data mutation was needed.

## Follow-up: only A's store loaded, no B graph handle

The initial experiment kept original B's native owner alive in another container.
Those observations alone did not isolate whether B must remain open elsewhere.
The maintainer asked for this distinction; a separate one-use `recover-A-only`
control now removes it.

The measured follow-up host adds only this stage; its exact source SHA-256 is
`bd7583819ac01c243838eebd29662034f3ce3e981e89151d13b600ddc91a1536`.
Protected evidence retains its executable/source manifest and source snapshot.
The production library/model are unchanged.

1. Inventory and stop confirmed GraphEvoDemo laboratory processes on iPad and XR.
   Verify zero matching processes on either device before the controlled launch.
2. Launch a new acknowledged iPad process with exactly one GraphDatabase/native
   owner and one strictly new private SQLite in `single-private-A`. No original
   A/B store or other fresh store is opened in that process.
3. Recover/validate A only. No graph B handle is created, no explicit B catalog/
   content inspection is requested, and no application writes/invitations occur.
   Retain the sole native owner for 90 seconds after A becomes complete.
4. Await native owner close. The PID/ticket-bound report confirms one owner,
   no B store/handle, no app writes and deferred offline inspection. Its default
   `physicalIsolationCounterexample = false` does not classify B: this stage
   intentionally does not inspect B while CloudKit is active.
5. Stop the acknowledged process and collect the closed directory separately.
   Confirm no XR laboratory process at completion. Use the public offline
   read-only inspector, without CloudKit, to inspect this file.

**Result: complete A and complete B are both physically present.** Each has exact
fixture root/child properties, edge/action endpoints and four-record integrity.
The native metadata is S02 with a new independent store UUID. B's local store
was not loaded during this control, and loading a B graph handle could not have
triggered the import: the first such handle was created during offline inspection
after the only mirrored owner had closed.

This closes the specific local co-loading ambiguity for the tested configuration.
It does not assert that other clients worldwide were offline, control server
scheduling, or prove a per-graph import filter exists. Already exported B records
remain on the server independently of its original local store being open.

## Follow-up: direct Core Data rows, independent of Graph's reader

The earlier offline inspections used Graph's adapter. To remove that dependency,
run a separate `CoreDataReader` executable whose target has no GraphEvo dependency
and whose source imports only CoreData/Foundation. Symbol inspection also finds
no GraphEvo/GraphDatabase symbols in that executable.

A separate ModelExporter process constructs the S02 model from Graph's public
base model, adds the exact identity columns/indexes, substitutes generic
NSManagedObject classes and verifies the entity hashes are unchanged. It opens
no store. The reader decodes that structural archive and checks compatibility
before opening data. No Graph code or managed subclasses are involved in reads.

Each reader process opens exactly one closed evidence file through a plain
NSPersistentStoreCoordinator, read-only with automatic/inferred migration disabled.
It asserts one attached store and the exact canonical URL, sets affectedStores on
every request, excludes pending changes, and fetches dictionaries containing only
native ge2GraphID/ge2NodeID/type attributes. A second object-ID request asserts
that all fetched IDs belong to that same NSPersistentStore. Four matching native
identities/types means the expected root, child, relationship and action rows are
physically present; this reader does not decode application property payloads.

Add a never-cloud local control: create two new S02 stores through ordinary local
GraphDatabase opening, with no CloudKit identifier. Seed four A records only in A,
four B records only in B, verify separate catalogs, then close all leases. Read
these files through the same independent reader in separate processes.

| Closed file inspected directly | Native A rows | Native B rows | Exact native identities |
|---|---|---|---|
| Single A file recovered from cloud, B never opened | 4 | 4 | Both sets match the cloud fixture |
| New local-only A file, never cloud-enabled | 4 | 0 | A matches; B absent |
| New local-only B file, never cloud-enabled | 0 | 4 | B matches; A absent |

All readers confirm one store, exact file binding, compatible model and persistent
object IDs bound to that store. There is no private SQL/table inspection and no
CloudKit container in this reader. Thus the never-cloud local control does not
mix the graphs; the cloud-recovered single file really contains both native sets,
independently of Graph's query adapter.

The initial reader build warned about capturing NSPersistentStore across the
context closure. The final reader obtains the bound store inside the context
queue instead; it builds without new reader warnings. The local controls/model
exporter also build/run. No production code, default schema or integration branch
was changed. Prepared sources, model archive, fresh local fixtures and reader
outputs remain protected external evidence; only the reproducible source and
sanitized counts are committed on the experiment branch.

## Interpretation and limits

Reject the inference **one native controller/file seeded with one graph ⇒ only
that graph is imported/recovered** for the tested same-model, same-container,
private/shared configuration. Zone separation, logical membership, graph-handle
filtering, distinct file URLs and physical import partitioning are different facts.

This does not show that 1 controller : 1 Graph is impossible. It shows that
exclusive physical ownership of that graph cannot simply be assumed underneath
such a controller. Returning a copied file in MC01 still replaces an entire
resource that can hold several graphs; this experiment does not authorize that
operation as independent per-graph publication.

No universal impossibility claim is made for other architectures, models or cloud
container configurations. No alternative production topology or import-filter
mechanism is selected. Native graph-specific import control, if proposed later,
needs its own supported-API design and independent recovery evidence.

Validation: physical host builds and all five acknowledged stages execute;
offline physical-file inspections and fourteen-store metadata checks pass;
`swift package dump-package`, Python source parsing and `git diff --check` pass.
The unchanged library's focused GraphDatabase baseline passes all nine tests.
There is no new production source to accept through CI or a merge in this branch.

References: Apple's
[NSPersistentCloudKitContainerOptions](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontaineroptions)
selects CloudKit container/database scope; the
[multiple-store setup](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit)
and [sharing guide](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
describe the native configuration and sharing mechanisms. The observed physical
import scope above is experimental evidence for the stated matrix, not an
additional guarantee inferred from those documents.
