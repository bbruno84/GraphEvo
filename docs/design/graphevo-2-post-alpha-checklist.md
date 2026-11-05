# GraphEvo 2 — end-of-alpha and release checklist

For implementation and integration progress, start with
[development status](graphevo-2-development-status.md). This checklist owns
beta/stable gates, not a competing branch-status summary.

Status: open consolidation register, 2026-10-27. This collects follow-ups from
A1–A8 and the specification so they survive individual PRs. It complements the
[delivery plan](graphevo-2-delivery-plan.md), [decision register](graphevo-2-decisions.md)
and [experimental evidence register](graphevo-2-test-checklist.md).

## H01 public entry — 2026-11-04

[PR #150](https://github.com/bbruno84/GraphEvo/pull/150) implements the selected
[public coordinated entry](graphevo-2-public-entry.md), including explicit context
ownership, account-only local verification, public staged bootstrap and private
cloud authority/peer recovery. Full checkpoint #41811987802 passes on 414cea3f
with both platform suites and Swift 6 consumers. Binding input/route ordering is
corrected through #151 with reviewed v2 checkpoint #41815151417 on c966f153.
Companion demo adoption and its bounded local/model evidence are tracked in
[GraphEvoDemo PR #2](https://github.com/bbruno84/GraphEvoDemo/pull/2). This narrows implementation gaps, not the broad B/R
acceptance below. Public invitation onboarding, independent-reader/protected-data,
production cutover, restoration and final distribution/API audits remain open.
No schema, persisted format or account-change beta scheduling gate is changed.

## H02 public sharing — 2026-11-04

[PR #152](https://github.com/bbruno84/GraphEvo/pull/152) implements the selected
[contract](graphevo-2-public-sharing.md): native invitations/UI, fixed GraphID
and descriptor-version control record, durable pre-GraphID joins, observable
permissions and guarded leave/recovery. Full checkpoint #41836169999 passes on
dc0ea893 with both platform suites and Swift 6 consumers. Explicit session-8
conversion preserves validated state; initial-save participant/account markers
and stale-generation guards protect restart/reinvite boundaries. MF10 private
recovery also validates/excludes native CKShare control metadata.

All acceptance boxes remain unchanged. Native UI/two-account physical acceptance
is still required before closing PA03's B gate. The new cloud record type requires
Production deployment and stopping old alpha writers; it is not a distributed
old-client fence. Companion demo delivery is separate.

The [first H02 device checkpoint](results/h02-public-invitation-2026-11-04.md)
retains a real metadata-first history failure and the candidate's same-workspace
recovery. The correction integrates through [#153](https://github.com/bbruno84/GraphEvo/pull/153)
with reviewed full checkpoint #41872809620 on 012b5083; source inputs remain
unchanged in the final documentation commit. Native acceptance/discovery, one owner-to-participant
note, read-only enforcement, reverse transfer, participant restart and settled
leave are observed. Reinvitation recovered after restarting the participant app.
The workspace/idle-claim correction [#154](https://github.com/bbruno84/GraphEvo/pull/154)
covers normal/deferred leave and revocation with reviewed v2 checkpoint
#41887502842 on 3ee3d3fa: 709 macOS / 707 iOS functions and both Swift 6 consumers.
The capacity-only first attempt and the next macOS run's 87 issues remain recorded;
one bounded macOS repeat passes without source/timeout changes or root-cause
attribution. Restart-free final-pin acceptance remains open. No PA03 box closes from this partial result.

## App Group physical control — 2026-11-04

The [presence-lock control](results/app-group-presence-control-2026-11-04.md)
reproduces 0xdead10cc for both real iPad processes retaining owners.flock;
bootstrap writer locks had already been released. The matched fd-only variant
survives and passes short bidirectional app/widget round trips, while refusing
exclusive/destructive maintenance. It is experimental evidence only. **PA02
remains open:** replace lifetime presence with a suspension-compatible exclusion
contract before claiming safe concurrent App Group lifecycle support. Do not
remove the lock in production or treat per-operation coordination as a complete
replacement. Other OS versions, expiry/long writes and cloud roles remain open.

## Apple owner-lifetime continuation — 2026-11-04

[M/M2 evidence](results/apple-owner-coordination-2026-11-04.md) completes the
bounded native owner/maintenance experiment: M2's presenter lease refuses active
clone replacement, closes on pause, rejects old leases and reopens explicitly.
Mac controls and actual iPad background/widget contention pass; 18 timing runs
verify 1,350 commits. Preserve M's 16 PASS / one clone FAIL and both earlier
prototype corrections. No PA02 acceptance box closes: public lifecycle/observation,
partial-init cleanup, quarantined suspension, sibling-store layout, persistent
workspaces/migration and session/catalog locks still need integration validation.
This report adds no production code or remote CI checkpoint.

The [pre-integration priority protocol](graphevo-2-apple-owner-test-protocol.md)
has [N evidence](results/apple-owner-priority-tests-2026-11-04.md): 51 macOS
controls, 99 existing adapter tests and thirty actual iPad lifecycle cycles pass.
Partial opening, retained-task cancellation and actual session/backup lease
release have bounded positive evidence. The [iPad fault continuation](results/apple-owner-ipad-faults-2026-11-05.md)
verifies background quarantine and exact cold readback, including controlled
pre/post-save interruptions. Both interrupted preparation directories remain on
disk. The [O experiment](results/apple-owner-preparation-recovery-2026-11-05.md)
passes concurrent cleanup, creation and publication fault, cancellation, and
native recovery controls on macOS. The iPad continuation verifies controlled
host interruptions during preparation and before and after native save. A separate iOS 18.5 simulator control passes
thirty Home/widget/app cycles with N. **NO GO for production adoption** pending
remaining device coverage, including the XR iOS 18 and widget-private paths, and
physical lifecycle checks. The [P macOS experiment](results/apple-owner-runtime-lifecycle-2026-11-05.md)
verifies the presenter attachment, transport drain and fresh public observation
with existing runtime fences active. The replacement fence, native coordination
and context admission transition remain open.
No PA02 acceptance box closes. Deferred
layout, migration-workspace and broader platform cases remain pre-beta work.

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

## Current gate interpretation — audited 2026-11-03

The [audit and evidence map](results/roadmap-audit-2026-11-03.md) is pinned to
integrated #144. Unchecked B/R items below are broad acceptance obligations;
they must not be read as proof that their implementation is absent. Dated S01,
S03, native-mirroring and early T01 text retains its historical tested scope.
The selected custom-sync store uses S04; old-model device evidence is not
transferred automatically to a newer transport or schema.

| Remaining gate group | Existing implementation | Evidence or decision still needed |
|---|---|---|
| PA01/PA02/PA10: public API and supported runtime | Typed scopes/models, package-only ContextManager, cooperating-process locks | Public coordinated opening/bootstrap, complete Swift 6 audit, OS/process matrix, API/schema reconciliation |
| PA02: app/widget | Read-only/process safeguards and bounded earlier App Group evidence | Current custom-sync app/widget roles, interactive-write scope, first-launch/migration and physical multiprocess acceptance |
| PA03/PA04: cloud lifecycle | T01–T08 transport, conflicts, pause, foreground scheduling, sharing and lifecycle | Account/cache policy, public invitation integration, structural conflict scope, broader interruption/restore and spool device acceptance beyond the bounded private checkpoint |
| PA05/PA06: supported costs | S04/P01–P03, #142 inventory reuse, #143 descriptor queries, #144 spool | Publish supported limits; broader device/capacity acceptance and beta performance measurements |
| PA07: observation/processing | A8 async state, Combine and live rescan hints | O04 live processing versus durable replay, recovery contract and current-backend acceptance |
| PA08/PA09: migration/recovery | MF01–MF11 bounded protected execution, backups, conversion and authoritative new-cloud bootstrap | Public flow, historical/production source matrix, host old-client cutover, interruption and restoration acceptance |
| PA10: stable release | Independent consumers and reviewed CI checkpoints | Real application adoption, full production acceptance, distribution and release evidence (R) |

No broad B/R gate closes solely through this audit. Background scheduling and
interactive widget writes require explicit scope decisions; this audit neither
adds them as mandatory features nor excludes them. Real application adoption
remains R; a pre-beta application pilot is a recommendation, not a moved gate.

## Consolidation evidence

The maintainer selected [controlled-store access](graphevo-2-controlled-store-access.md)
after private query/attachment/import/lock studies. Correct writer exclusion,
query-local semantics and durable transport recovery are alpha implementation
work; opening/listing latency tuning, batch-memory sizing and representative
device/network performance envelopes remain beta measurement work. Retaining
native attachment bodies does not certify temporary-spool recovery or quota
acceptance. No broad release gate closes from the private performance results.

The first ownership increment integrates through
[PR #142](https://github.com/bbruno84/GraphEvo/pull/142), with reviewed full
[checkpoint #387](https://github.com/bbruno84/GraphEvo/actions/runs/41692421379)
on `2e0d2b171c46661560646482b65ac974b4a50278`: 974 macOS functions,
971 passed iOS functions with the known skip and both Swift 6 consumers.
The manager remains the coordinated writable gateway; transaction-local reuse
requires protected contexts, and workspace ownership stays exclusive until
detach. This closes that narrow implementation increment. Query adoption
follows in #143 and reference-only transport in #144; broader release gates
remain open. Cooperating-process regression evidence does not certify old or
external writers.

The [descriptor-first query increment](graphevo-2-descriptor-query-scopes.md)
separates query-local inputs from explicit auditing without changing S04 storage.
Its [matched local comparison](results/descriptor-query-scopes-2026-11-03.md)
retains complete results with approximately sixfold query improvement. It
integrates through [PR #143](https://github.com/bbruno84/GraphEvo/pull/143), with
reviewed [v2 checkpoint #392](https://github.com/bbruno84/GraphEvo/actions/runs/41702479602)
on `5e258fdfc5564cf128aaf4ad6f82a7f4f1ddb1a2`: 648 macOS and 646 iOS
functions without failures/skips and both Swift 6 consumers. The capacity case
passes locally on both platforms. This closes query-source adoption only;
broader acceptance remains open; asset transport subsequently integrates through
#144. Private F's timing is not a generalized or device checkpoint.

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

M18 selects [S03](graphevo-2-history-schema.md): preserve graph/node UUIDs in
deleted-node history through six flags, without new columns. PH01 remains
experimental evidence; model adoption does not close history processing,
checkpoint/queue recovery or selected-model/custom-sync cloud gates.

- [x] Allow Foundation-only domain files and separate GraphEvo mapping extensions.
  [M20 / #131](graphevo-2-extension-model-mapping.md) verifies UUID/context binding,
  same-UUID graph isolation, native reopen and typed observation with a two-file
  independent consumer. Corrected full CI #340 passes after the retained #338
  consumer entry-point failure. This closes the narrow API requirement, not
  production model/migration/cloud acceptance. [Numeric mapping / #132](graphevo-2-numeric-properties.md)
  adds eight Swift numeric conformances with exact narrowing and full CI #343;
  logical cases and wire/native formats are unchanged. Native-property schema/
  planner adoption remains separate.
- [x] Select the native 2.0 target after reviewing query, attachment, sharing and
  migration requirements: [S01](graphevo-2-persistent-schema.md), 2026-10-30.
  Retain twelve entities; select graph/node projections, optional node data
  version and compound identity indexes. This closes the shape decision only.
- [x] Adopt S01 in the explicit native factory/shape checks and opening matrix:
  stable model ID, exact shape, local CRUD/files/reopen, offline paired routing,
  read-only paths and refusal preserving older/wrong-marker source data. These local
  controls do not close selected-model physical sharing/recovery acceptance;
  [530-test adoption result](results/s01-runtime-adoption-2026-10-30.md) records
  exact source-file checks and the volatile SHM limitation.
- [x] Validate selected S01 native sharing/recovery, including attachments,
  through the public factory: [16-stage iPad/XR result](results/s01-native-sharing-recovery-2026-10-30.md),
  two independently empty participant pairs, byte-exact 10-MiB exports and actual
  S01 metadata on eight native resources. Scope is the A6 entity/file fixture;
  broader PA03/PA05/PA08 remain open. S02 requires separate device acceptance. Retain
  SM01–SM03's same-shape laboratory evidence separately from runtime activation.
- [x] M16 withdraws library-owned application format declarations/admission.
  Consumer transformations and protected migration execution remain PA08 work;
  this is a scope correction, not acceptance of cloud compatibility.
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

### Planned lifecycle follow-up — complete graph deletion

- [ ] **R** Define, implement and validate explicit permanent deletion of an owned
  graph, both local and cloud, under ContextManager. Coordinate aliases, admitted
  work, store/internal files, cloud data/control/sharing and transport cleanup;
  recover after interruption/offline failure without unintended recreation or
  damage to other graphs. Preserve owner/participant authorization boundaries and
  settle existing-backup retention separately. This is not `removeAll()`, leave,
  or a prerequisite for migration. See [the roadmap](graphevo-2-delivery-plan.md#complete-graph-deletion--planned-lifecycle-work).

## PA03 — graph separation, accounts and native sharing

Current implementation correction: #106/#108/#109 and T01–T08 implement the
coordinator, PH processing, engines, record effects, conflicts, foreground sync
and zone sharing/lifecycle. Their bounded reports are linked under the T03–T08
follow-ups below. References within the early bullets to missing upload/import,
conflict resolution, scheduling or sharing describe the earlier foundation,
not the integrated implementation. The broad boxes stay open for the public,
account/process, interruption and recovery acceptance specified above.

M17 replaces automatic native mirroring with explicit CloudKit sync. Existing
native-sharing evidence remains historical. The
[transition contract](graphevo-2-custom-sync-transition.md) defines replacement
ownership and the retained CS01 result; the experiment does not close these gates.

The [package-only coordinator increment](graphevo-2-graph-coordinator.md) adds
local exclusive ownership/lifecycle tests, without closing public activation,
engine or cross-process acceptance. Retain this scope when integrating it.

- [ ] **B** Implement exclusive per-graph stores/controllers and ContextManager
  ownership of at most one engine per configured CloudKit private/shared database
  in the synchronization process. Route exact zones, scope account state and keep
  private graphs unshared until requested. The
  [engine foundation](graphevo-2-sync-engine-foundation.md) supplies package-only
  ownership/manual fetch and durable inbox retention. Physical native-engine
  behavior, public activation, record import/upload and sharing remain open.
- [ ] **R** Measure the incremental disk/retention cost of S03 identity tombstones
  and representative PH processing, separately from queued payload and attachment
  costs. The six-flag model decision does not establish a storage envelope.
- [ ] **B** Implement scoped PH processing with safe deleted-detail/owner
  correlation, token/store binding, pruning/expiry policy and durable pending
  publication before checkpoint advancement. S03 retains deletion IDs; it does
  not reconstruct pre-preservation tombstones or certify processor recovery.
  The [PH pending increment](graphevo-2-history-processing.md) covers local/Simulator
  discovery, atomic-save rollback, replay and acknowledgement races. Real
  process-kill/power-loss, retained-history rebaseline, full incoming operations
  and queue/engine ordering remain open; count refusals are not resource bounds.
- [ ] **B** Prove durable local change discovery/publication and incoming application
  across interruption, including store/queue/engine-state ordering and outgoing
  acknowledgement races. Explicit fixture queueing is not this acceptance.
  Engine-foundation tests cover file publication failures, reopen/replay and
  drain/late-callback behavior. True crash/power-loss, inbox consumption/effect
  receipts, CKAsset staging and joint queue/engine ordering remain open.
  [CF01](graphevo-2-cloud-record-format.md) adds lossless logical record encoding,
  secure system-field reuse and PH/inbox conversion tests, without upload/import
  activation. Actual server change tags, metadata/effect persistence, dependencies,
  conflict handling and cloud-schema deployment remain open.
  [T01](graphevo-2-record-transport.md) connects manual native driver hooks and
  atomic metadata/effect receipts, with injected two-replica recovery tests and
  actual local container relocation. Physical CloudKit delivery/change tags/CAS,
  real process-kill/power-loss and consistent session/native backup restore are
  still required; automatic scheduling and conflict resolution remain open.
  The [ten-stage real private result](results/record-transport-cloudkit-2026-10-31.md)
  proves small-fixture insert/update/delete, native server metadata reuse, iPad/iPhone
  recovery, no upload feedback, restart, empty final recovery and complete final
  local/server inventory agreement. The [thirteen-stage real conflict result](results/record-conflicts-cloudkit-2026-10-31.md)
  adds actual serverRecordChanged/unknownItem, partial acknowledgements, independent
  graph progress, preserved newer local generations, import refusal, reopen and
  fresh server-state recovery. It explicitly records deletion winning on the server
  for both tested stale update/delete orders. Consumer resolution/rebase and
  multi-node structural conflict acceptance remain open. This does not close
  genuine concurrent conflicts, interruption/backup, assets or broader account/sharing
  acceptance. The initial #111 CI process exit remains undiagnosed after successful
  local/final-CI reruns; retain crash/stress follow-up and iOS result diagnostics.
- [ ] **R** Measure full-document engine-state/inbox and graph transport metadata/
  frozen-attempt rewrite costs, receipt retention and growth; count/encoded-byte limits are not total memory/I/O envelopes.
- [ ] **B** Validate graph-level pause/resume with automatic and in-flight work,
  migrated local stores, pending changes and independent progress of other graphs.
  Cancelling an engine is not a graph-level completion barrier.
- [ ] **B** Retire the transitional v2 native mirror/assignment paths after their
  callers have replacement coverage; preserve mandatory v1 conversion/readers.

- [ ] **R** During beta, exercise the selected
  [account isolation](graphevo-2-cloud-account-isolation.md) default with physical
  iCloud logout, account switch and verified same-account return. The maintainer
  deferred these device account-change trials to beta on 2026-11-04; complete
  them before stable release. [PR #147](https://github.com/bbruno84/GraphEvo/pull/147)
  implements the default with reviewed full CI and injected regression evidence.
  It retains data separately, blocks ordinary access after identity loss and
  notifies consumers. This scheduling decision does not certify physical behavior.
- [ ] **B** Validate account isolation across protected-data transitions and
  independent reader processes. These gates are unchanged by deferring physical
  account-change trials; cached consumer UI and restoration retain their scope.
- [ ] **R** Design optional local-data merge into a signed-in account, including
  explicit consent, identity/conflict rules and interrupted-operation recovery.
- [ ] **R** Design optional automatic local deletion on account loss, including
  unsent edits, attachments, backups and interrupted deletion. Only isolation is
  implemented now; neither alternative is exposed as a supported configuration.
- [ ] **B** Define supported graph/zone scale, quotas and recovery limits; do not
  infer selective graph download or unlimited zones from isolation tests.
  Include unbound database lifecycle-event retention: the private spool checkpoint
  retained 65 unrelated `zoneChanged` events after consuming its fixture zones.
  Preserving those events is not acceptance of unbounded queue growth.
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
- [ ] **B** Reconcile C03a's split metadata/content requirements with the
  selected S04/custom-sync attachment path: participant insertion, replacement,
  partial import/conflicts and legacy conversion. Retain the native-mirroring
  [experiment](graphevo-2-attachment-metadata-experiment.md) as historical evidence;
  do not transfer its acceptance to the new spool. Metadata listing does not
  certify body availability.
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

- [ ] **B** Finalize the supported query envelope/capability matrix after P02
  native planning and #143 descriptor-local hydration. Their bounded review and
  measurements are complete; representative selective/file-heavy workloads and
  candidate amplification still need acceptance. Retain A7 memory evaluation
  where explicitly selected; do not restart a planner already integrated.
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

- [x] Align PR #95's migration-manager contract with M14/S01: consumer-defined
  application-data plans only; native schema routes are internal. M1 remains a
  package-only journal, with no production execution/admission or cloud fence.
  See [the renewed contract](graphevo-2-migration-manager.md).
- [x] Exercise [M2a local data/version publication](graphevo-2-data-migration-local.md):
  pure consumer transformation, atomic values/version/effect marker, native
  close/reopen and recovery without callback replay, stale/future input refusal,
  cancellation and protected-source recovery. This is a package-only laboratory,
  not public-store activation or complete M2 admission. The
  [553-test result](results/m2a-local-data-migration-2026-10-30.md) records the exact
  accepted scope and retained fixture/type-inference corrections.
- [x] M16 supersedes M2b.1 application-version contracts and the proposed format
  registry with [consumer-owned data](graphevo-2-data-formats.md). S02 removes the
  native version column and global format refusal. Historical results retain scope.
- [ ] **B** Reconcile selected S04/custom-sync sharing and independent recovery
  acceptance with [P03's bounded physical result](results/s04-typed-properties-runtime-and-cloud-2026-11-02.md)
  and subsequent transport changes, including the
  [private spool result](results/durable-asset-spool-device-2026-11-04.md). Historical
  S01/native-mirroring results do not certify the current complete path; do not
  require obsolete S03 fixtures as a substitute for current-model acceptance.
- [ ] **B** Complete consumer-defined migration execution with resource/process
  readiness, protected-source backups, retention, recovery and activation. Keep
  the exact M2a fixture isolated; no public format registry is required.

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

- [ ] **B** Validate the [MF07 local v1 route](graphevo-2-v1-local-conversion.md)
  against historical/production sources and supported bootstrap. Retain source
  bytes/data, native detail versions, lookup mappings and complete legacy backups;
  classify ambiguous null/native wrapper cases without silent loss. Exercise
  interrupted conversion, failed cleanup, source replacement, bounds and scale.
  Before new-cloud activation, settle legacy binary properties exceeding the
  inline cloud allowance; preserving a Data value locally is not CKAsset migration.
  Select one authoritative initial import/mapping before activating peers; separate
  local conversions must not publish competing random IDs into the same graph.
  #129 integrates the bounded local route after review and full CI #331;
  [local/device results](results/v1-local-conversion-2026-11-01.md) retain the
  exact pin and scope and do not close the whole v1 gate.
  Old-cloud conversion/coexistence is not part of this local increment.
  [MF08](graphevo-2-store-migrations.md) factors the protected sequence into
  concrete internal definitions; this does not close public bootstrap, future
  staged/in-place schema or production-source acceptance gates.

Sources: specification S11, delivery plan migration workstream, V08, D07/M02/M09.
API compatibility remains optional; data migration is a stable-release gate.

## PA09 — backups, restoration and retention

The [current roadmap](graphevo-2-migration-foundations.md) adds a central
BackupManager with a caller-supplied manifest reason and a reversible graph-local
write reservation. [MF01](graphevo-2-local-maintenance.md), integrated in #120 after
corrective review and the combined CI checkpoint, supplies their package-only
baseline with complete local snapshot/empty-destination restoration, caller
reasons, native content checks and durable retention. The
[local result](results/local-maintenance-2026-11-01.md) verifies the candidate
on macOS/iOS Simulator, without closing physical/cross-process acceptance.
In-place/cloud restore, legacy-source integration and actual migration activation
remain open. Validate nested reservations,
all-handle drainage and explicit app/widget exclusion before claiming migration
isolation. Current one-graph/store backups must preserve other graphs' shared
engine/session state and must not roll back the cloud control ledger. Historical
paired-store evidence below retains its original backend scope.

- [ ] **B** Accept MF02's implemented `.geb` packages, manifest discovery,
  async export/import and bounded extraction for the supported production
  envelope; the format and implementation are already selected. Verify coherent
  copy, atomic publication and interruption recovery separately. Validate transfer between devices and
  independent cross-user import without inherited sharing/transport ownership.
  See [backup roadmap](graphevo-2-migration-foundations.md#compressed-local-packages-and-portability--next-backup-increment).
  [MF02](graphevo-2-backup-packages.md) integrates the `.geb` package-only baseline
  in #121 after corrective review and the combined CI checkpoint;
  independent cross-user graph activation and production/media-scale acceptance
  remain open even when package transfer/import succeeds.

- [ ] **B** Define consistent closed/quiescent backup prerequisites and whole-content
  inventory, including external bytes, both native resources, auxiliary files and
  operation ledgers; identify existing narrow migration backup callers to replace.
- [ ] **B** Validate bounded shared graph control metadata at scale, including
  concurrent writers, interrupted control publication, permissions and lifecycle
  recovery. [MF03](graphevo-2-shared-ledger.md) supplies the package-only foundation through #122
  with current/previous operation, 32 events, bounded consumer JSON and session
  format 6. The [bounded iPad/XR result](results/shared-ledger-2026-11-01.md)
  verifies read-only control updates during data pause and explicit restart
  recovery; broad physical fault/concurrency acceptance remains open. Measure session rewrite
  costs and reserved 512-KiB headroom per enabled graph before production sizing.
  Unmirrored local journals and migration-data commit-marker recovery remain open;
  diagnostic history rotation must not delete unresolved executor evidence.
- [ ] **B** Complete large logical-emptying acceptance: native/resource/payload
  costs, external-byte reclamation, cumulative deleted-ID/PH limits, concurrent
  remote insertions and permission/account changes during deletion delivery.
  [MF04a](graphevo-2-logical-emptying.md) integrates through #123 after review and CI #311, using existing
  deletion queues and tombstone retention, not a global cloud reset. The
  [bounded iPad/XR result](results/logical-emptying-2026-11-01.md) retains exact
  empty/repopulated inventories and share/ledger/control-graph continuity; physical
  read-write guest/concurrent-writer/account-change and scale coverage stays open;
  retain local and physical evidence separately; no workspace/publication gate closes here.
- [ ] **B** Implement and validate the isolated working graph and explicit PH
  range/seal contract. [MF04b preparation](graphevo-2-migration-workspace.md) integrates through #124
  after review and full CI #317. It preserves the protected original
  without creating a premature backup and refuses ordinary cloud activation.
  MF04c implements bounded sealing/reduction, restart/source-freshness recovery
  and activation-bound cleanup through #125 after corrective review and CI #320.
  The [MF04c result](results/migration-workspace-sealing-recovery-2026-11-01.md)
  retains a two-process injected pre-detach-failure/recovery protocol separately
  from final corrective CI. Complete physical I/O/power-loss, external-process
  writer and production-scale acceptance. The [local preparation result](results/migration-workspace-preparation-2026-11-01.md)
  keeps broad/final focused checks separate. Bind history to the exact working
  instance and survive interrupted sealing. Measure full validation/copy costs
  and reserved native seal metadata (default 4 MiB, hard maximum 8 MiB); physical
  file-identity binding deliberately refuses copied/cross-volume workspace adoption.
  Participant-origin workspace activation also requires permission and T08
  revocation/purge integration before enabling that route. A change manifest
  alone does not establish safe original-store publication.
- [ ] **B** Validate [MF05 publication](graphevo-2-migration-publication.md): one
  bounded atomic original commit, verified pinned backup, native receipt recovery,
  unchanged frozen transport and ordinary PH generations. #126 integrates the
  bounded implementation after review and CI #324; its
  [result](results/migration-publication-2026-11-01.md) separates local and real
  owner-to-read-only-participant recovery evidence. Participant-origin execution,
  fresh-after-publication shared bootstrap and physical interruption remain open.
  Preserve the 10,000-ID
  projected pending and 100,000-native-change limits; measure payload/copy costs.
  The latest-only receipt can refuse old workspace recovery after a subsequent
  migration. Review retained orphan backups after abandoned failures and explicit
  retention release. Neither receipt nor queue emptiness proves global migration.
- [x] Exercise one representative synthetic consumer through ledger, isolated
  transformation, validation, backup and publication. The [MF06 result](results/consumer-migration-flow-2026-11-01.md)
  records six local functions/ten invocations on macOS/iOS and ten iPad/XR stages.
  Original A remains unchanged while its ledger and unrelated B progress; restart
  recovers native commit evidence without body replay or duplicate backup. This
  local-only laboratory does not close production adoption, participant-origin,
  fresh-after-publication shared bootstrap, physical interruption/scale or v1 gates.
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
Core Data model version GraphEvo.nativeIdentity.alpha.2 before existing-file load
in that increment (now superseded by S01 / GraphEvo.v2.schema.1),
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


### Actual app/widget App Group baseline (2026-10-29)

[Physical WidgetKit evidence](results/widget-app-group-2026-10-29.md) now covers
signed App Groups with app-owned private/shared mirroring and local read-only
widgets on iPadOS 27.0 and iOS 27.2. Native mirroring/mutation refusals, independent
PIDs, 0→1→2, iPad owner close/reopen and visible small/medium rendering are retained.
This closes the **first physical read-only baseline experiment**, not PA02/O03
as a whole. Preserve the iOS 18 actual-widget gap and the remaining suspension,
protected-data, concurrent migration/reset, account/cache/revocation, performance
and interactive-write decisions. No beta/tag promotion follows from this result.


### Native schema migration experiment (2026-10-30)

[SM01–SM03 result](results/schema-migration-2026-10-30.md) validates additive
v1-shape→native-plus-optional-node-version migration locally and on iPad/XR
Development sharing. Final staged-handler values and native version 1 were
recovered by an existing peer and a fresh pair before ordinary post-open writes.
A failed pre-handler can leave saved changes; a protected copy retains baseline.
Six controls and the full 526-test suite pass. This does not close PA08: historical
v1 store/codec coverage, process-kill/activation recovery, concurrent cloud edits,
Production deployment and full graph/data conversion remain open. The optional
version field was experimental in this result; S01 now selects its target shape.
Explicit native runtime openings now adopt S01; default/current openers retain
their original model. Neither shape adoption nor the laboratory result closes
the remaining PA08 data-conversion gates.

## CI checkpoint evidence policy

V2 alpha uses [explicit remote CI checkpoints](graphevo-2-ci-checkpoints.md),
selected by the maintainer on 2026-10-31. Per-increment review and relevant local
checks remain mandatory; a skipped remote job is not acceptance evidence. Full
macOS/iOS validation is required at agreed delivery checkpoints and before
alpha/beta tags; release/v1 automatic checks remain enabled. Existing B/R gates
and physical-device scopes are unchanged. Record the actual tested commit/run
when closing any gate; do not infer success from an unrun or skipped workflow.


## T03 conflict-policy follow-ups

- [ ] **B** Extend [T03](graphevo-2-conflict-policies.md) beyond bounded private
  record fixtures: structural dependencies, sharing/permissions, account changes,
  offline/rate limiting, actual interruption and consistent backup recovery.
  Same-record convergence does not close the broad conflict gate.
- [ ] **R** Measure added hidden modifiedAt rows, server conflict receipt archives,
  deleted-ID trace growth and full-map rewrite costs on realistic workloads.
  Transport plus traces share 32 MiB; traces cap at 100,000 IDs with explicit
  refusal. Design/verify safe lifetime retention before claiming stable capacity;
  do not prune automatically and risk old-event resurrection.
- [ ] **R** Document device-clock skew consequences of lastEditWins; no distributed
  correction or global temporal ordering is provided. Confirm policy guidance and
  report interpretation: local resolution is distinct from confirmed publication.


## T04 asset follow-ups

#144 supersedes the original inline durable-body representation with owned-file
references. The rewrite/copy measurement item below applies to that current
representation; it must not trigger reimplementation of already integrated
staging/restart recovery. The bounded private new-spool checkpoint is recorded
below; shared-account, in-flight interruption, restoration and broader resource
acceptance remain open.

- [ ] **R** Measure durable portable asset copies in frozen attempts and engine
  envelopes, whole-document rewriting, memory/I/O and send staging cleanup under
  realistic concurrency/media, including additional asset-conflict record fetches. Keep 10MiB/file and 32MiB encoded state bounds;
  evaluate sidecar staging only from measured evidence and a recovery design.
- [ ] **B** Validate the new custom CKAsset path across shared-account permissions,
  revocation/account changes, offline/throttling, interruption and consistent backup
  recovery. Prior NSPersistentCloudKitContainer attachment evidence is historical.
- [ ] **R** Deploy the optional GraphEvoNode asset field to production before public
  activation and document whole-record asset conflict/clock and timeout semantics.


## T05 pause follow-ups

- [ ] **B** Extend T05 admission to future background/native scheduling paths.
  [T06 foreground evidence](results/automatic-foreground-sync-2026-10-31.md)
  covers explicit manager scheduling only. Preserve per-graph zone filtering and
  admission across native callbacks/receipts; broader framework paths remain open.
- [ ] **R** Exercise long paused backlogs, shared-account revocation/account change,
  stop/interruption and supported-scale control/observer resource costs without
  raising PH/pending/inbox limits or claiming distributed writer exclusion.
- [ ] **B** Protected migration must add its separate exclusive local access,
  durable readiness/intent and backup contract. Process-local pause is not enough.


## T06 foreground automatic synchronization follow-ups

- [ ] **B** Extend foreground-only T06 admission/lifecycle evidence to future
  background/APNs/silent-launch scheduling, with expiration and account/permission
  coverage. A notification hint is not proof of notification delivery.
- [ ] **R** Measure foreground 60s polling, PH scanning, full-document rewriting,
  scheduler/observer costs and long offline/backoff workloads at supported scale.
  No larger limits or timing guarantees are inferred from virtual-clock tests.
- [ ] **B** Retain shared participant, interruption/backup and protected migration
  gates; automatic foreground operation neither excludes local writers nor
  certifies migration readiness. See [T06](graphevo-2-automatic-sync.md).


## T07 sharing follow-ups

Integrated [T07](graphevo-2-zone-sharing.md), [#119](https://github.com/bbruno84/GraphEvo/pull/119), has a
[nine-stage two-account result](results/zone-sharing-2026-10-31.md), covering
read-write/read-only and bidirectional entity/file recovery with a private control.
It retains release gates for invitation
UI/URL routing, leave/revoke/purge/reinvite, account and cached-read policy,
permission changes/offline/stale controls, concurrent invitations and actual
interruption fault injection. Measure additional root access metadata and bounded
session share-attempt markers with backup/recovery costs. Initial two-account
sharing evidence does not close these gates or authorize native schema changes.


## T08 sharing lifecycle follow-ups

Candidate [T08](graphevo-2-sharing-lifecycle.md) introduces destructive participant
cleanup, durable lifecycle commands/generations and whole shared-engine refetch
on explicit rejoin. Retain **B** account/protected-data/cross-process reader,
interruption and backup restoration coverage; **R** measure journal/tombstone
retention, repeated subscription/refetch costs, external asset cleanup and long
offline control retries. Do not infer distributed ordering or backup/secure-erasure
certification from a bounded same-process purge or the initial hardware fixture.
The [T08 report](results/sharing-lifecycle-2026-10-31.md) closes the bounded
iPad/XR downgrade, revocation, deliberate pre-destruction interruption/restart,
empty rejoin, leave and foreground paused-graph control scenario. Broader fault
injection, offline hardware leave, account/cross-process policy and restoration
remain open; do not expand the evidence beyond its tested source pins.

## Typed local properties (P01–P03)

- [x] Review and integrate P01 S04 storage with codec, PH, attachment, backup and
  internal v1 conversion regression coverage; no public opener or implicit upgrade.
- [x] Complete P02 native/residual planner, consulted-field validation, explain
  diagnostics and bounded source-order semantic regression tests.
- [x] Complete P03 actual-runtime S03/S04 measurements and fresh physical
  CloudKit/sharing/empty-recovery evidence before closing adoption gates.
- [ ] Measure S04 indexes, raw/external binary storage and serialized exceptions
  at the end-of-alpha cost review. Retain mandatory v1 migration and production
  bootstrap/cloud-cutover acceptance as separate gates.

See [the typed-property contract](graphevo-2-typed-properties.md).

P01 closes only local/injected S04 storage adoption through
[PR #133](https://github.com/bbruno84/GraphEvo/pull/133) and
[checkpoint #346](https://github.com/bbruno84/GraphEvo/actions/runs/41403835359).
Physical S04, native query execution and performance acceptance remain open.

P02 closes its bounded execution contract via [PR #134](https://github.com/bbruno84/GraphEvo/pull/134)
and corrected [checkpoint #351](https://github.com/bbruno84/GraphEvo/actions/runs/41408938116).
The first #349 did not cover the subsequently found aggregate defect. P03 retains
measured costs and refusals separately; planner integration is not performance
acceptance for every allowance or dataset.

P03 closes the bounded validation protocol in the
[S04 runtime/physical report](results/s04-typed-properties-runtime-and-cloud-2026-11-02.md):
fourteen physical stages and complete runtime measurements, without a cloud reset.

- [x] Review and resolve the S04 2,000-record native-sort refusal at 100,000
  steps, without raising budgets or hiding the refusal. The
  [follow-up](results/s04-sort-capacity-2026-11-02.md) integrates through #137
  after review and full checkpoint #362 on `b9fcd03`. It retains the original
  and heap-only refusals, then passes Release and complete paginated regressions
  with heap merge/direct order reuse. This closes the bounded refusal only.
- [ ] Establish broader representative and device capacity acceptance before beta;
  a successful 2,000-record desktop fixture is not a general production envelope.
- [ ] Retain the measured +6.9% fixture disk/index cost and simple-count cost at
  400 records in the end-of-alpha cost review. The approximately 3x selected-row/
  page gain does not establish every supported production envelope.
- [x] Review repeated full adapter Session construction during bulk inserts.
  [Controlled-store access](graphevo-2-controlled-store-access.md), #142, adopts
  transaction-local inventory reuse only under the coordinated writer/process
  fence, with rollback/refusal invalidation and final-detach protection. Full
  checkpoint #387 on `2e0d2b1` passes macOS/iOS and both Swift 6 consumers.
  Generic/unprotected adapters retain their separate path; broader device/batch
  performance measurement remains R work.

## MF09 local conversion/opening checkpoint

- [x] Review/integrate explicit package-only bootstrap through backed-up S04
  conversion and ordinary opening, preserving committed outcomes after failure.
- [x] Record fresh physical local bootstrap/restart evidence separately from
  historical MF07 S03 and P03 S04 cloud fixtures.
- [ ] Retain production/historical source acceptance, public facade/bootstrap,
  physical interruption, external-process exclusion, scale and production cloud
  cutover as open gates; local readiness does not close them.

See [MF09](graphevo-2-local-v1-bootstrap.md).

[MF10](graphevo-2-authoritative-cloud-bootstrap.md) has its contract integrated
through #139 and package-only implementation integrated through #140 after review
and full macOS/iOS checkpoint #371.
The [bounded result](results/authoritative-cloud-bootstrap-2026-11-02.md) distinguishes
physical first-claim exclusion and the twelve-stage same-account iPad/iPhone
protocol from broader production acceptance. Empty-peer/current-state recovery,
ordinary edits and competing-conversion refusal pass within that synthetic scope.
Host v1 writer/completeness policy, historical sources, production binary
acceptance and deployment remain unchecked gates above.

- [x] Review/integrate the bounded package-only authoritative conversion seed and
  initial-peer recovery, including interrupted-import reconciliation, after full
  macOS/iOS checkpoint #371. This closes that implementation checkpoint only.

- [ ] Measure MF10's per-transport authority reads, native receipt/manifest
  validation, seed verification latency and process memory on representative
  workloads before establishing production capacity. Count/byte refusals do not
  certify total memory, SQL I/O, network cost or latency.

MF09 closes its bounded package-only local opening gate through
[PR #136](https://github.com/bbruno84/GraphEvo/pull/136),
[the six-stage local device result](results/local-v1-bootstrap-2026-11-02.md) and
[full checkpoint #355](https://github.com/bbruno84/GraphEvo/actions/runs/41422586643).
This does not close public bootstrap, production/historical source acceptance,
physical interruption, cross-process writers, scale or new-cloud activation.

## Durable spool private device checkpoint

- [x] Verify #144's bounded private spool on same-account physical devices with
  more than 32 MiB total content: [2026-11-04 result](results/durable-asset-spool-device-2026-11-04.md).
  Signed exports `0fc16a3` and `25ef3d2a` retain identical shipping Sources from
  integrated #145. iPadOS 27.0/iOS 27.2 recover 40 MiB plus empty/control assets,
  complex serialized payloads, frozen outgoing and retained incoming checkpoint
  restarts, exact files/IDs and another empty replica. Eight reports pass; the
  original global-inbox assertion failure is retained with a guarded read-only
  continuation. No import replay or broad B/R gate closure. In-flight
  interruption/power-loss, production resources, cross-account and restoration
  remain open. Protocol/evidence integrate through #146; reviewed full checkpoint
  [#41782215684](https://github.com/bbruno84/GraphEvo/actions/runs/41782215684)
  passes on `db80d8cd`: 993 macOS functions, 990 passed iOS functions with the known
  skip and both Swift 6 consumers.

## CI checkpoint scope

- [x] Review and integrate the durable CKAsset spool increment with
  [full macOS/iOS checkpoint #41715897139](https://github.com/bbruno84/GraphEvo/actions/runs/41715897139)
  on `ae0d50e`: 993 macOS functions, 990 passed iOS functions with one known
  skip, and both Swift 6 consumers. Local reference/restart and 36 MiB seed
  tests do not certify physical CloudKit delivery, process interruption, disk exhaustion,
  production-scale activation memory or network latency. Preserve S04 native
  attachment placement and ordinary serialized consumer payloads. See the
  [spool contract](graphevo-2-durable-asset-spool.md).

- [ ] Retain full macOS/iOS validation for legacy/shared foundations, test/CI
  infrastructure, milestone/tag/release acceptance. A v2 profile checkpoint
  verifies store/runtime/model and Swift 6 consumers, with the large capacity
  fixture deferred to full/relevant local checks; it is not full beta acceptance.
  See [CI profiles](graphevo-2-ci-checkpoints.md), integrated through #138 after
  reviewed full checkpoint #365 on `1927535`. Keep historical full-run evidence
  unchanged and record each new run's actual profile. Cold remote v2-profile
  timing remains unmeasured; full iOS and runner-queue costs remain explicit.

## MF11 native staged conversion

- [x] Implement and locally review native staged conversion without a graph-sized payload
  snapshot or whole-database property-byte budget; preserve source, backups,
  identity allocation, row checkpoints and atomic readiness/sync sealing.
  Follow-up review includes fault-tested seed metadata stamping before destination
  publication, preserving absent/retryable targets on preparation failure.
- [x] Complete the required full reviewed checkpoint and integrate #141. #381
  passes 960 macOS functions, 958 passed iOS functions with the known skip and
  both Swift 6 consumers on `22db0d67c6fff65d2665c64fbc53e20164db00d7`. Only the
  unassigned iOS job is retried; the successful macOS job is retained. Earlier
  #374/#375/#378 failures remain evidence, not passing checkpoints.
- [ ] Retain larger identity-map/receipt formats, platform memory/disk capacity,
  historical model/codec coverage, physical interruption and public/production
  cutover as separate acceptance gates. Synthetic payload/page tests do not
  certify every workload; private source artifacts remain outside Git/CI/cloud.

See [MF11](graphevo-2-native-v1-migration.md).

## Alpha CI frequency — maintainer revision 2026-11-04

Review and adequate affected local checks are the ordinary alpha integration
gate. Remote checkpoints are explicitly requested for grouped reviewed work;
retained labels and intermediate pushes do not request another run. Hosted
runner unavailability is recorded without blocking an authorized, locally
verified alpha merge. Actual failures remain investigated and recorded. Required
beta/release and published-tag remote gates remain open until actually passed.
This scheduling policy closes no acceptance box or physical-device gate.
