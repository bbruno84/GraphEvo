# GraphEvo 2 — native identity integration

Status: fresh local native identity layout available as an explicit alpha schema
selection. Default/current and mirrored opens retain the prior model. The shared
resolver preserves audited absence and common writers; native paired acceptance
remains open. C02b's original weaker miss is retained only as historical evidence.
Read the [prototype](graphevo-2-native-identity-experiment.md),
[query contract](graphevo-2-queries.md) and [post-alpha checklist](graphevo-2-post-alpha-checklist.md).

## Identity and validation scopes

Logical GraphID/GraphNodeID remain persistent UUID values. Native graph/node
String columns are queryable routing projections, cross-checked against archived
logical identity metadata. Never derive identity from Core Data URIs or native
CloudKit mappings. A configured compound index supplies no global uniqueness or
cross-replica completion guarantee. Optional native fields are selected only by the explicit local native schema;
default and mirrored opens remain on the previous model.

| Operation | Evidence and outcome |
|---|---|
| Native point hit | Validate the matched target, native/raw identity, membership and referenced endpoints; detect native-column duplicates across every node kind. This is not a whole-graph integrity certificate. |
| Native point miss | Audit the complete logical/native identity inventory on the same context/local view before returning nil. Missing, mismatched, malformed, duplicate or misrouted columns are errors, not absence. No persisted activation marker substitutes for this check. |
| Known staged rows | A valid staged row in the selected graph makes the absence audit fail with pendingNativeOperation, even when its native columns have not arrived. Do not infer import progress from an arbitrary missing field. |
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

## Fresh-store alpha policy

Maintainer decision, 2026-10-29: start each incompatible alpha layout from an
empty store. Alpha-to-alpha conversion, downgrade compatibility, identity
backfill tooling and interrupted alpha-conversion recovery are not delivery
gates. The next increment creates and validates the selected native layout on
fresh local resources, then fresh controlled private/shared fixtures.

This does not authorize ordinary opens to erase an existing incompatible path
or cloud database. They retain explicit incompatibility errors. Fresh local
files alone do not certify empty remote data; mirrored acceptance uses controlled
fresh test state. The existing copy/backfill prototype remains historical
laboratory infrastructure, not a required alpha migration product.

Mandatory v1-to-v2 migration remains separate: preserve data, logical mappings,
references and file bytes with protected sources/backups and coordinated stopped
v1 writers. Demonstrate representative local/cloud feasibility before beta and
complete migration tooling before stable 2.0. Beta data compatibility follows
the delivery plan; this decision concerns disposable alpha stores.

## Increment order

1. Close false absence and split metadata audit from full integrity; add staged,
   missing/misrouted and malformed-body regressions, retain changed costs.
2. Wire all writers into the fresh-store layout. Revalidate normal leases,
   attachments, high-degree actions and opening/validation on empty local stores.
3. Verify fresh native private/shared schema/import, assignment, cross-user
   mutation and recovery before selecting the layout for mirrored opens.
4. Add selective query execution only where row coverage and related dependency
   bounds are established. Re-measure public startup/mixed descriptors and
   complete v1 migration feasibility; do not freeze schema or enter beta early.


The [first retained result](results/native-identity-readiness-2026-10-29.md)
records 504 tests, 16 sanitizer tests and 120 focused Release rows. Safe native
absence on 500 nodes costs about 52 ms; positive indexed hits remain 2.6–3.5 ms.
These are local validation scopes, not interchangeable production guarantees.


## Common writer projection maintenance

After the reviewed #84/#85/#86 merges into `codex/v2-cost-experiment-matrix`
(`e2f6323`, `33225aa`, `0b933dd`), the common typed writer maintains projections
when the explicitly selected model contains both optional String columns on all
three node kinds. A schema with partial/mixed column definitions is rejected.
Default Model.makeModel still has neither column, so public opening and persisted
model hashes remain unchanged.

New application rows receive their existing logical UUIDs in native columns in
GraphTypedStoreAdapter.stamp, before membership links or assignment. New roots
and membership controls receive the graph UUID and a nil node UUID. The prototype
no longer rescans after each insert to stamp columns as a special workaround.
Application fields remain ordinary detail properties; native identity columns do
not appear in detached records.

A persisted row's projection is validated rather than filled or repaired.
Common writer admission validates graph controls and current graph projections,
rejecting incomplete staged state unless completing the explicit native operation.
Normal record lookup validates its target. Patch/replacement preserves IDs;
delete/cascade removes the same rows and preserves surviving action identities.
Explicit conversion/backfill remains the only path that may populate existing
missing projections after validating a protected source.

Shared staging preflights the model before journal reservation, and uses the same
new-row stamp. Finalization revalidates root/membership/staged and already-committed
rows before linking or clearing intent. Native assignment remains exclusively
owned by NSPersistentCloudKitContainer; no retry/replay or synthetic share claim
is added. Default-schema behavior remains unchanged. These hooks do not establish
native-column private/shared import or real-device assignment acceptance.

The package-only laboratory adds `fullAdapter: true` to exercise common public
GraphDatabase/GraphStore operations on the candidate model, independently of the
old targeted mutation prototype. Point reads retain the same guarded native
hit/miss path in both modes; the option changes mutation adapters, not absence
safety. Local acceptance covers all node kinds, pending
reads/rollback, file import/replacement, implicit edge/file cascade, surviving
actions, independent graphs, integrity checks and reopen. It also verifies that a
bad persisted projection cannot be repaired by stamping/patch/deletion, and a
partial model fails before control creation or raw logical identity edits.

Fresh local opening now selects this model explicitly. Native paired-store
acceptance remains before mirrored selection. Prior alpha conversion tooling is
not required under the maintainer's fresh-store policy. Projection maintenance alone does not
select the default schema, enter beta or promote an integration/tag.


Local writer acceptance passes 507 full tests (322 legacy, 101 store, 61 runtime,
23 model) and 31 selected sanitizer tests. The full-writer point path also rejects
an injected incomplete imported row, refuses a normal patch while it is staged,
and resumes valid absence only after fixture cleanup. This is deterministic local
coverage, not native CloudKit import/assignment acceptance.

The [writer acceptance record](results/native-identity-writers-2026-10-29.md)
separates 507 local tests, 31 targeted sanitizer tests and the Release functional
probe from physical native-column sharing/conversion acceptance.


## Fresh local native schema API

The local adoption increment offers explicit `GraphDatabase.open(at:schema:)`
and `inMemory(schema:)` selection with `GraphDatabaseSchema.nativeIdentity`.
No-schema/current opens and existing mirrored opens keep their prior schema;
this is an explicit local alpha option, not a silent default-model replacement.

A shared GraphNativeIdentityAccess resolver now lives in persistence code. Its
persisted marker distinguishes fresh public `nativeIdentityLayout = alpha.1`
controls from historical laboratory `nativeIdentityPrototype = local.1` controls,
although their native column shapes can match. Public creation activates only
new, empty, unstaged controls with valid projections. No backfill/copy/migration
path is called by the public native opener. Historical helpers remain package-only.
Old/current incompatible models and old prototype markers are refused; their
original paths/data remain available to their original reader.

Point reads retain the audited native hit/miss contract. All ordinary writes use
the common typed adapter, with graph protocol checks before operations. Bounded
queries still inventory the resource group, preserving existing allowances,
related dependencies and property materialization semantics. Snapshots validate
native projections for consulted nodes, even when their payload is skipped.
Only the explicit historical backfill scope can read unprojected source snapshots.
Metadata attachment listing validates native identity inventory without reading
file bodies. No indexed SQL query or total-memory promise is introduced.

`GraphDatabase.validateIntegrity(of:)` is explicit and works with current and native
local schemas. It validates storage-level graph identities, endpoints and payloads,
including attachment content/ownership, without invoking app model decoders. It
returns application-node count and is separate from query budgets, metadata-only
listing and native import completion. It can materialize complete large files.

Local acceptance includes fresh SQLite/in-memory stores, empty catalog, multiple
graphs, independent leases, files and reopen; refusal of current/prototype data
without conversion; projection corruption surfaced by point/query/integrity and
observed failure/recovery. An external Swift 6 Release consumer exercises the
public product, native opening, typed model, query, Combine and reopen without
package/test access.

Native-column mirrored initialization/assignment/import and physical private/shared
acceptance remain the next step. Local selection does not make a fresh local path
proof of an empty cloud container. M13 removes alpha-conversion work; mandatory
v1 data migration and beta compatibility remain separate release requirements.
