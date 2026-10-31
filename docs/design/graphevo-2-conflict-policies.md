# GraphEvo 2 — T03 automatic record conflicts

Status: package-only implementation on `codex/v2-conflict-policies`, directly
from reviewed/merged #114 (`4e9d30c`). This contract supersedes T01's conservative
same-record refusal; T01/T02 reports retain their original runtime and scope.
Native **S03 is unchanged**. No public custom-cloud opening is introduced.

## Policy and edit metadata

`GraphConflictPolicy` has `cloudWins` and `lastEditWins`. The latter is the default.
`GraphContextManager.createGraph(id:at:conflictPolicy:)` selects the initial policy.
A graph handle reads `conflictPolicy` and changes it through
`setConflictPolicy(_:)`. These APIs are package-only. The hidden root persists
`__graphevo_v2.conflictPolicy` locally; all handles share the same choice, including
after reopen. Absence means lastEditWins; malformed metadata is refused. Policy
changes take effect at the next resolution, do not edit records/dates/queues and
are not synchronized. Different replicas may intentionally have different policies.

The context-confined consumer mutation tracker records actual Entity, Relationship
and Action edits. Before save, one injected-clock instant becomes their reserved
`__graphevo_v2.modifiedAt` property. It includes surviving actions changed by endpoint
deletion. No-op patches do not refresh it; rollback and pre-save cancellation roll
back both body and date. Imported changes, receipts, retries and policy changes do
not invoke this tracker. The internal clock is injectable for tests only. PH reads
never manufacture edit dates. Application `GraphRecord`, typed properties and the
native model remain unchanged; consumers cannot write reserved metadata.

## Wire compatibility and ordering

GraphEvoNode keeps the same record type and CloudKit fields. Wire **format 2** adds
an optional modifiedAt to its internal payload. Format 1 remains readable and has
unknown date, regardless of payload contents. Invalid/nonfinite dates are rejected.
No date is synthesized from createdDate or opening time. A known date beats an
unknown date; equal dates and two unknown dates choose cloud. CloudWins always
chooses cloud for competing saves. Resolution replaces an entire logical record,
including endpoints, tags and groups; there is no property merge/resolver callback.

Dates use device wall clocks. This is not a global temporal order, distributed
clock correction, or protection against clock skew. Import without pending local
work follows ordinary remote application, even if the imported date is older.
A known nonempty server change-tag echo never clears newer pending local work.

## Durable conflict resolution

Native serverRecordChanged receipts retain the validated server archive before
engine state advances. Under the graph writer gate, reconcile PH and inspect the
**current** local body/date and current policy, rather than the frozen attempt's
body. Group all retained receipts for the same send before retiring its attempt.
Successes acknowledge only the original matching generation; ambiguous successes
require both full body and modifiedAt to match the original frozen save.

In the same native save, persist the chosen data/date, latest server system fields,
pending generations and idempotent receipt fingerprint. A cloud winner clears the
competing current pending save. A local winner preserves its current body/date and
pending generation, learns the server base and retires the stale attempt. A later
prepare freezes the current value against that base. Neither arbitrary consumer
closures nor historical mutation bodies are replayed.

A manual send permits at most two native invocations: the initial selection and
one targeted retry of rebased IDs only. A second collision remains pending. Other
failures remain explicit and prevent the targeted retry. `resolvedConflicts` counts
resolved competing events, including a repeated collision; it is not a unique-node
or publication count. `succeeded` counts confirmed native successful receipts;
`pendingRetry` identifies unresolved rebased work. `cleanupPending` and transport
errors retain T01 meanings. Applying an inbox may resolve locally without uploading.

## Delete wins and structural limits

Remote deletion beats a pending update; pending local deletion beats a remote
save under either policy. An unknownItem for a save previously carrying a native
server change tag is remote deletion, not permission to recreate. An unknownItem
for an unassociated new save remains an error. Native delete unknownItem still
confirms absence. Deleted IDs are not reusable: application recovery uses new IDs.

The root's local `__graphevo_v2.deletedNodeIDs` trace survives acknowledgement and
restart. It rejects old saves after deletion; within an inbox cut a deletion also
dominates any later stale save for that ID. Supported native cascades still apply.
If applying a choice changes other pending primitives through inverse/cascade
effects, or lacks dependencies, the entire resolution transaction fails visibly
and retains data, pending work and receipts/inbox. General multi-node structural
resolution is deliberately not implemented.

## Alpha state and bounds

The engine session document is **format 3**, native graph transport state **format
2**. Incompatible alpha state is refused unchanged; use new fixtures, without
resetting the test container. This is separate from mandatory v1 data conversion.
Bindings remain graph + complete zone identity, without persisted sandbox paths.
Native store UUID and PH epoch retain their validation role.

Transport plus deleted-ID encoded data share a 32 MiB ceiling. Existing limits of
100,000 server metadata entries, 4,096 retained receipt fingerprints and 100 records
per new attempt remain; the deleted-ID trace is separately limited to 100,000 IDs.
Session count/byte budgets include retained server archives in failed receipts.
Reaching a bound refuses the operation atomically; no automatic pruning or reset.
These are encoded-state/count ceilings, not measured production resource envelopes.
Metadata cost, full-map rewriting and unbounded-lifetime deletion retention need
post-alpha measurement and a safe retention strategy before stable acceptance.

## Evidence and remaining gates

Deterministic tests cover policy/date ordering, missing/malformed dates, shared
policy persistence, no-op/rollback/cancellation, implied action edits, current local
3→4 versus frozen 3, grouped partial receipts, bounded retry, import feedback,
deletions/old events/ID reuse and incompatible state refusal. Existing transport
fault and structural refusal tests retain their atomicity/restart coverage.

The [physical T03 result](results/conflict-policies-cloudkit-2026-10-31.md) separates
native CAS proof from injected bus tests. Assets, sharing/permissions, automatic
scheduling, skew mitigation, power-loss/backup recovery and broad structural
conflicts remain open. These bounded successes do not close the full beta gates.
