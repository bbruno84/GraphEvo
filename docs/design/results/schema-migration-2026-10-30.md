# V1 native schema migration and cloud replication — 2026-10-30

Result: positive for the bounded additive native-schema experiment, including
staged-handler final data replicated to an existing different-account peer and
a fresh local replica **before an ordinary post-open application save**. This is
not complete v1-to-v2 data conversion or general schema-migration acceptance.

## Models and source provenance

The [laboratory](../../../Experiments/SchemaMigrationProbe/README.md) uses the
v1 model construction from release `1.0.0`, commit
`1f0d2cd72d805f7c8d979b2f6ddee728f164e2d0`, model source blob
`4d0d4c4b25a87161d71ca7b66404cc6898c25dbb`. The current `Model.makeModel()`
extracts the same construction from the former cached factory. It does not change
native attributes/relationships. Test fixtures are newly populated under current
frameworks; they are not historical production-store copies.

Local controls compare three shapes: v1; native optional graph/node String
projections plus compound indexes; and that native shape plus experimental
optional Integer64 `ge2DataVersion` on the three node kinds. The native shape's
entity hashes match the current candidate factory. The new version attribute has
no default. V1 already has a distinct `appDataVersion` on property-detail rows.

Physical runs use v1→versioned, an additive superset of the native v2 shape.
Laboratory model identifiers are explicit and are not public alpha activation.
No production model, default opening, public schema choice or migration policy
is changed. Version metadata is a viable experimental representation, not an
adopted mandatory application contract or a guarantee of semantic compatibility.

The fixture has two entities, a directed relationship and an action, each with an
explicit synthetic identity, four-byte binary value, fixed date, tag and group.
Node projections use those declared fixture UUIDs; graph projection uses the run
UUID. No generic legacy-ID conversion or v2 catalog/membership activation occurs.

## Executed matrix

| Case | Observed outcome | Scope |
|---|---|---|
| SM01 local lightweight | v1→native→versioned preserves all four records, values and topology; new optional fields initially absent, then explicitly populated | Same owned local SQLite, not a public automatic migration |
| SM02 local staged | `will` then `did` execute; final labels, node versions and projections are populated; identities/binary content/endpoints survive | Custom native stage with a compatible additive model transition |
| SM02 injected failure | A thrown error after the pre-handler save leaves that pre-handler change in the source; the protected copy retains exact baseline data | A handler failure is not an implicit rollback; no blind retry |
| SM03 lightweight hardware | V1 baseline shared and independently recovered; writer file migrated, ordinary save sets version 2; old-model peer reads known updated fields, upgraded peer and fresh pair recover exact native projections/version/content | iPadOS 27.0 owner, iOS 18.7.11 XR participant, distinct accounts |
| SM03 staged hardware, before ordinary save | Writer reports both handlers and local version 1. Still-v1 peer observes final handler properties. Upgraded existing peer **and separate fresh pair** recover final handler label, handler-only property, native identities and version 1 | No normal application save after migration preceded those observations |
| SM03 staged hardware, after ordinary save | Explicit distinct ordinary save changes label/version to 2; existing peer and another fresh pair recover it while retaining the handler-only property and exact baseline topology/content | Separate control for ordinary-context writes |

All accepted comparisons use fixture identities/types, exact binary bytes,
dates/tags/groups and relationship/action endpoints, not merely row counts.
`stageOnly` is changed by the handlers and left untouched by the ordinary save.
The pre-handler's label/property changes are overwritten by the post-handler;
therefore this establishes the **final staged result**, not isolated export of
each intermediate pre-handler effect.

Before writer migrations, the exact acknowledged writer process was terminated
and its whole probe directory copied to private external evidence. For the
staged case the original participant directory was protected too. Owner resources
were retained until independent peer observation; termination is not treated as
clean native-detach or export-barrier evidence. Fresh pairs are created on new
peer paths and obtain records from CloudKit, never from copied owner SQLite.

CloudKit Development, native sharing/assignment/import and an existing accepted
share are used. No reset, purge, production schema deployment, invitation to an
unrelated account or direct CKRecord data mutation occurs. Test records/shares
remain in Development; future tests must not assume an empty or fully converted
cloud container merely because they use fresh local files. After final independent
recovery the exact remaining probe processes were stopped; stores and reports
were preserved. The schema change's
local success, native setup, exported data and recovered replica are separate
facts; replica results provide the actual remote-data evidence.

## Interpretation

A successful local model migration alone remains insufficient evidence of cloud
replication. However, the absolute claim that changes made during staged
migration cannot replicate is contradicted by this controlled result. Custom
handlers saved through the migration-owned Core Data context, and their final
values/native attributes were recovered remotely after the mirrored store opened.
This does not establish arbitrary copy-to-new-store/manual migration behavior,
all framework versions or a general synchronization pause.

The additive data-driven direction is supported: retain a stable native Graph
shape and evolve application properties/formats where appropriate. Native schema
changes remain internal library work; consumer migrations target application data.
A node version helps identify a declared format, but does not prove import
completeness, permissions, latest writer version or semantic compatibility.

## Retained failures and harness corrections

- The initial staged adapter used Graph searches inside the migration-owned
  context. Native fetches saw the source rows while those facade searches returned
  none. The explicit stage adapter now uses generic public Core Data fetch/KVC
  operations; normal post-open operations retain Graph facades. This is not a
  claim of a Core Data migration bug. A checksum warning was addressed by freezing
  the source model before creating its model reference.
- The first device host wrote the identity transport and identity stage report to
  the same filename. The overwritten transport caused a `DecodingError` bridged
  as Cocoa 4864 **before native sharing was invoked**. Initial reports and source
  directories are preserved. Reports now have `.report.json` names. The explicit
  `identity-refresh` / `invite-prepared` continuation retained the original seed;
  native sharing requires absent mappings and a one-use durable assignment intent.
  The unsuccessful existing-share continuation also failed at transport decoding,
  not native reassignment. No seed or native assignment was replayed.
- A final read-only host confirmation was initially routed to expect version 1
  after version 2 had already been independently observed. Its bounded deadline is
  retained as a harness expectation error, not a migration/sync failure. Version-1
  and version-2 reader routes are now explicit and distinct.
- Readiness now requires the entire known fixture, including detail rows and
  endpoints, rather than four node rows. Accepted earlier hardware reports were
  independently compared against every baseline field. Each report's PID matches
  its actual acknowledged launch. The final host also stamps the launch-ticket
  nonce so a stale report cannot pass under a reused process ID. Legacy reports
  lack that field and retain their narrower fresh-stage/PID/receipt provenance.

## Verification and remaining gates

- Full macOS package suite: **526 pass** — 328 legacy-target tests including six
  laboratory controls, 111 store, 64 runtime and 23 model.
- Signed Debug generic iOS host builds/installations pass; all preparation and
  signing changes are confined to the disposable demo copy. Original demo edits
  are preserved. Physical peers are iPadOS 27.0 and iOS 18.7.11; Xcode 27.1
  (`27A9275`), macOS 27.0.1.
- The final read-only host confirmation passes the stricter complete-fixture
  readiness check and exact launch-ticket nonce binding on the XR, with version 2
  and the retained handler-only values. Earlier full hardware comparisons were
  also rechecked against their acknowledged process IDs.
- Evidence comparisons, Python syntax, package manifest and diff checks pass.
  Stores, reports, capabilities, identity transports and raw logs remain private
  external artifacts; no personal screenshots are required or committed.

Keep historical populated v1 store/codec coverage, actual process-kill interruption,
activation recovery, isolated pre-handler export, staged execution on older OS,
non-additive mapping routes, external file content and Production schema deployment
open. Concurrent cloud edits/stale-analysis rejection, account/permission changes
and late old-version writers are not established by these ordered fixtures.
Neither the beta gates nor mandatory complete v1 local/cloud migration are closed.
