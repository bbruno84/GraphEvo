# GraphEvo 2 — consolidation after A1–A8

Status: started 2026-10-27 after A8 PR #77 merged into `codex/graphevo-2`
(`caa12129cd535c2ffd8bfbbf7e302a223d04815a`). Remain alpha: this is the
integration baseline for consolidation, not schema/API freeze or beta entry.
Read the [delivery plan](graphevo-2-delivery-plan.md),
[decision register](graphevo-2-decisions.md) and
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).

## First finding and scope

A1–A8 established functional contracts and native framework feasibility. C01
now measures their combined implementation through a reproducible independent
consumer. This separates correctness from the cost of the candidate storage and
execution strategy. Review the [C01 measurements](results/c01-cost-baseline-2026-10-27.md)
before selecting a replacement representation.

The accepted file identity/exclusive ownership model remains the starting point
(M12). The current content representation and full-inventory execution strategy
are candidates to change. Mandatory v1 data migration, graph/share boundaries,
whole-content source protection and visible partial-import errors remain binding.
Do not publish a larger memory/size envelope just by raising query budgets.

## Measured work and proposed next increments

| Increment | Concrete work | Reviewable exit |
|---|---|---|
| C01 — integrated cost baseline | New temporary local fixtures, isolated Release processes, scalar CRUD/query/list/read and one/eight observer cycles | Retained correctness assertions, diagnostic counters, time/memory/storage scope and prioritized bottlenecks; physical/production limits remain unproven |
| C02 — selective identity/catalog/session access | Prototype targeted metadata/identity access and reuse within an operation; compare retaining the candidate native model with adding queryable native identity/membership fields if required | Fetching/patching one node stops requiring full application-record inventory; graph ownership, duplicate/invalid identity detection, remote changes and snapshot semantics retain an explicit validation route; compare against C01 |
| C03 — attachment metadata/content separation | Prototype metadata-only reads and separate binary storage without JSON/base64 content wrapping; keep file ID/owner/public lifecycle as the starting point | Unrelated scalar queries/counts/projections do not materialize attachment bytes or exhaust a byte budget because files exist; metadata listing avoids full content hashing; actual content reads still validate identity/size/digest |
| C04 — shared observation work | Reuse selective inputs/refresh work where contracts permit; compare shared snapshots and dependency-based invalidation against the conservative A8 baseline | Several observers avoid independent repeated full scans while preserving related/action/file invalidation, cancellation, failure states, per-handle shutdown and each query's explicit budget/view contract |

C02/C03 are closely related and may challenge the schema together. These are
proposed implementation directions, not a frozen native model or an inference
that a transformable value can be indexed as an ordinary scalar. Benchmark
alternative representations before selecting their query capabilities. C04
must retain the correctness of broad invalidation until narrower dependencies
are demonstrated; fewer notifications alone is not a valid optimization.

C01 has no product latency/RAM acceptance threshold. Select such thresholds
from realistic library/application scenarios and physical devices, not from
these synthetic desktop medians. Do not replace the independent consumer with
an app-specific API to meet a benchmark.

## First experiment checkpoint

[C02a](graphevo-2-metadata-experiment.md) compares the baseline with batching all
reserved metadata (A) and persisted-owner batching (B), without schema/API
changes or cross-operation caches. The [result](results/c02a-metadata-costs-2026-10-27.md)
retains 596 timing samples, 469 regression tests, 19 targeted sanitizer tests and
read-only iPad/XR checks. B is preferred on the experiment branch: identity reads
and queries improve substantially and A's insertion regression is avoided.
Observer memory increases in some cases, full inventory remains, and new native
sharing writes have not been revalidated. C02/C03/C04 gates remain open.

## Required checks for candidate changes

- Rerun the same C01 fixture matrix and assertions on the integrated candidate.
  Explain input/measurement changes and retain failed results; do not silently
  loosen budgets, reduce fixture sizes or remove mandatory validation to win.
- Verify all node kinds, endpoint/owner deletion, tags/groups, unknown values,
  null/absent data and identity/reference preservation. C01's Entity-only scalar
  fixtures do not establish the full model contract.
- Use fresh stores for incompatible alpha layouts; retain mandatory v1 mapping/codec feasibility.
  Public attachment metadata and original bytes must remain recoverable; ordinary
  v1 binary values are not implicitly reclassified as owned files.
- Revalidate actual same-account and cross-account mirroring with the selected
  schema. Attachment metadata/content and every new native row must remain in
  the graph's existing share boundary, including participant assignment and
  partial-intent recovery. Native public APIs remain the synchronization owner.
- Preserve complete backups, journal/source protection, access/account handling,
  cancellation and local-view semantics. No persistent cache may treat native
  identity mappings or notifications as import completion or distributed locking.

## Before beta

The [S01 review](graphevo-2-persistent-schema.md) has selected the native shape;
the explicit native factory now adopts it and the
[bounded public device fixture](results/s01-native-sharing-recovery-2026-10-30.md)
passes sharing/files/fresh recovery. Optional consumer-format admission and
broader native acceptance remain open. No further
native columns/entities are planned without concrete correctness or measured
evidence. The historical experiment sections below retain their original scope.

After the cost/representation review, reconcile schema/API and supported query,
file and observer envelopes. Resolve the stable processing contract (O04),
platform/process scope, account/conflict/recovery limitations and alpha-store
policy. Demonstrate representative end-to-end v1 local/cloud migration
feasibility, including the coordinated cutover and returning old devices.
Only then review beta entry. Complete migration tooling, real app adoption and
release acceptance during beta; mandatory data migration cannot become optional.

## First attachment metadata experiment

[C03a](graphevo-2-attachment-metadata-experiment.md) separates metadata/body on
new files and preserves existing envelopes. The [local result](results/c03a-attachment-metadata-costs-2026-10-27.md)
retains 564 measurements and 473 passing tests. Four 10-MiB file listing improves
from about 219 ms to 29–30 ms; sampled process peak falls from 134 to 71 MiB.
Native faulting/memory remain variable, complete reads and query costs are
largely unchanged, and default query allowance still refuses four large files.
The candidate remains isolated: device assignment/import/replacement/conflict
acceptance, coordinated conversion and query body avoidance are still open.


## Executed cost / correctness matrix

The [matrix](graphevo-2-experiment-matrix.md) and
[retained comparison](results/cost-matrix-2026-10-27.md) cover binary storage,
descriptor property dependencies and native row filtering (M03b), plus physical
owner/participant file lifecycle. M02 + M03b is proposed for review: unrelated
large-file queries succeed at unchanged budgets with substantially lower memory,
and full reads are faster. Four-small-file disk usage increases; list/read memory,
indexed identities, real storage envelopes and migration remain open. Observation
benefits from cheaper queries without introducing C04 shared work. This evidence
does not authorize an automatic integration, beta entry or schema freeze.


## Native identity lookup experiment

[C02b](graphevo-2-native-identity-experiment.md) compares optional native UUID
columns with/without a configured index using normal runtime scopes. The
[local evidence](results/c02b-native-identities-2026-10-27.md) selects columns
with bounded endpoint identity/metadata batches and topology prefetch as the next
integration candidate. Entity point reads/patches improve substantially; the
500-reference action improves only after two retained regressing variants.
A configured index adds a smaller gain on these sizes. Default schema/openers
remain unchanged. Missing-column absence, import/old-writer semantics,
private/shared conversion, native sharing and mandatory v1 migration remain
C02 gates; this local result does not freeze the schema. C04 observer work is the
next independent cost investigation after review of this candidate.


## Shared observation experiment measured

[C04a](graphevo-2-shared-observation-experiment.md) tests one explicit laboratory
per handle. Exact query/model/budget shapes share immutable native query records;
application models are decoded independently per subscriber. Broad invalidation,
per-consumer newest buffers, cancellation and Combine demand remain. There is no
result replay, cross-handle grouping or default public observer change. The matrix
separates startup from update wall/CPU costs, includes single and mixed observers,
and measures sampled whole-process RSS on the default model independently of
C02b. Native source cleanup and late-join/account races precede timing acceptance.


The [C04a result](results/c04a-shared-observation-2026-10-27.md) retains 420 timed
matrix/confirmation rows. At 500 nodes/eight equal observers an update wave falls
from 786 to 183 ms; 32 equal observers fall from 3251 to 181 ms. Initial reads
remain proportional to new subscriptions; mixed descriptors remain separate.
Use exact-query native-work sharing as the next candidate for review; no default
public activation, narrower invalidation or replay cache is introduced.


## Selected direction and implementation order

The maintainer accepted the measured direction on 2026-10-29. Stop expanding the
alternative matrix without a concrete implementation/regression question. Keep
experiment checkpoints and measured limitations; acceptance of the direction is
not proof of native/schema/migration readiness.

1. Review C04a and adopt its exact-query native-read coordinator through public
   async/Combine observation in a focused PR. Settle shared local-view identity,
   join/refresh behavior and idle handle ownership explicitly. Keep broad native
   invalidation, independent decoders, per-consumer demand/cancellation and no
   replay cache. PR #83 is merged into the experiment parent; public adoption is
   the next implementation, not a change to the alpha.8 integration tag.
2. Carry selected C02a metadata lookup, M02 binary content and M03b dependency-row
   filtering forward through review of their stacked PRs. Preserve the four-small-
   file disk regression and complete integrity/whole-content backup requirements.
3. Turn C02b native logical identity/membership columns into an integrated design:
   settle missing-column/old-writer/import semantics, private/shared placement,
   point validation and explicit full integrity. Add selective query access where
   a descriptor permits it, and measure startup/different-query behavior through
   public APIs. The package-only alternative opener is not a public schema choice.
4. Validate the combined implementation on representative local and native
   owner/participant workloads, including files, account/access transitions and
   mandatory coordinated v1 migration feasibility. Reconcile API/schema and
   beta gates only after that evidence.

The first public-observation increment leaves native schema, opening and file
ownership unchanged. Its comparison retains the historical independent worker
as a package-only control and runs the selected mode through public `observe`.
Startup and mixed-query latency remain visible follow-ups, not hidden by caching
old results or broadening query allowances. A draft PR can make this behavior
reviewable while physical/native and heavy-decoder adoption gates remain open.


## First selective-materialization increment

Before adopting native identity columns, optimize ID-guarded queries on the
current layout. Keep complete structural inventory but avoid same-model property
rows/bodies that a leading finite ID guard rejects. Related/traversal queries and
property-before-ID Boolean evaluation remain conservative. This improves a
well-defined public query path without changing schema, absence, sharing or
migration contracts. See the [query contract](graphevo-2-queries.md#c02-consolidation-identity-guarded-materialization).

Compare the public observer path against the retained pre-change Release binary
on copies of one closed seed. Include equal/mixed descriptors, one/eight/32
subscriptions, startup separately from update and unchanged candidate budgets.
Keep mixed and single-observer overhead even if it regresses; do not turn reduced
body materialization into a claim of indexed SQL access or a bounded total heap.
The selected C02b native schema still requires its distinct integration gates.


## Native identity integration started

The [integration contract](graphevo-2-native-identity-integration.md) fixes the
validation boundary before public schema adoption. The first increment closes
the laboratory's false-negative lookup: audit same-view identity metadata before
returning nil, reject missing/misrouted projections and known staged rows, and
retain full payload integrity as a separate explicit operation. A native
transformer poison probe verifies that the metadata audit does not read unrelated
application bodies. Negative reads now intentionally have an inventory cost.

The next increments must maintain projections through all writers and explicit
protected-source conversion/recovery, then verify native private/shared import
and conversion before selecting mirrored schemas or indexed query execution.
Default public openers, the native model and alpha.8 remain unchanged here.


## Reviewed consolidation merges and writer increment

#84/#85/#86 were reviewed against their exact heads, with successful macOS/iOS
CI, and merged through GitHub into the experiment/consolidation parent. Merge
commits are `e2f6323`, `33225aa` and `0b933dd`; prospective and actual merge trees
match reviewed content. These merges preserve all measurement checkpoints and do
not move `codex/graphevo-2` or `2.0.0-alpha.8`.

The next increment wires native projection maintenance into common row/control
creation, ordinary writes and shared staging/finalization preflight. The
[writer contract](graphevo-2-native-identity-integration.md#common-writer-projection-maintenance)
keeps default models/openers unchanged and distinguishes local common-writer
coverage from native-column physical sharing acceptance. The next layout-adoption
component is fresh-store opening/validation under M13, followed by fresh native
private/shared acceptance. Alpha conversion tooling is not required.


## Fresh alpha stores — maintainer decision (2026-10-29)

M13 supersedes earlier alpha-conversion steps in this plan: start the new native
layout from empty stores. Do not implement alpha-to-alpha conversion/backfill or
interruption recovery as a public-adoption gate. Retain old probe evidence as
history. Next: create/validate fresh local stores, then controlled fresh mirrored
private/shared fixtures, while maintaining writer, query and observation guards.
Mandatory v1 local/cloud migration remains separate. No automatic erasure of
incompatible existing files or CloudKit data is introduced.


## Fresh native local opening

The next reviewed increment explicitly selects `GraphDatabaseSchema.nativeIdentity`
for local SQLite/memory resources, with distinct public protocol activation and no
alpha conversion. The shared persistence resolver replaces production dependence
on the old laboratory enum. Existing defaults and mirrored paths are unchanged;
fresh paired native initialization is the next acceptance step. Explicit storage
integrity validation, guarded reads and bounded queries retain distinct scopes.
