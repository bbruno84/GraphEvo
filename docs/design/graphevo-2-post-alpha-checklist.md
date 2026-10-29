# GraphEvo 2 — end-of-alpha and release checklist

Status: open consolidation register, 2026-10-27. This collects follow-ups from
A1–A8 and the specification so they survive individual PRs. It complements the
[delivery plan](graphevo-2-delivery-plan.md), [decision register](graphevo-2-decisions.md)
and [experimental evidence register](graphevo-2-test-checklist.md).

## How to close an item

All boxes start open: existing evidence is input, not a claim that its broader
release gate passed. Each closure must link the decision or result, tested
revision, dataset, platform/device/account scope and remaining limitations.
Keep local regression, injected failures and physical mirroring evidence distinct.
Update this register whenever an increment introduces or resolves a follow-up.

**B** means settle and demonstrate the supported contract before entering beta.
**R** means complete acceptance during beta, before stable 2.0. A B decision may
leave enumerated R validation work. An optional capability may be explicitly
excluded with its user impact and recovery route documented; an unchecked box
is not an agreed deferral. Mandatory data migration cannot be excluded.

A8 observation belongs to alpha. Its candidate implementation, supported-scope
review and the migration feasibility review precede consolidation; they are not postponed by
calling this a post-alpha checklist. No release branch or tag follows from
creating this document.

## Consolidation evidence

A8 is reviewed/merged. [C01](results/c01-cost-baseline-2026-10-27.md) begins the
cost review with 182 validated samples across eight local synthetic configurations.
It measures identity/session overhead, file/query coupling and repeated observer
work. The [consolidation plan](graphevo-2-consolidation.md) proposes C02–C04;
these measurements do not yet select final representation or supported envelopes,
so PA01/PA05/PA06/PA07 beta gates remain open. Physical/production validation and
mandatory migration feasibility still require their own evidence.

[C02a](results/c02a-metadata-costs-2026-10-27.md) adds the first measured
schema-preserving candidate: B improves metadata access while retaining full
validation, but observer memory, full inventory and new native-write coverage
remain open. This is progress evidence, not closure of PA05/PA06/PA07.

## PA01 — schema, identities and application models

- [ ] **B** Complete A8 and review A1–A8 together; reconcile the actual supported
  API/schema with the specification before freezing them for beta.
- [ ] **B** Settle durable graph/node identity, reference and membership rules,
  ownership/deletion closure, incomplete imports, empty actions and valid absent
  endpoints (D04, D11, D14, O05); distinguish incomplete from corrupt data.
- [ ] **B** Inventory legacy codecs, unknown keys, null/absent values and opaque
  payloads; define lossless destinations and explicit conversion errors.
- [ ] **B** Record the migration effect of each persistent representation change,
  including logical metadata even when native model hashes stay unchanged.
- [ ] **R** Verify identity/reference/value preservation on independent replicas
  and migrated fixtures, including details, tags, groups and timestamps.

Sources: [model contracts](graphevo-2-application-models.md),
[typed store](graphevo-2-typed-store.md), specification S3/S6/S11.

## PA02 — runtime, concurrency and platform support

- [ ] **B** Select minimum OS/toolchain and supported process topology (O02/O03).
  Decide app/extension concurrent App Group access explicitly; a process-local
  registry does not establish cross-process safety.
- [ ] **B** Design, implement and validate concurrent app/widget access to the same
  App Group graph before beta (maintainer requirement, 2026-10-29). Define the
  supported read/write roles and which process owns CloudKit synchronization,
  cross-process change visibility/refresh, writer/intent coordination, and
  migration/first-launch behavior when the widget starts before the app.
  A local read-only widget is a candidate baseline, not an agreed restriction;
  interactive widget writes still require an explicit scope decision. Validate
  on iOS with independent processes; same-process leases and two-device cloud
  tests do not establish this contract.
- [ ] **B** Audit the complete distributed Swift 6 boundary, including legacy
  targets still in Swift 5 mode, Sendable/isolation, context escape, public
  imports and independent UI/non-UI consumers; document retained limitations.
- [ ] **B** Reconcile read consistency, local serialization, remote import/save
  overlap, same-property conflicts and cancellation/commit outcomes. Disjoint
  edit convergence does not establish conflict semantics.
- [ ] **R** Stress admitted/queued work, shutdown/reopen, independent leases,
  paired resource aliases/replacements, failed-load cleanup/quarantine and
  main-thread responsiveness under representative concurrency and payloads.
- [ ] **R** Run appropriate sanitizer/regression checks and physical runtime
  coverage on the selected OS matrix; verify new async paths avoid blocking
  bridges and retain explicit cancellation checks.

Sources: [A1](graphevo-2-store-runtime.md),
[A2](graphevo-2-async-transactions.md), V03/V08.

## PA03 — graph separation, accounts and native sharing

- [ ] **B** Publish account-unavailable/sign-out/switch/restriction and cached-data
  access rules, including revocation and offline retention. Prevent exposing or
  exporting an old account's data through a new account's session.
- [ ] **B** Define supported graph/zone scale, quotas and recovery limits; do not
  infer selective graph download or unlimited zones from isolation tests.
- [ ] **B** Settle native sharing presentation/adapters and invitation transport,
  recipient/container binding, errors and host responsibilities. Protect
  invitation/account capabilities and keep diagnostics payload-free.
- [ ] **B** Settle invitation readiness and resumable error behavior after native
  persistence, including unknownItem metadata lookup and a server share response
  lacking the intended recipient. Retain the first failures and explicit
  same-capability continuation in the [public adoption result](results/native-public-mirrored-schema-2026-10-29.md);
  never recreate zones or replay structural assignment as an availability fix.
- [ ] **R** Repeat supported mutations, fresh recovery and relaunch/offline/
  background scenarios on same-account and different-account replicas using
  the selected model; verify the control graph remains unchanged.
- [ ] **R** Exercise simultaneous structural writers, conflicting additions and
  replacements, stale permission metadata, read-only access reduction,
  revoke/reinvite/leave and owner deletion. Library permission rejection alone
  does not certify arbitrary native/server write enforcement.

Sources: [A4](graphevo-2-graph-separation.md),
[A5](graphevo-2-user-sharing.md), V01/V02/V09, D09/D10.

## PA04 — interrupted native operations and recovery

- [ ] **B** Publish supported reconcile/abandon/cleanup behavior for pending local
  intents, including missing owners/mappings and inaccessible graphs; never
  blindly replay native assignment or treat a local ledger as a distributed lock.
- [ ] **R** Inject interruption at each operation phase, native callback failure
  after partial persistence, divergence and post-commit journal cleanup failure;
  verify idempotent recovery without losing another operation's intent.
- [ ] **R** Cover permission loss, revocation and owner disappearance during
  shared insertion/file assignment, including retained staged bytes and safe
  cleanup. Pending intents must be resolved before a blocked leave/purge.
- [ ] **R** Verify journal/resource recovery after relaunch and independent peer
  observation; preserve useful bounded diagnostics when recovery remains pending.

Sources: A5 recovery contract and [A6](graphevo-2-attachments.md).
The existing physical assignment interruption is evidence for one window only.

## PA05 — native files: agreed cost review and acceptance

The [executed matrix](results/cost-matrix-2026-10-27.md) adds local binary/query
comparisons and serial cross-account native file lifecycle evidence. Keep the
remaining gates below: disk growth for four 1-MiB files, metadata-list/full-read
memory, real media, offline/conflicts/account recovery, conversion and migration
are not resolved by that result.


- [ ] **B** Perform M12's representation/cost review while retaining the accepted
  identity and ownership model as its starting point. Measure envelope decoding,
  full-content listing, copies, peak memory, latency and storage with representative
  content/sizes/graph counts; select representation and supported size envelope.
- [ ] **B** Complete C03a split-file acceptance: native participant insertion and
  two-value replacement/recovery, partial import/conflicting values, mixed old/new
  stores and coordinated legacy conversion. Metadata listing is not a body
  availability certificate. See the [experiment](graphevo-2-attachment-metadata-experiment.md).
- [ ] **B** Decide whether query/list costs require metadata separation or schema
  changes. Document actual availability and unsupported streaming/progress/
  eviction/selective-download behavior rather than promising these capabilities.
- [ ] **R** Cover security-scoped document providers, source changes/removal,
  cancellation/temp cleanup, atomic export to existing/dangling destinations,
  permission loss, and file I/O outside managed context scopes.
- [ ] **R** Verify exact bytes/metadata/revisions after offline/relaunch/import,
  concurrent remote replacements, pending assets and owner/dependency deletion
  across Entity, Relationship and Action, including rollback.
- [ ] **R** Confirm measured resource limits on supported physical devices and
  varied real content. Existing repeated-byte 512-byte/10-MiB probes and sampled
  whole-process peaks are not a production memory/performance guarantee.

Sources: [A6 contract](graphevo-2-attachments.md),
[A6 evidence](results/a6-native-attachments-2026-10-27.md), M12, V05/V09.

## PA06 — query semantics, execution costs and pagination

- [ ] **B** Review A7's bounded native inventory plus memory strategy with many
  graphs, selective queries and file-heavy records. Measure decoding of unrelated
  scoped properties, native candidate amplification and index opportunities;
  choose a supported production envelope and explicit capability matrix.
- [ ] **B** Finalize AND composition, literal strings, null/missing, numeric
  precision, ordering, count/projection/aggregate and traversal semantics with
  application adaptation examples. Decide scope of optional grouped aggregates,
  Decimal sums, portable cursors and deeper traversal; do not silently add them.
- [ ] **B** Publish budget/cancellation and moving-page guarantees. Candidate,
  payload and logical-step allowances do not bound all RAM, time or SQL I/O;
  opening/catalog work is outside the query allowance.
- [ ] **R** Test sort-key changes, duplicate keys, inserts/deletes around cursors,
  mismatched descriptors/graphs and page-local read views; verify documented
  repeats/omissions rather than claim frozen multi-page snapshots.
- [ ] **R** Cover decoder failures, exact numeric limits/overflow/nonfinite values,
  aggregate homogeneity, projections, cycles, budget boundaries, cancellation,
  fairness and close under representative local/remote datasets.

Sources: [A7 contract](graphevo-2-queries.md),
[A7 evidence](results/a7-retained-graph-queries-2026-10-27.md), V06.

## PA07 — observation and processing

- [ ] **B** Complete A8's three consumer contracts: one-shot results, observed
  current state and change processing. Resolve live feed/rescan versus durable
  replay (O04), with explicit application recovery if replay is excluded.
- [ ] **B** Demonstrate dependency invalidation for related-node/action filters,
  ordering, membership and attachments; close the retained V07 relationship gap.
- [ ] **B** Specify buffering/coalescing, slow consumers, cancellation, resource
  release, resubscription and error/incomplete-import delivery. Assess conservative
  whole-resource query refresh with many observers, Combine demand and any
  downstream scheduler queues against the supported production cost envelope.
- [ ] **R** Validate real remote edits/deletions, access/account changes, relaunch,
  pending work and close. If durable replay is selected, validate cursor retention,
  acknowledgements, duplicate delivery and history-gap recovery.
- [ ] **R** Verify query/observation behavior on migrated fixtures and the real
  application. No event, mapping or save callback establishes cloud completion
  or exactly-once processing.

Sources: [A8 candidate](graphevo-2-observation.md),
[physical/local results](results/a8-live-observation-2026-10-27.md), specification S10, V07,
D06/O04. The alpha implements async state and Combine over conservative
resource invalidation, with live rescan hints for processing. This does not
close O04 or mark the wider beta/stable items above complete.

## PA08 — mandatory v1 local and cloud migration

Manager renewal is tracked in the [M1–M6 contract](graphevo-2-migration-manager.md).
M1 provides package-only checkpoint bookkeeping; it does not close migration
feasibility, resource admission or compatibility gates. Consumer-authored schema/data migrations and ongoing imported-record format
compatibility belong to the general manager contract. RecoveryV2 is one concrete
compatibility/regression consumer, not the manager's architectural template.

- [ ] **B** Define and demonstrate consumer-registered native-schema and data-only
  plans, supported version routes and interleaved schema/data stages.
- [ ] **B** Define per-record format discrimination and a durable import processing/
  admission contract after whole-migration completion. Cover late old-format
  inserts/updates, future formats, incomplete dependencies and unauthorized writers;
  retain explicit incompatible states without silent query omissions.
- [ ] **B** Settle the awaited manager/admission contract, legacy completion import
  and tested v1 adapter subset; document Graph-dependent migrations that need porting.

- [ ] **B** Freeze the supported source-version/codec matrix and demonstrate
  end-to-end feasibility on representative populated v1 copies: all node kinds,
  topology, optional forms, values, binary content and old-to-new identity mapping.
- [ ] **B** Establish the coordinated cloud cutover mechanism (O01): v1 writers
  stopped, pending source writes reconciled, incomplete local sources detected,
  returning offline old clients handled, duplicate conversion prevented. KVS or
  a local flag is not a distributed fence or delivery acknowledgement.
- [ ] **B** Define source protection, durable migration phases, semantic validation,
  activation/reopen, retry and downgrade boundaries; enumerate remaining beta work.
  Do not silently convert incompatible originals or activate an empty cloud graph.
- [ ] **R** Complete tooling and convert representative real local/cloud stores,
  including unknown legacy payload handling and independent fresh replica recovery.
  Verify identity/topology/content, not only row counts.
- [ ] **R** Interrupt/cancel/fail each phase; verify resumability, idempotence,
  duplicate prevention, retained source data and rejection of invalid destinations.
  Test pending writes and returning old devices under the chosen cutover policy.

Sources: specification S11, delivery plan migration workstream, V08, D07/M02/M09.
API compatibility remains optional; data migration is a stable-release gate.

## PA09 — backups, restoration and retention

- [ ] **B** Define consistent closed/quiescent backup prerequisites and whole-content
  inventory, including external bytes, both native resources, auxiliary files and
  operation ledgers; identify existing narrow migration backup callers to replace.
- [ ] **R** Wire complete backups into actual conversion/recovery paths and verify
  bytes/checksums and successful reopen, interrupted copies/restores and protected
  source preservation. SQLite/WAL/SHM copying alone is insufficient for files.
- [ ] **R** Validate restoration of mirrored resource groups against existing cloud
  state and document limits. A local restore is not cloud rollback; current
  whole-directory copy evidence does not establish mirrored restore correctness.
- [ ] **R** Verify retention and cleanup of source stores, failed destinations,
  migration mappings and staged operations according to documented recovery policy.

Sources: A6 backup contract, specification S11, V05/V08.

## PA10 — integration, distribution and release evidence

- [ ] **B** Publish alpha-to-beta store reuse/migration/disposal policy (O06) before
  external adoption, plus schema/API revisions, supported limits and known failures.
- [ ] **B** Reconcile D01–D14 and O01–O06 against these items and the experiment
  register: retain exact evidence scopes and record explicit decisions for exclusions.
- [ ] **R** Adopt v2 in the real application while retaining independent consumers;
  exercise its actual data, UI responsiveness, migration, queries and observation.
- [ ] **R** Validate SPM/Release distribution, external Swift 6 consumers, minimum
  toolchain/OS CI and public examples; preserve v1 guidance and license notices.
- [ ] **R** Run acceptance on the exact release revision; retain device/account,
  dataset and diagnostic scope, unresolved findings and supported recovery routes.
  Debug seams must remain absent from Release and diagnostics must expose no payloads.
- [ ] **R** Review release notes, incompatible-beta migration paths and downgrade
  boundaries; verify mandatory migration and all selected acceptance gates before
  the release PRs/tags described in the delivery plan.


## C02b native identity prototype gates

- [ ] Integrate a selected native identity model only after reviewing the
  [prototype](graphevo-2-native-identity-experiment.md): default schema/openers
  remain unchanged during the experiment.
- [ ] Define production point-read absence/global-validation semantics, including
  missing columns, raw/column disagreement, duplicates, import progress and old
  writers. An activated local fixture is not a cloud completeness certificate.
- [ ] Complete protected-source/auxiliary/ledger and mandatory v1 mapping
  acceptance before release adoption. Alpha conversion is removed by M13; fresh
  native paired sharing/recovery now has bounded device evidence below.
- [ ] Check high-degree Relationship/Action reference costs and indexing/storage
  trade-offs; Entity-only latency is insufficient for graph-wide acceptance.

- [x] Measure the local C02b native-column candidates, including 500-reference
  actions and a second independent campaign. The [retained result](results/c02b-native-identities-2026-10-27.md)
  includes both regressing intermediate resolvers; integrated C02 gates above
  remain open.
- [ ] Carry the changed-owner facade fallback and staged/raw-mismatched endpoint
  regressions into integrated metadata/import tests on supported SDKs. A batched
  property fetch must never hide newly inserted metadata from the local view.


## C04a shared observation adoption gates

- [x] Review the [C04a experiment](graphevo-2-shared-observation-experiment.md),
  including single-observer/mixed-query overhead, update CPU and process memory.
  PR #83 reviewed and merged into the experiment parent at `9232993`; exact-head
  macOS/iOS CI run `40575201851` passed. This is not integration-line promotion.
- [x] Settle shared execution view/cursor semantics, per-consumer model decoding
  and failure/demand/cancellation behavior: see the [adoption contract](graphevo-2-observation.md#c04-consolidation-adoption).
  The first consolidation PR wires the public path; native acceptance below stays open.
- [ ] Validate supported native notification/account/import/handle lifecycles and
  representative physical-device workloads. Injected feeds are not CloudKit proof.
- [ ] Retain broad relationship/action/file invalidation until narrower dependency
  tracking independently demonstrates correctness. No replay cache or silent
  budget/view widening is accepted by local performance alone.

- [x] Retain C04a local matrix and independent confirmation: [results](results/c04a-shared-observation-2026-10-27.md).
  Exact-query gains do not settle single/mixed workload overhead or public adoption.
- [ ] Assess startup fan-out/model-decoder churn and heavy/slow application models
  before consolidation promotion. New subscribers deliberately request fresh reads and
  can refresh existing equal-query subscribers; shared view semantics remain explicit.


## Identity-guarded materialization follow-up

- [ ] Review the public-path identity-guarded implementation and retained matched
  Release comparison. It retains complete bounded structural inventory; it does
  not close native indexed query adoption.
- [ ] Verify the native same-model transformer exclusion/requested-failure probe
  on supported macOS/iOS SDKs, including eager transformation behavior.
- [ ] Keep body-validation scope explicit for IDs rejected before property access;
  complete selected records, candidates, related dependencies, ordered Boolean
  errors, pending edits and moving-page semantics must remain covered.
- [ ] Reassess startup and different-query costs after this increment. Native
  columns, import/old-writer absence semantics and v1 data migration remain open.

Source: [query materialization contract](graphevo-2-queries.md#c02-consolidation-identity-guarded-materialization).

Local implementation evidence: [501 tests, 44 targeted sanitizer tests and 72
matched Release rows](results/identity-guarded-queries-2026-10-29.md). This evidence
does not close the review/native-SDK or indexed identity/query gates above.


## Native identity integration readiness

- [ ] Review the [integration contract](graphevo-2-native-identity-integration.md)
  and stronger same-view negative lookup: absent columns and staged rows must not
  become successful absence. Preserve separate metadata/full-payload validation.
- [ ] Carry complete native projection maintenance through every integrated
  writer, attachment and assignment/recovery path before any public selection.
- [x] Validate controlled fresh native local/private/shared initialization and
  actual import/assignment/recovery, including separate files. See the local
  opening result and [device evidence](results/native-identity-paired-devices-2026-10-29.md).
  Alpha conversion tooling is removed by M13; mandatory protected-source v1
  migration remains a separate open gate.
- [ ] Retain changed negative-lookup/audit costs and high-degree action coverage.
  Default native schema and query row-coverage gates remain open.

First native readiness evidence: [504 tests, 16 selected sanitizer tests and 120
focused Release rows](results/native-identity-readiness-2026-10-29.md), retaining
stronger negative-lookup costs and unrouted/staged/native-body regressions. This
does not close public schema, paired-store conversion or v1 migration gates.


## Common native projection writer follow-up

- [ ] Review common projection maintenance for optional-column models. New rows
  and controls must be stamped in the common writer, with no prototype-only
  post-insertion rescan or repair of persisted missing projections.
- [ ] Keep local full-adapter coverage for all kinds, files, rollback, cascade,
  independent graphs, reopen and malformed/partial model rejection.
- [x] Validate controlled native-column staged assignment/finalization/import
  and explicit recovery on the private/shared pair, with independent peers and
  a separate file run. Preserve the first merge conflict and later recovery.
  See the [device result](results/native-identity-paired-devices-2026-10-29.md).
- [x] Validate explicit public local model selection using fresh stores under
  M13 (reviewed/merged #89). Public mirrored selection is a separate pending
  increment; no prior alpha conversion is required and v1 migration is mandatory.

#84/#85/#86 review and exact-head macOS/iOS checks passed and their consolidation
merges are `e2f6323` / `33225aa` / `0b933dd`. Native/schema/beta gates stay open.

Local writer evidence: 507 full tests and 31 selected sanitizer tests pass,
including common local file lifecycle, projection corruption refusal and guarded
point/mutation behavior during injected incomplete import. The later physical native-column
assignment/import result below supersedes that initial laboratory-only scope;
protected mandatory v1 conversion remains open.


## Alpha compatibility scope — resolved by M13

The maintainer selected empty stores for incompatible alpha layouts on 2026-10-29.
Earlier checklist references to alpha conversion, paired alpha-store conversion
or protected alpha-conversion recovery are superseded: they are not adoption
or beta gates. Historical migration experiments remain evidence only. Fresh
local/mirrored initialization and native behavior still require acceptance.
Mandatory v1 migration and beta compatibility/backup requirements remain.


## Fresh native store acceptance

- [x] Review explicit local native schema selection, create-only activation,
  incompatible model/prototype refusal and compatible reopen. PR #89 reviewed
  at 0529caa with successful macOS/iOS CI (40856799055, retry after queued job
  cancellation) and merged through its PR.
- [ ] Preserve fresh SQLite/memory, independent graph/lease, file, public-product
  consumer and query/observation corruption-recovery regressions.
- [x] Validate controlled fresh native private/shared initialization and actual
  cross-user assignment/import/recovery, including separate attachment bytes/
  replacement/cascade. See the [device result](results/native-identity-paired-devices-2026-10-29.md); public mirrored adoption remains separate.
- [ ] Retain v1 migration feasibility and beta data compatibility gates; alpha
  conversion is not required by M13.

The local API and [validation scopes](graphevo-2-native-identity-integration.md#fresh-local-native-schema-api)
do not turn bounded queries into indexed SQL or certify cloud completion.


### Native paired laboratory readiness (2026-10-29)

The internal native paired opener/host now exercises the selected layout without
changing public mirrored defaults. Offline adapter checks and generic iOS host
compilation do not close the native private/shared gate. Development reset was
confirmed, but physical installation lost connectivity before any cloud stage.
Retain independent A5/A8 recovery, native-column assignment/recovery, permissions
and lifecycle, plus a separate attachment byte/ownership/cascade run as open.
See the [acceptance matrix](../../Experiments/NativeIdentityPairedProbe/README.md).
V1 migration and beta compatibility remain separate requirements.

[Readiness evidence](results/native-identity-paired-lab-2026-10-29.md): 512 local
tests and 13 sanitizer tests passed; generic iOS host compiled. Device connectivity
prevented the physical run; no native acceptance item is closed by these checks.


### Native paired device acceptance (later on 2026-10-29)

The [physical result](results/native-identity-paired-devices-2026-10-29.md) supersedes
the initial device connectivity block above. Controlled A5 native identities,
shared insert/details, permissions, explicit interrupted recovery and full
revoke/reinvite/leave passed on the iPad/XR pair. A separate native A6 run passed
512-byte/10-MiB exact bytes, participant import/replacement/deletion, owner cascade,
independent absence and preserved B. Public mirrored defaults remain unchanged.

PA04 remains open for the broad crash/conflict matrix and guidance: the first
recovery save failed with Cocoa merge error 133020; its original intent survived
and later explicit recovery succeeded without reassignment. Cover this case in
supported recovery/error guidance, retain both outcomes and add deterministic
conflict/interruption coverage before claiming a general guarantee. Neither
automatic retry nor a change of merge policy was introduced. PA03 account/scale/
concurrency and mandatory v1 migration gates remain open.


### Public mirrored schema adoption

The explicit public native overloads cover private-only and paired resources;
no-schema/current defaults remain unchanged. The native factory requires standard
Core Data model version GraphEvo.nativeIdentity.alpha.2 before existing-file load,
so an old same-hash prototype cannot start export before catalog refusal. The
[adoption result](results/native-public-mirrored-schema-2026-10-29.md) separates
513 local tests, 14 sanitizer tests, Swift 6 Release consumption, successful
private-only device consumption, and paired invitation failures/continuation.
Do not replace the retained controlled #90 laboratory result with a claim that
every public paired attempt was clean. PA03 invitation readiness remains open;
app/widget support from merged #91 still gates beta.


The public paired consumer subsequently completed exact initial/replacement
10-MiB export, participant import/deletion, owner cascade to A=0 and preserved B.
It required one explicit same-recipient persistence with byte-identical invitation
after unknownItem, plus distinct read-only host continuations/controlled debugger
launches after reportless starts. The adoption result retains those failures;
PA03 invitation readiness is not closed by eventual success. Public native
private/paired selection is implemented; review/CI of its increment remains
separate from integration/tag/beta promotion.

### Public adoption causal gate (2026-10-29)

The maintainer requested causes before app/widget work. [Causal triage](results/native-public-causal-triage-2026-10-29.md)
reproduced a launcher false positive and added UUID/PID/scene receipts. The
historical black screen did not recur in bounded normal-launch checks, and two
traced first invitations succeeded with matching local/native/server recipients.
Neither historical cause is established. Keep PA03 invitation readiness open and
PR #92 draft; successful continuations/repetitions are not incident closure.


### Containing-app/extension first safeguard

The maintainer authorized continuing after fixing the launcher while retaining
non-reproduced historical incidents until recurrence. Their cause is not claimed
resolved. #92 passed exact-head macOS/iOS CI and was reviewed/merged into the
consolidation parent at 7a21bf6ae82022d1f362c6ae39f6dfa9a1ea8175.

The [extension access contract](graphevo-2-app-extension-access.md) adds v2
extension mirroring refusal and explicit single/paired local read-only openers.
Unit checks and an independent-process macOS public consumer cover local refresh,
observation and mutation refusal. **PA02/O03 remain open** for an actual iOS
App Group/widget, containing-app cloud owner, suspension/protected data and the
selected interactive-write scope. An extension-role preflight is not a universal
cross-process ownership lock or a claim that two application processes may mirror
one store. Native account/revocation policy remains open in PA03.

Evidence: [520 tests, 7 selected sanitizer tests, external Swift 6 Release
process/bundle consumers and generic iOS build](results/extension-readonly-access-2026-10-29.md).
This closes the first protective increment only; the iOS gate above stays open.
