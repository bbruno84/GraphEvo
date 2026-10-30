# GraphEvo 2 — deletion-history identities (S03)

Status: selected alpha revision, maintainer decision M18. S03 supersedes
[S02](graphevo-2-identity-schema.md) for explicit `.nativeIdentity` and the
package-only coordinated opening path. The physical model identifier is
`GraphEvo.v2.schema.3`. No-schema/current and v1 opening paths are unchanged.

## Exact model change

Retain S02's twelve entities, all attributes, relationships, types, optionality,
defaults, codecs, external binary storage and compound identity indexes. Change
only `preservesValueInHistoryOnDeletion` from false to true on ge2GraphID and
ge2NodeID for ManagedEntity, ManagedRelationship and ManagedAction: **six flags**.
The three node entity hashes change; the nine detail entity hashes do not.
No native application-version column or format registry is reintroduced.

Core Data deletion history now retains the graph/node UUID strings for deleted
application nodes. The tombstones do not preserve application properties, tag/group
payloads, attachment bytes or whole GraphRecord snapshots. Actual incremental disk
cost and history-retention envelopes remain unmeasured. Structural checks reject
partially preserved identity pairs and inconsistent preservation across node kinds.
Historical explicit laboratories keep their original factories/flags and markers.

## Evidence and adoption

[PH01, retained on its experiment branch](https://github.com/bbruno84/GraphEvo/blob/c806330/docs/design/results/ph01-persistent-history-2026-10-30.md)
proves the bounded real-Graph discovery fixture on macOS and iOS Simulator 26.5,
including nineteen expanded cases and a negative S02 deletion control. The
prototype is not merged. This increment implements the selected model directly,
with fresh regression tests against the public opening and normal native factory.
It does not import the experimental candidate reducer into production.

Selected-model tests assert the six-flag delta, exact model marker, deterministic
hashes, unchanged detail hashes/shape/index names and refusal of partial flags.
Normal CRUD/query/file/coordinator regressions continue through the same adapters.
Actual deletion-history tests use Entity/Relationship/Action operations, an
attachment cascaded from its edge owner, and persisted-token replay after reopen.
They assert all deleted IDs and that tombstones contain only the two projections.

The local validation checkpoint passes 578 tests (331 legacy, 153 store,
71 runtime, 23 model), the Swift 6 ModelConsumer, manifest and diff checks.
iOS Simulator 26.5 passes the selected schema/fresh-store/coordinator checks:
24 test functions and 29 expanded cases. The initial full run exposed two
legacy assertions still expecting S02; they now assert S03 and independently
retain the historical native/versioned model checks. These are local/Simulator
results, not physical CloudKit or crash/power-loss acceptance.
Review CI with Xcode 16.4 additionally caught a test token crossing a Sendable
boundary; its secure deserialization now stays on the native context queue and
only Data crosses that boundary.

## Compatibility and migration policy

S03 is incompatible with S02's native model hashes. Existing S02/S01/current and
laboratory files are refused before native loading: no relabelling, migration,
erasure or silent local substitute. Tests retain a real S02 file/data and compare
durable SQLite/WAL artifacts after local/read-only/mirrored refusal; volatile SHM
is not a source-data identity guarantee. Same-shape wrong-marker controls remain
separate from the real S02 compatibility control.

Under the agreed M13 policy, alpha adoption starts with fresh explicitly selected
stores. This increment does not provide an S02→S03 alpha converter. It also does
not claim schema migration retroactively reconstructs identity values for deletions
that occurred before preservation was enabled. Mandatory v1 data conversion and
any supported beta-data migration remain library responsibilities before release.

There is no cloud reset, deployment or new cloud record format in this change.
Earlier S01/native sharing reports retain their original scope. Existing mirrored
alpha entry points select the same explicit new model, but S03 native/cloud and
future custom-sync cross-device acceptance remain separate gates. The native
model marker and six local history flags are not evidence of sync completion.

## Next implementation increment

Use Persistent History as the committed-change source. Persist distinct local,
import and metadata authors; filter discovery without suppressing observations
of imported values. Implement scoped detail/node correlation with visible
unresolved states, then atomically persist pending work with its history checkpoint
before advancing the cursor. Prepare immutable batches from coherent current reads
and preserve newer generations when older sends are acknowledged.

That processor and pending-state storage are implemented separately in the
[package-only PH continuation](graphevo-2-history-processing.md). Real crash/power-loss
recovery and CKSyncEngine activation remain unimplemented by this model increment. No typed mutation journal
or interception of every consumer edit is introduced. Retain beta gates for
history pruning/expiry, copied/replaced stores, account/conflict policy and scale.

Apple references: [deletion preservation](https://developer.apple.com/documentation/coredata/nsattributedescription/preservesvalueinhistoryondeletion),
[consuming history](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes).
