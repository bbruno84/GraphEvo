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
