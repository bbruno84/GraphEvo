# V01 — cloud separation verification procedure

Status: T0 observed on two devices; T1 rejected by the native framework; T2 not
launched after that rejection; T5 observed unified fresh-peer recovery;
T3–T4 remain unexecuted. T6's initial runs were inconclusive; after an observer
delivery correction, owner-only zone creation and fresh same-iPad recovery were
observed. The independent iPhone reader subsequently recovered the exact fixture
and distinct owner-only zones from the iPad writer. See the
[T0 result](results/v01-t0-2026-10-23.md) and
[T1 result](results/v01-t1-2026-10-23.md), and
[T5 result](results/v01-t5-2026-10-23.md), and
[initial T6 result](results/v01-t6-2026-10-23.md) and
[T6 iPad diagnosis/result](results/v01-t6-ipad-diagnosis-2026-10-24.md) and
[independent T6 reader](results/v01-t6-independent-reader-2026-10-24.md) for evidence and limits.
This elaborates V01 of
[the verification roadmap](graphevo-2-verification-roadmap.md) and requirement R01
in [the design outline](graphevo-2-outline.md). It selects no v2 topology.

## Question

When two independent local graphs use the same model, CloudKit container,
account, and private database, what boundary does
`NSPersistentCloudKitContainer` actually preserve? Can a fresh peer independently
recover A or B, or does it import both into the same local replica?

A local filename, separate coordinator, or query filter is not evidence of cloud
separation. Distinguish local file separation, logical graph membership, remote
zone identity, and selective recovery. Record observations for each separately.

## Prerequisites

- Review the laboratory preparation and its regression fixes first.
- Use only a dedicated disposable CloudKit Development configuration with a
  compatible test model, valid signing/capabilities, and synthetic data.
- Start the app directly in laboratory mode in a fresh process. No normal demo
  graph or previous experiment container may remain active.
- Identify two devices signed into the same test account for the main procedure.
  Different accounts belong to V02. Record OS builds and the exact signed cloud
  environment; do not infer environment from a local filename.
- Record source revisions, local diff state, package pin, toolchain/language
  mode, model, configuration, procedure version, and observation window.
- Provision resources outside tracked source. The default unsigned/local demo
  configuration does not satisfy these prerequisites.

## Minimal fixture and instrumentation

Use direct framework calls, not GraphEvo. Start with a tiny CloudKit-compatible
model whose optional string attributes are runID, logicalGraphID, itemID, and
value. Do not add unique constraints or an app-level deduplication policy.
Use fixed item identifiers A-001/A-002 and B-001 within a unique recorded runID.
The graph labels are diagnostic markers, not the claimed isolation mechanism.

Route inserts explicitly to a store and inspect each store with affectedStores.
Retain store identifiers, lifecycle errors, local save outcomes, native
setup/import/export events, and the exact fetched fixture rows per store.
Use fresh private-context reads to distinguish imported data from a stale view.
Where available, inspect node cloud identities through the container's public
mapping API, on the owning queue, without saving or forcing export. Record zone
identity separately from local object identity; absent mappings are inconclusive.
No private API, custom zone injection, or direct CKRecord write is part of V01.

## Trial sequence

| Trial | Action | Observation required |
|---|---|---|
| T0: control | Mirror a single fresh store on device 1 and recover its fixed fixture on device 2 | Verify that setup and real cross-device mirroring work before interpreting topology results |
| T1: two stores | Configure A and B with distinct local URLs, the same model and cloud settings, in one persistent container; assign writes explicitly | Record whether the configuration opens, native errors, rows imported into each store, and available zone mappings |
| T2: fresh peer | On device 2, open one fresh store with the same model and cloud settings and no application-level graph filter | Inspect all rows for the run; determine whether A, B, both, or neither arrive |
| T3: recovery order | With new disposable local paths, repeat opening candidate A/B replicas in reversed order; never load one SQLite store through two mirror owners | Determine whether any claimed identity boundary survives recreation and order changes |
| T4: independent change | Change A-001 on device 1, retaining B-001 as a control | Inspect persisted rows on device 2; distinguish a full replica with filtered queries from separate recovery domains |
| T5: alternate lifecycle, if justified | If needed, compare separate persistent containers owning distinct store files using the same cloud configuration | Record differences from T1 without treating this as a way to select arbitrary private zones |
| T6: owner-only shares | Create a new share for each disconnected root graph, without adding other participants; recover on a fresh same-account peer | Verify distinct zones and exact root/child share membership without claiming selective download or separate SQLite stores |

Do not proceed with T1–T6 if T0 has not established a working cloud setup.
Stop an unsupported configuration on its native error; do not silently fall
back to local persistence or count an app-side partition as remote isolation.
Do not deliberately run simultaneous mirror owners for the same SQLite file.

The system controls synchronization timing. End each observation window with a
recorded outcome; a timeout or a missing row alone is inconclusive, not proof of
separation. A successful event alone is not a complete-fixture assertion.

## T5 revision: separate owners, same cloud destination

After the native T1 rejection, the maintainer authorized T5 with an independent
fresh-peer stage. T1 and its unexecuted T2 remain unchanged historical trials.
The new stages use a new runID and new local paths; previous cloud fixtures may
remain, distinguished by runID rather than deleted as a prerequisite.

The iPhone writer creates two distinct `NSPersistentCloudKitContainer` objects
in one process. Each owns exactly one distinct SQLite file, uses the identical
V01 model, and targets the same configured iCloud container and `.private`
scope. Keep both owners alive throughout the observation window. The T1
duplicate-destination preflight remains scoped to descriptions within one owner;
it must not reject the separate-owner experiment or be removed from T1.

Write A-001/A-002 only through owner A and B-001 only through owner B. Retain
initial and final fresh-context snapshots for each physical store, native events
attributed to the emitting owner and store, local save results, and available
record/zone mappings. Reads may filter only by runID, never logicalGraphID.
Cross-store arrival of an exact fixture written only by the other owner is
positive evidence against isolation. Missing rows at the end of the window
remain inconclusive, even if both exports report success.

After retaining the writer report, terminate its process. On the independent
iPad, launch the T5 reader into a new SQLite path with one mirror owner, the same
model, cloud destination, account, and runID. It must not insert, restore, or
copy fixture data. Recovering both A and B in that one fresh replica is positive
evidence of a unified recovery domain for this tested topology. Compare exact
values and available record/zone identities with the writer evidence. Absence,
partial recovery, or a native setup error does not establish isolation.

Verify signed Development entitlements and frozen source provenance before
hardware execution. Local/injected tests verify orchestration only. No forced
export, direct CKRecord writes, custom zones, scope changes, or local fallback
belong to this trial. Record the outcome before choosing further lifecycle or
selective-recovery experiments.

## T6 revision: graph membership and owner-only shares

Native event observation must return promptly on the posting queue and deliver
report/UI updates asynchronously. Registering a main-queue notification observer
can deadlock when native sharing waits on work that posts an event. Keep diagnostic
callback-entry tracing independent of the MainActor, and record debugger pauses
separately from clean execution. A fresh same-device replica is useful preliminary
evidence but does not replace the independent-device reader below.

After T5's unified recovery, the maintainer authorized a separate sharing-zone
experiment. Use one private store and one `NSPersistentCloudKitContainer`, with
two disconnected root objects A/B and their own children. Introduce dedicated
experimental entity names in new SQLite paths rather than modifying old stores
or resetting the test cloud schema. Root/child relationships must be optional,
have inverses, and form no cross-graph or global-catalog connections. Persist
the fixture and retain a checkpoint before requesting shares.

For each root independently, call the public `share(_:to:completion:)` with
`to: nil`. Apple's API documentation explicitly describes creating a new shared
record zone without participants; its deep traversal also includes related
objects. The experiment adds no participants, sends no invitations, and does
not use sharing UI. Distinguish the share owner from non-owner participants;
record public permission without collecting user identities or invitation URLs.

Retain each share callback outcome and returned object-ID membership, then
inspect all fixture roots/children with `fetchShares(matching:)` and public
record mappings. Verify that every A object belongs to share/zone A, every B
object to share/zone B, and the two share IDs and zone identities differ. Read
the entire run; graph labels must not hide unexpected members. Missing local
metadata is inconclusive: `fetchShares(matching:)` reads only known shares and
is not a server discovery or synchronization barrier. No custom zone injection
or CKRecord CRUD is part of this experiment. Any necessary share persistence
uses Core Data's supported share APIs, with its exact call sequence retained.

After the writer report is retained and its process terminated, start a reader
on the same-account iPad in a new private SQLite file. It creates no fixture or
shares and accepts no invitations. Compare exact roots, children, relationship
membership, record names, zone identities, share IDs, and owner-only participant
state. Both graphs may arrive in one local store even if they retain separate
cloud zones. Report zone separation, logical membership, local store topology,
and selective recovery as distinct findings.

Use bounded observation windows, fresh context reads, native events, source and
signature verification, and retained final reports as in earlier trials. Stop
on an unsupported native configuration or share failure without substituting
another scope/resource. Missing or partial peer data is inconclusive. This
trial does not prove cross-user permissions, selective zone download, future
share lifecycle stability, or production scale; those remain separate checks.

## Evidence, cleanup, and decision

For each trial retain its exact configuration, local store inventory, fetched
fixture identifiers/values, available cloud mappings, events/errors, timestamps,
peer conditions, and cleanup status. Redact account and provisioning details
from committed results. Keep reports even if a trial fails.

Close contexts and detach stores before removing disposable local fixtures.
Local cleanup does not remove server records. Remote cleanup must be a separate
explicit operation against verified experiment resources, never a generic purge
of the normal demo container. Record residual remote fixtures so later trials
cannot mistake them for new results.

Report R01 as supported only within demonstrated guarantees and documented API
constraints. If private graphs still converge into one replica, return that
finding to discussion; do not silently replace R01 with a logical-ID filter.
Potential alternatives, such as different provisioned cloud containers or
sharing-zone boundaries, require separate feasibility review and are not
accepted conclusions from this procedure.

## Apple references and limits

- [Setting Up Core Data with CloudKit](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit): multiple-store configuration; it does not establish the proposed per-graph cloud boundary.
- [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer): system-controlled timing and conflicts from multiple mirror owners for one store.
- [Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users): private/shared store topology and sharing behavior, to be examined in V02 rather than assumed for unshared graphs.
- [Creating or extending a share](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/sharemanagedobjects%3Atoshare%3Acompletion%3A): a nil share requests a new zone without participants; related objects are included by traversal.
- [Fetching known object shares](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/fetchsharesmatchingobjectids%3Aerror%3A): reads known associations only, without discovering additional zones.

These references motivate the controls; this document contains no experimental
findings. Resource configuration remains local and is excluded from tracked files.

## Device scope and optional single-device preliminary check

The maintainer has authorized a dedicated test container in Development and
testing on a physical iPhone and iPad, confirmed to use the same iCloud account.
This supersedes the earlier restriction to one iPhone and allows the original
T0 control to be attempted. Remote wipe
authorization is confined to that test container's Development environment;
it is not a required first step. Do not record personal resource identifiers
in this document. Confirm runtime access rather than inferring it from signing.

Before the cross-device T0 control, a separately labeled preliminary check may:

1. Validate the signed environment, account availability, and store setup.
2. Save a small fixed fixture under a fresh runID in a disposable writer store.
   Record native events and available mapping information, without claiming
   that a local save or record mapping alone acknowledges an export.
3. End the writer lifecycle, preferably across an explicit app-process restart,
   and open a genuinely fresh reader SQLite path. The reader must never insert
   or restore the expected fixture from local files or application code.
4. Observe native imports and fetch persisted rows through the owning context.
   Compare actual fixture values and identities with the recorded expectation.
5. Retain evidence and report whether this demonstrates an observed round trip
   into a new local replica on this device, or remains inconclusive.

Keep the expected fixture description separate from database recovery input.
Never reuse the writer SQLite, sidecars, backups, or migration restoration to
populate the reader. Release all context-bound objects and mirror owners; an
app restart must enter only the experiment reader, not GraphProvider.

The optional single-device check does not satisfy T0's independent-device control.
T1–T6 remain gated
on T0 under this procedure; changing that gate requires an explicit revision
and a clear account of what evidence would still be missing. Local/unit tests
and preliminary single-device work can proceed independently. The experiment
must not be reported as fully verified while cross-device checks are pending.
