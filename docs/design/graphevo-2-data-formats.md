# M2b.1 — detached format contracts and persistence refusal

Status: first public-contract increment after [M2a](graphevo-2-data-migration-local.md).
This is not complete M2b store admission or an enabled public migration manager.
The native S01 shape, identifiers, default openers and legacy manager are unchanged.

## Model and record contract

`GraphRecord.dataVersion: Int64?` is immutable detached metadata. Construction
rejects negative versions. Nil is undeclared, distinct from zero. This is neither
a modification revision, native schema version, codec version nor import proof.
Patches preserve it; changing it requires an explicit new detached record.

`GraphModel.graphDataFormat` defaults to `GraphDataFormat.undeclared`, which reads
and writes only nil. Existing undeclared models therefore retain their behavior.
An explicit declaration supplies a nonnegative `currentVersion`, a finite set of
`readableVersions` containing that version (default: only current), and optional
`acceptsUndeclared` (default: false). A declaration can explicitly read a newer
format, but does not infer that its decoder understands unknown fields.

`GraphRecord.decoded(as:)` checks kind/type and declared readability before invoking
the consumer initializer. `GraphRecord(model)` requires the serializer's version
to equal the declared current version. It does not stamp, convert or downgrade
the consumer's output. `canRead` and `canWrite` are separate: compatible reading
does not authorize rewriting another format. Typed `patch(_:as:)` checks write
compatibility before calling the decoder or editing. Raw detached patches retain
their input version and unknown properties.

Query descriptors capture the model's format policy in their definition, including
cursor/shared-query identity. Native query planning checks selected-type metadata
before property fetch/decode, and detached evaluation checks readability before
predicates/count/projection/aggregate. Non-record queries do not bypass format
compatibility merely because they do not instantiate the application model.

```swift
static let graphDataFormat = try! GraphDataFormat(
    currentVersion: 2, readableVersions: [1, 2], acceptsUndeclared: false
)
```

Declarations are application promises, not content validation. Identity/kind/type,
property decoding, reference resolution, ownership and query budgets still apply.
Direct consumer initializer calls bypass library mapping checks, as before.
There is no public Codable wire format or schema change for GraphRecord.

## Normal persistence remains unversioned

Until a shared store-format registry and lifecycle policy exist, normal insertion
rejects non-nil versions with `GraphStoreError.dataFormatAdmissionRequired`.
This includes raw and typed scoped insertion, the native adapter and shared intent
preparation. A rejection rolls back the transaction; shared intent preparation
refuses before native assignment or journal writes. No version is silently dropped.

On S01, every normal Session and indexed point anchor first checks native version
metadata across all stores in the resource group. Any non-nil version, including
zero, blocks application data access for that resource with the same typed error.
The preflight fetches at most one matching native node per kind, includes pending
edits and fetches no application property rows. The native predicate may still
scan SQLite rows; this is not an indexed-version or total-I/O budget claim.
This adds resource-wide work to S01 point reads; earlier indexed-lookup timings
do not establish this increment's performance or the final admission envelope.

This deliberately conservative resource-wide refusal also covers other graphs,
unrouted rows and loaded private/shared stores. It is temporary, not the final
record/dependency-scoped compatibility policy. It prevents a future/partial native
format from becoming a successful empty point lookup, partial query, file listing
or silently decoded result. Point reads, fetchAll, query/count/projection/aggregate,
traversal, attachments, mutation and integrity paths use those common boundaries.
Observation/Combine retain their existing visible recoverable failure mechanism.
Catalog/control-only status and access reduction remain available; no decoder is
needed to revoke access. Native imports are not intercepted or paused.

The exact package-only M2a physical model identifier is the sole laboratory
exception. Normal public S01 openers still refuse its files. Laboratory snapshots
now expose the native version in the record, and M2a's row projects that same
metadata. Consumer transformations must preserve it; only the manager stamps the
prepared target. The private archive's existing version field/format is retained.

## Validation and remaining work

See the [local validation result](results/m2b1-data-formats-2026-10-30.md) for
test counts, retained development corrections and acceptance limits.

Tests cover absent/zero/future versions, invalid declarations, format refusal
before consumer decoding, explicit older/newer read compatibility without write
permission, serialization and patch preservation. Real SQLite/in-memory probes
cover every node kind, ordinary batch rollback, refusal before shared preparation,
point absence, queries/count/projection, traversal, file access, mutation,
integrity, pending metadata preceding malformed bodies, unchanged control access,
cross-graph conservative refusal, a second local SQLite store with an unrouted
versioned row, and observable failure/recovery. Injected native
metadata and producer repair are local controls, not CloudKit acceptance.

Complete M2b still needs a resource-bound registry shared by all public paths,
write authorization, bounded record/dependency admission, protected-source backup
and retention, process/widget readiness, routing/dependency scheduling and public
migration activation. No versioned production opener is enabled here. M6 covers
later/partial/incompatible cloud arrivals. Mandatory v1 conversion remains M3–M5.
Keep [PA08](graphevo-2-post-alpha-checklist.md#pa08--mandatory-v1-local-and-cloud-migration)
open; a successful DTO conversion is not store activation or beta acceptance.
