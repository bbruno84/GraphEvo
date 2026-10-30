# GraphEvo 2 — selected persistent schema (S01)

Status: native target selected on 2026-10-30 after reviewing queries,
attachments, sharing and migration evidence. Explicit `.nativeIdentity` runtime
openings now adopt this shape. Application-format APIs/admission and mandatory
v1 conversion remain separate implementation work; model adoption is not a
data migration or beta admission decision.

## Native model

Retain the v1 model's twelve entities: Entity, Relationship and Action, each
with its existing property, tag and group entities. Retain the existing
attributes, relationships, inverses, optionality and deletion rules. In
particular, `createdDate` remains optional and property `object` remains a
transformable value with external binary storage enabled. Actual external
placement remains Core Data's decision.

The complete selected native delta from v1 is three attributes on each of
`ManagedEntity`, `ManagedRelationship` and `ManagedAction`, plus one compound
index per node kind:

| Attribute | Native type | Optional / default | Meaning |
|---|---|---|---|
| `ge2GraphID` | String | Optional / none | Canonical logical graph UUID projection |
| `ge2NodeID` | String | Optional / none | Canonical logical node UUID projection |
| `ge2DataVersion` | Integer64 | Optional / none | Consumer-declared application record format version |

Retain the existing binary-collation `(ge2GraphID, ge2NodeID)` index named
`<entityName>_ge2_identity` on each node kind. Do not add uniqueness constraints,
native per-property query indexes, version indexes or required relationships.
Local indexes do not establish CloudKit server indexing or uniqueness.

Native optionality permits migration and incomplete imports; it does not relax
the logical identity invariant. Application records require validated graph/node
identities. Existing hidden catalog roots and membership controls retain their
documented projection rules, including a missing native node ID where required
by the control protocol. Native projections are checked against logical identity
metadata; they do not replace that metadata or derive identity from local URIs.

The existing optional `appDataVersion` on property rows is retained. It is a
legacy property-level field, initially stamped from store configuration, not an
equivalent record-level version. Do not rename it, reinterpret its historical
values or automatically copy them into `ge2DataVersion`.

No new native entity, other attribute, index or relationship is selected for 2.0.
Graph catalog/membership, attachments and migration bookkeeping use the existing
representation and local ledgers described below.

## Record version contract

`ge2DataVersion` is optional application-format metadata, scoped to the declared
logical node kind/type contract. It is neither the app release number, native
model version, GraphValue codec version, modification counter nor migration ID.
Versions are nonnegative Int64 values. `nil` means **not declared**, with no
implicit latest-version or legacy-zero interpretation; zero has meaning only
when explicitly declared by that consumer contract.

Versioning remains opt-in. Unversioned consumer models are still supported.
A versioned consumer must explicitly classify undeclared legacy records and
register supported formats/conversions. Library-owned control and attachment
formats continue to use their own versioned protocols; do not stamp them with
an unrelated consumer version.

Migration writes the declared version with the converted values in one local
transaction. Compatible edits preserve the format declaration; reading a newer
record must never silently downgrade it. Optional minimum-reader/minimum-writer
compatibility information may use reserved logical metadata with an independently
readable, stable encoding. No additional native compatibility columns are needed.
Compatibility is an explicit, tested declaration within one format family, not
a conclusion derived from numeric version ordering alone.

Native imports can deliver a node, its property rows and related metadata at
different times. A version column is an early discriminator, not a certificate
that all values belong to that version or that the graph is complete. The data
migration/admission implementation must validate the required versioned units
and revision/content evidence, using reserved metadata where necessary, before
interpreting a transition as complete. Metadata that controls admission must be
readable without decoding an unsupported application body. The detailed protocol
and its partial-import tests remain implementation gates.

Unknown/future or partially imported formats are retained and exposed through
explicit pending/incompatible/update-required outcomes. They must not silently
disappear from a successful complete query or aggregate. A declared compatible
reader/writer may continue only under its tested policy, preserving unknown data.
An old client may change known fields while leaving newer metadata untouched:
the column does not identify the last writer or enforce remote client behavior.

## Cross-area review and retained choices

| Area | Selected representation | Evidence and remaining limits |
|---|---|---|
| Queries | Keep encoded property rows, selective requested-property materialization, explicit candidate/payload allowances and the graph/node point-lookup index. No scalar columns or new query entity. | [Cost matrix](results/cost-matrix-2026-10-27.md), [guarded query materialization](results/identity-guarded-queries-2026-10-29.md) and [native identity integration](graphevo-2-native-identity-integration.md). Property predicates/counts/projections remain bounded inventory plus memory evaluation, not arbitrary indexed SQL execution. Broad candidate scans, mixed observers and production envelopes remain PA06/PA07 work. |
| Attachments | Keep a separately identified logical attachment Entity, exclusive same-graph owner, split metadata/content values and existing external-storage support. Keep size, digest and revision in the versioned attachment representation. | [A6](graphevo-2-attachments.md) and the cost matrix retain full-read integrity, replacement and native assignment evidence. Metadata listing does not certify content availability. Do not add native blob/path/hash/owner tables. PA05 still covers representative sizes, conflicts, offline behavior and complete backups. |
| Sharing | Keep paired private/shared resources, hidden roots/membership links and native share assignment. Local intent ledgers remain resource-bound recovery records. | [A5](graphevo-2-user-sharing.md) and [public native mirrored adoption](results/native-public-mirrored-schema-2026-10-29.md). Do not persist substitute zone/permission/sync-status columns as authority. Native mappings, setup, local persistence and independent recovery remain separate observations; account/revocation/recovery gates remain open. |
| Migrations | GraphEvo owns native Core Data schema transitions; the consumer manager owns application-data plans. Add only optional node-format version storage; keep durable operation/checkpoint state in local versioned journals and destination effect metadata. | [SM01–SM03](results/schema-migration-2026-10-30.md) supports the additive shape and final staged-handler replication on the tested fixture. Native schema migration is not complete logical v1 conversion, import exclusion or an exactly-once guarantee. PA08 remains open. |

Attachment metadata and content may arrive separately; existing revision/digest
checks and explicit pending states remain necessary. A different native table
would not by itself make their cloud import atomic. Whole closed resource
directory backups must include external content and operation ledgers, not just
SQLite/WAL/SHM.

Migration progress, retry intent and application compatibility need not become
native schema columns. Existing reserved property storage can carry versioned
effect/format metadata; a local ledger alone cannot prove a data commit. Durable
processing of later old-format imports remains a separate M6/O04 contract.
The package-only journal proposal in PR #95 must be aligned with the
consumer-data-only boundary before integration; its earlier consumer-native-schema
registration proposal is superseded.

## Adoption and migration work remaining

The explicit native factory now selects `GraphEvo.v2.schema.1` for local,
in-memory, private-only mirrored, paired mirrored and local read-only native
openings. Existing alpha.2, unversioned and incorrectly labeled same-shape files
are refused before native loading, without conversion, relabeling or erasure.
Default `.current` opening paths still use the original model. Historical
laboratories retain their identity-only or separately versioned factories;
the versioned migration fixture has the same entity hashes as S01.

Adoption status and remaining work:

1. **Implemented:** optional version attribute, uniform shape validation and
   stable physical-model identifier `GraphEvo.v2.schema.1` in the native factory.
   App/alpha/beta release names must not change a physical schema identifier
   without a model change. Keep logical layout and codec versions independent.
2. **Implemented local controls:** exact attributes/types/optionality/defaults/
   indexes and model hashes, malformed/mixed-shape rejection, local CRUD/files/
   reopening, offline paired routing and read-only selection. Durable source
   SQLite/WAL bytes, other artifacts and companion-path noncreation are checked
   across incompatible opening shapes. Metadata reads may refresh volatile SHM;
   see the [adoption result](results/s01-runtime-adoption-2026-10-30.md).
   Offline containers do not establish actual native assignment or replication.
3. **Open:** implement application-format declarations and admission in the data manager,
   including atomic local version/value writes, undeclared/future formats,
   compatible partial edits and mixed/out-of-order remote imports. Do not expose
   a field as a working compatibility gate before these behaviors exist.
4. **Implemented bounded native acceptance:** [S01 public iPad/XR result](results/s01-native-sharing-recovery-2026-10-30.md)
   passes the entity/attachment lifecycle and two fresh participant recoveries,
   with actual S01 metadata on all eight resources. Source protection and broader
   native account/conflict/node-kind and data migration gates remain separate;
   this does not accept every final model/data behavior.
5. **Open:** complete the mandatory v1 mapping: identities, catalog/membership, property
   codecs, topology, tags/groups/dates and binary content. Preserve unknown or
   corrupt source material with explicit findings. Adding columns alone does
   not activate a valid v2 graph. Where v1 did not encode original graph
   ownership, require an explicit assignment policy; do not invent it from
   business keys, local URIs or the current contents of a merged cloud store.

Incompatible alpha data can start fresh under M13, without automatic erasure.
V1 data migration remains mandatory. Cloud cutover still requires coordinated
stopping of v1 writers and a supported policy for pending writes/returning old
devices. NSPersistentCloudKitContainer owns import/export; the manager cannot
claim a native cloud pause, pre-import interception or distributed lock.

## Change discipline and beta gate

S01 replaces the open-ended native-schema candidate decision. No further native
changes are planned for 2.0. Reopen this decision only for a concrete correctness
requirement or measured limitation that cannot reasonably be handled by the
selected representation. Record the reason, native/logical migration effects
and local/cloud verification plan before adopting such a change.

Logical metadata and application formats may evolve under explicit versioned
contracts without changing native entities. This does not make those changes
migration-free. S01 does not freeze every public API or close beta admission:
[PA01/PA05/PA06/PA07/PA08](graphevo-2-post-alpha-checklist.md) still require actual
adoption, supported performance envelopes and migration feasibility. Supported
beta data requires a documented migration path for subsequent incompatible
changes. Production CloudKit deployment and stable-release acceptance remain
separate gates.
