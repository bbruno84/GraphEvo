# GraphEvo 2 — native identity integration

Status: staged alpha integration after review of #84/#85. C02b proved useful
local point-access costs but its original index miss could hide missing columns.
This contract defines the next implementation boundaries. The first increment
closes that unsafe absence result within the package-only laboratory; it does
not change default schemas/openers or assert CloudKit conversion readiness.
Read the [prototype](graphevo-2-native-identity-experiment.md),
[query contract](graphevo-2-queries.md) and [post-alpha checklist](graphevo-2-post-alpha-checklist.md).

## Identity and validation scopes

Logical GraphID/GraphNodeID remain persistent UUID values. Native graph/node
String columns are queryable routing projections, cross-checked against archived
logical identity metadata. Never derive identity from Core Data URIs or native
CloudKit mappings. A configured compound index supplies no global uniqueness or
cross-replica completion guarantee. Optional native fields remain a candidate;
this document does not activate them on public opens.

| Operation | Evidence and outcome |
|---|---|
| Native point hit | Validate the matched target, native/raw identity, membership and referenced endpoints; detect native-column duplicates across every node kind. This is not a whole-graph integrity certificate. |
| Native point miss | Audit the complete logical/native identity inventory on the same context/local view before returning nil. Missing, mismatched, malformed, duplicate or misrouted columns are errors, not absence. No persisted activation marker substitutes for this check. |
| Known staged rows | A valid staged row makes the absence audit fail with pendingNativeOperation, even when its native columns have not arrived. Do not infer import progress from an arbitrary missing field. |
| Metadata identity audit | First reject unroutable native rows across the resource group, then check this graph's routing identities, existing membership/format metadata and exact backing-row coverage; no application property bodies are decoded and no IDs are repaired. A malformed unrelated app body does not prevent an otherwise valid metadata absence check. |
| Full integrity | Add complete payload, endpoint and attachment-owner validation. This is separately invoked/timed and remains distinct from the metadata audit. |

An unlinked partial row can lack both archived and native graph IDs. A per-graph
filter alone cannot see it. The negative audit therefore first checks native
projection readiness across the resource group, reading only node-native fields.
An unroutable row blocks absence conservatively even when its eventual graph is
unknown. A known staged row in the selected graph reports pendingNativeOperation;
other missing/malformed routing fields are errors, not inferred import progress.
Foreign application bodies/format metadata remain unread by this native readiness
pass. Its additional resource-wide cost is included in negative lookup timing.

A valid miss is only absence from this local view. It does not certify another
replica, a completed import, a deletion or a tombstone. Query-generation pinning
and mutation scopes retain their existing runtime semantics. No audit result is
cached across scopes/generations or used as a cloud certificate. On hits,
unrelated raw identity damage still belongs to explicit whole-inventory/full
validation; do not claim a new global uniqueness guarantee.

The first implementation tightens the laboratory's negative read: an index miss
now performs metadata inventory validation. Found-node costs remain targeted;
missing reads intentionally acquire an inventory cost. Retain the original fast
but weaker missing measurements as history and measure this stronger contract
separately. Full payload validation must not be substituted for metadata audit:
that would unnecessarily decode unrelated large files and conflate guarantees.

## Writer and import invariant before public adoption

Every admitted writer must maintain native projections with logical metadata on
its own context before rows become visible: Entity, Relationship, Action, hidden
root/membership, attachments and assignment/staging/recovery paths. Preserve
pending insert/update/delete views, serialized writes, rollback, graph boundaries
and participant assignment intent. A property-only patch cannot rewrite logical
identity. Full validation must detect old writers or damaged projections.

An import may expose incomplete local state. Query observation must surface a
recoverable failure rather than issue a smaller successful result through an
incomplete index. A native hint can request a rescan; it cannot certify that
columns are complete. Do not silently regenerate UUIDs, backfill imported rows,
replay native share assignment or switch to a second native persistence owner.

Default A7 queries retain complete bounded inventory plus identity-guarded
property selection. Selecting native rows for queries requires a separate
proof of row coverage and dependency correctness; candidate allowance must
still account for its documented resource group. Do not advertise indexed SQL
queries merely because point operations can use native identity columns.

## Explicit conversion with protected source

Public migration tooling is a later increment. Its implementation must provide:

1. A quiescent closed source with coordinated stopped v1/external writers, runtime
   ownership exclusion and a whole-directory backup including external content,
   auxiliaries and operation ledgers. Do not modify the original source or use an
   ordinary open to trigger incompatible model migration.
2. An owned new destination and explicit conversion state: prepared, native model
   conversion, identity backfill, validation, activation, ready. Persist enough
   source/destination/model identity to diagnose interruption without guessing
   that a partially produced destination is usable. Protect identity transports.
3. UUIDs from the archived logical IDs, exact node kinds/references, tags/groups,
   dates, null/opaque values, attachment metadata/ownership/content and native
   bookkeeping preserved or explicitly rejected. Activation occurs only after
   complete validation of the intended resource set.
4. Failure leaves source/backup intact and an unpublished destination available
   for diagnosis. Retrying/resuming must prove the exact phase is safe; do not
   replay a failed native mutation or silently adopt partial backfill. Recovery
   must not move the public source path before conversion is accepted.

For already-v2 sources, preserve archived logical UUIDs exactly. A v1 source may
not have them: allocate and durably record its logical-ID mapping once before
native projection/backfill. Legacy identifiers may be mapping lookup keys, never
a URI-derived UUID representation; restart must reuse the same recorded mapping.
Preserve all application values and references through that mapping.

The existing local prototype already exercises explicit copy-to-new-destination
mapping and rollback/backfill, but is not complete migration tooling. Conversion
of CloudKit private/shared pairs must first be verified using supported native
framework behavior. Do not assume that copying or independently migrating a
mirrored SQLite file preserves its share identity/export history. That procedure
remains a feasibility gate, not a settled promise in this document. Mandatory
v1 local/cloud migration, returning old clients and coordinated cloud cutover
remain binding. Demonstrate representative local/cloud migration feasibility
before beta; complete and validate mandatory migration tooling before stable 2.0.

## Increment order

1. Close false absence and split metadata audit from full integrity; add staged,
   missing/misrouted and malformed-body regressions, retain changed costs.
2. Wire all writers and local explicit conversion/activation/recovery into a
   reviewed integrated layout. Revalidate normal leases, attachments and high-
   degree actions, then expose the supported local opening/validation contract.
3. Verify native private/shared schema/import/conversion, assignment, cross-user
   mutation and recovery before selecting the layout for mirrored opens.
4. Add selective query execution only where row coverage and related dependency
   bounds are established. Re-measure public startup/mixed descriptors and
   complete v1 migration feasibility; do not freeze schema or enter beta early.
