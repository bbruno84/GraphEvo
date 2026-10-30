# GraphEvo 2 — delivery plan

Status: initial plan, 2026-10-26. Read with the
[specification](graphevo-2-specification.md) and
[decision register](graphevo-2-decisions.md).

2026-10-30 schema milestone: [S01](graphevo-2-persistent-schema.md) fixes the
native 2.0 target following the query/attachment/sharing/migration review.
The runtime adoption increment now supplies the optional record-version field
and stable physical-model ID `GraphEvo.v2.schema.1` for explicit native openings.
Next complete consumer-format admission and mandatory v1 conversion; retained
selected-model device checks remain a separate gate. Default/current openers
retain their original model. Native adoption is not beta entry or completion of
migration work.

## Release policy

Develop directly toward 2.0 through alpha and beta releases. Keep v1 fixes on
the v1 integration/maintenance line. The agreed branch layout is:

| Branch | Purpose and PR destination |
|---|---|
| `develop` | V1 integration and maintenance until stable 2.0 promotion; v1 work returns here |
| `codex/graphevo-2-design` | Specification/planning parent; its documentation-only PR continues to target `develop` |
| `codex/graphevo-2` | V2 integration, initially branched from the planning branch with the agreed documents |
| `codex/v2-<topic>` | Focused work from v2 integration, with PRs back to `codex/graphevo-2`; first increment `codex/v2-store-runtime` |
| `release/2.0` | Created from v2 integration at the beta gate, accepting stabilization fixes |
| `master` | Latest stable release, promoted through a release PR |

Alpha tags identify reviewed commits on `codex/graphevo-2`; beta tags identify
commits on `release/2.0`. Creating `release/2.0` from v2 integration is an explicit
exception to the normal v1 rule of branching releases from `develop`, recorded
in [AGENTS.md](../../AGENTS.md). Do not create the release branch or publish tags
as a side effect of preparing the integration/feature branches.

Assess relevant v1 fixes individually for forward-porting to the new
architecture. V2 release corrections return to the v2 integration branch.
After stable release readiness and review, promote 2.0 into `master` and
`develop`; unfinished v2 code does not enter the v1 integration line. The design
PR remains documentation-only. Do not merge it as an implicit implementation
release. Package distribution details remain to settle before the first alpha.

Each alpha is a coherent usable increment with its model/API revision and
known limits recorded. Alpha stage numbers below are planning milestones,
not a promise of one prerelease tag per stage. Remain alpha through stage 8.

## Integration checkpoint — 2026-10-27

| Area | Current status |
|---|---|
| A1–A7 | Reviewed and merged into `codex/graphevo-2` through PRs #70–#76: runtime, async scopes, models/typed CRUD, graph boundaries, user sharing, files and queries |
| A8 | Reviewed and merged through PR #77, including both concurrency corrections; async current state, Combine and live rescan hints have retained local and cross-account dependency/deletion evidence |
| Consolidation | Started with [C01 and the C02a metadata experiment](graphevo-2-consolidation.md); the B candidate remains on the experiment branch. Content separation, shared observer work, schema/API, stable processing and other supported envelopes remain open |
| Migration | [SM01–SM03](results/schema-migration-2026-10-30.md) adds bounded additive local/cloud schema migration evidence, including final staged-handler data recovered before normal post-open saves. Explicit local adoption/upgrades exist; complete v1 conversion and coordinated cloud cutover do not. Representative end-to-end feasibility is required before beta; full tooling/application validation must pass before stable |
| Beta | Not declared. Eight implementation candidates do not alone satisfy the entry gate below |

## Alpha sequence

The first [A1 local ownership increment](graphevo-2-store-runtime.md) now lives
in an internal Swift 6 target, using the current schema. It has awaited
resource leases, coalesced opens, compatibility checks and drained final close.
The public Graph facade and cloud topology are not connected yet;
this progress does not mark the entire alpha stack or migration gate complete.

| Stage | Work and dependencies | Demonstrable exit | Relevant checks |
|---|---|---|---|
| A1 — resource ownership and lifecycle | Build the new runtime, store identity/registry, awaited open/close and private context ownership, using the current schema as first candidate and Swift 6 from the outset | Two compatible handles share resources safely, independent resources remain independent, handle release does not invalidate another handle, and shutdown/reopen work | V03, V08; S4 |
| A2 — async operations and transactions | Complete safe value reads, isolated mutation scopes, serialized writes, errors and cancellation on A1 | A non-UI Swift 6 consumer reads/writes without context escape; rollback, cancellation and admitted-work shutdown have tested outcomes | V03; S4–S5 |
| A3 — application models | Implement protocol-based typed mapping for Entity, Relationship and Action, identity/references, tags/groups and explicit edits | A small independent consumer creates, reads, edits and deletes a typed graph without dynamic-member access; decoding and scope errors are visible | V04, V03; S3, S6 |
| A4 — graph separation and mirroring | Apply the candidate membership model to the new runtime and owner-private personal graph share boundaries; introduce the shared-store pair with A5 participant routing; revise schema only where required | Two personal graphs retain separate cloud boundaries on an independent replica, including detail rows and mutations; local readiness/import integrity stay distinct | V01, V02.12, V03.8; S3, S7 |
| A5 — user sharing | Add private/shared resource ownership and routing, invitation/acceptance, owner/participant writes, permissions, leave/revocation and recovery on A4 | Different-account devices recover and mutate one complete graph without leaking the control graph; partial native operations are diagnosed/recoverable | V02; S5, S7 |
| A6 — files | Implement attachment ownership, metadata, import/read/replace/delete/export and whole-content backup with A4/A5 | Exact binary lifecycle and cross-account recovery with a measured memory/size envelope; no internal file paths exposed | V05; S8 |
| A7 — queries | Build typed query composition, related-node filters, count/projections, deterministic ordering and selected pagination/aggregations | Capability/cost matrix and representative queries with explicit unsupported cases and bounded traversal | V06; S9 |
| A8 — observation | Compare/implement one-shot results, observed state and processing needs on A7 and real mirroring | Correct dependency invalidation, local/remote refresh, cancellation, slow-consumer behavior and an explicit live/replay contract; then reconcile schema/API and meet the beta gate | V07; S10–S12 |

The [A2 local execution foundation](graphevo-2-async-transactions.md) now adds
serialized writes, isolated contexts, rollback, pinned SQLite reads and explicit
cancellation/commit boundaries. Its Swift 6 consumer regression is package-internal.
The independent public consumer exit moves to A3, where typed model scopes can
hide native context capabilities without introducing an interim untyped API.
Legacy/v2 opening exclusion is still required before exposing that public path.
A2 uses a temporary stacked PR against A1 while A1 awaits merge; retarget it to
v2 integration after A1 merges. The production integration destination is unchanged.

S references refer to numbered sections of the specification. A1 supplies the first
implementation foundation; it does not require a predesigned frozen v2 schema.
A1/A2 are two increments of the same stack foundation, not independent runtime
architectures. A3 needs an initial identity/mapping proposal, not a premature
commitment to its final storage representation. Schema changes retain their
rationale and test fixtures so higher-level features can challenge earlier choices.

The [first A3 increment](graphevo-2-application-models.md) implements transferable
model/record contracts, explicit values and patches, with a package-only adapter
and public Swift 6 model consumer. It does not complete typed public CRUD,
persisted identity, ownership exclusion or the mandatory v1 value migration.
A1 and A2 are reviewed and merged (#70/#71); the bootstrap CI PR #69 was closed
as superseded. Further A3 work starts from the integrated v2 branch.

The [A3 local typed store continuation](graphevo-2-typed-store.md) now implements
public scoped CRUD, persisted graph/node UUIDs, property envelopes, same-process
legacy/runtime exclusion and explicit current-schema v1 local adoption with a
pre-edit backup and retained old-ID mapping. A standalone typed SQLite consumer
and main-actor UI-state example exercise the public path. Local functionality is
implemented; replica identity, complete legacy codec/source conversion, migration
cutover and cloud membership still require later stages and beta validation.

The [A4 owner-private implementation](graphevo-2-graph-separation.md) adds a
multi-graph catalog, hidden native membership using the current schema, explicit
backed-up a3.1→a4.1 local upgrade and native owner-only share preparation/mapping
inspection. The shared-store resource pair is staged with A5 participant routing;
personal graph boundaries require only the private resource. This does not defer
user sharing or weaken its exit. Keep the [hardware evidence](results/a4-native-membership-2026-10-27.md)
separate from local regression tests and from native partial-operation recovery.

The [A5 implementation candidate](graphevo-2-user-sharing.md) adds paired native
ownership, invitations/acceptance, explicit participant structural operations,
permissions and leave/revocation. Local operation journals diagnose/recover
partial assignment without replaying native sharing. Native model hashes remain
unchanged. Hardware evidence and remaining release gates are recorded in the
A5 guide; this does not complete coordinated v1 cloud cutover or account-change
policy, and does not freeze the schema.

The [A6 candidate](graphevo-2-attachments.md) adds an owned attachment lifecycle
over the current schema, bounded source import, complete verified reads,
replacement/export/delete, owner cleanup and closed whole-directory copies.
Shared imports reuse A5 assignment. The attachment representation and memory
limit remain alpha decisions; complete v1/cloud migration and broader backup/
conflict/performance coverage remain release work.

The [A7 candidate](graphevo-2-queries.md) adds typed query descriptors,
AND/OR composition, scalar filters, directed relations, cycle-safe bounded BFS,
keyset pages, count/projection and selected aggregates. The current schema uses
an explicit bounded inventory/memory strategy; native indexes or cheap scalar
COUNT/projection are not claimed. A6 PR #75 is reviewed and merged; A7 PR #76
now targets v2 integration with A6 included. The maintainer deferred
attachment representation costs to end-of-alpha consolidation. A8 observation
and mandatory migration remain separate work.

The [A8 candidate](graphevo-2-observation.md) adds bounded current-state async
observation, whole-resource invalidation covering related dependencies, live
rescan hints and a cold Combine adapter. The three consumer contracts remain
distinct. O04's durable-processing choice, production cost/account coverage,
mandatory migration feasibility and the other beta-entry gates remain open;
this implementation does not declare alpha completion or create a release.

## Migration throughout alpha

Migration is a parallel workstream rather than a task first discovered after
A8:

- A1: preserve source-version definitions and synthetic populated v1 fixtures;
  inventory source properties/codecs/identity and current backup behavior.
- A2/A3: demonstrate that every v1 concept has a destination or retained opaque
  representation, and exercise old-to-new reference mapping on copies.
- A4/A5: select and prototype the old-cloud-layout transition, replica recovery,
  duplicate prevention and the coordinated cutover with v1 writes stopped.
  Define pending-write/returning-old-device recovery. Resolve any schema
  limitation that would make mandatory migration infeasible.
- A6: include externally stored bytes and attachment metadata in transformation
  and recovery fixtures; ordinary v1 binary properties are not assumed to be
  dedicated v2 attachments without an explicit interpretation.
- A7/A8: use migrated fixtures to exercise queries/observation and classify
  legacy history/ledger state that is preserved, translated or superseded.
- A8: review end-to-end migration feasibility and interruption/recovery protocol.
  Final implementation and broad real-store validation continue during beta.

Maintainer decision (2026-10-29): incompatible alpha layouts start from empty
stores. Prior alpha data is disposable; alpha-to-alpha conversion, downgrade
compatibility and interrupted alpha-conversion recovery are not requirements.
Release notes state this fresh-store policy. Existing incompatible paths are
still rejected without automatic erasure; fresh-store creation is an explicit
caller/test setup action. Experimental alpha files do not replace v1 production
data. Mandatory v1 migration and adopted beta-data compatibility remain distinct
requirements. Start beta from the agreed defined schema under its migration rules.

## Beta entry gate

Track outstanding consolidation decisions and beta acceptance in the
[post-alpha checklist](graphevo-2-post-alpha-checklist.md). Keep its B/R gates
updated with each increment; it does not postpone A8 or migration feasibility.

Enter beta only when:

1. All eight areas have been implemented or have a precise agreed scope. An
   accepted deferral states its user impact; a vague unchecked item is not a
   completed feature.
2. The target persistent schema, identity/reference rules and supported typed
   API are defined, with decisions justified by integrated behavior.
3. Cloud membership/sharing uses supported public APIs and has real-device
   evidence with the selected model, not only the V09 surrogate.
4. Transaction, cancellation, read/conflict, permission, incomplete-import and
   observation-delivery contracts are explicit and tested for supported uses.
5. The v1 local/cloud migration design is feasible on representative fixtures,
   including identity translation, source protection and recovery. Its remaining
   implementation/validation work is enumerated; migration is not deferred past
   the final release.
6. Supported OS/toolchain, process topology, query capabilities, attachment
   envelope and recovery limitations are published.

## App/widget requirement before beta

Maintainer requirement, 2026-10-29: concurrent app/widget access to the same
App Group graph must be designed, implemented and validated before beta.
Settle O03 with explicit read/write roles, synchronization ownership, native
change visibility, lifecycle and migration/first-launch behavior. A process-local
runtime registry does not coordinate independent app/extension owners. The
read-only local-widget approach is a candidate, not yet a final scope decision.
Interactive writes require an explicit supported contract and conflict/recovery
checks. Retain iOS multiprocess evidence separately from same-process runtime
and different-device CloudKit tests. Track acceptance under PA02 in the
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).

## Beta and final release

During beta, complete migration tooling and validate copies of representative
application stores, then integrate the real application. Exercise interruption,
failed conversion, retries, duplicate prevention and recovery on an independent
cloud replica. Validate ordinary local/cloud lifecycle and performance on the
supported OS matrix. Keep small independent consumers in addition to the app.

Schema and API are consolidated at beta entry. An incompatible beta correction
requires a specific rationale, revision notes and a supported migration for
affected adopted beta data; it is not an ordinary unannounced change.

Release 2.0 only after mandatory v1 migration, real app adoption and the selected
library acceptance matrix pass, with documented recovery/downgrade boundaries.
Review any optional v1 API adapter separately; it cannot block or weaken the
core design. Documentation and examples move to the actual v2 contracts while
v1 guidance remains accessible.
