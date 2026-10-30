# GraphEvo 2 — current development status

Updated: 2026-10-30. This is the single entry point for **integrated work,
laboratory-only work and next steps**. The specification defines contracts, the
delivery plan defines milestones, and experiment reports retain historical
evidence. A successful experiment or merged child PR alone does not establish
integration into the main v2 branch or beta readiness.

## Active branch and completed reorganization

Develop on **`codex/graphevo-2`**. C01 #78 is integrated as `f47776f`; cumulative
consolidation #81 as `4ae3468`. The latter merge tree was verified identical to
reviewed head `b1def55`, with exact-head macOS/iOS CI `41078884832` green. The
complete local suite at that checkpoint passes **567 tests** (331 legacy,
142 store, 66 runtime, 28 model). CI for integration merge commits is separate.

| PR | Final disposition |
|---|---|
| [#78](https://github.com/bbruno84/GraphEvo/pull/78) | Reviewed/merged baseline harness and measurements into v2 |
| [#79](https://github.com/bbruno84/GraphEvo/pull/79) | Closed as superseded; all commits plus corrections are included through #81 |
| [#80](https://github.com/bbruno84/GraphEvo/pull/80) | Closed as superseded; all commits plus corrections are included through #81 |
| [#81](https://github.com/bbruno84/GraphEvo/pull/81) | Retargeted directly to v2, reviewed and merged as the final implementation |

#79/#80's old CI failed on non-Sendable test-closure transfer. Successor commits
`b5defcd`/`1011398` corrected queue transfer/context creation; the final head passes
CI. No red intermediate was independently merged as accepted. Branches, commits,
rejected variants and measurements remain available; history was not rewritten.
No experiment store/mutation was replayed for this cleanup.

The old `codex/v2-consolidation-costs`, `codex/v2-cost-experiments`,
`codex/v2-attachment-metadata-experiment` and `codex/v2-cost-experiment-matrix`
branches are historical references, not alternative integration lines. Do not
start new features there. `develop` remains v1, `master` stable. The documentation-
only design PR #68 retains its separate purpose.

The focused [M16/S02 change, #103](https://github.com/bbruno84/GraphEvo/pull/103)
removes native/public application versioning and the proposed format registry.
Its local checkpoint passes 557 tests (331 legacy, 137 store, 66 runtime, 23 model)
and the public Swift 6 consumer. The earlier 567-test checkpoint above remains
historical; removed format-policy tests are replaced by consumer-data behavior
and expanded old-model refusal cases. S02 device/cloud acceptance is still open.

## Selected synchronization transition

M17 selects explicit CloudKit sync after the successful bounded CS01 experiment.
The selected design assigns private/shared CKSyncEngine ownership to the
ContextManager and one graph/store with migration/pause lifecycle to each
GraphCoordinator. Engine implementation remains pending.
See the [transition contract](graphevo-2-custom-sync-transition.md) for rationale,
retained experiment evidence, cleanup scope and implementation order.

Native mirroring isolation [#105](https://github.com/bbruno84/GraphEvo/pull/105)
is reviewed/merged as `32ae83f`, with exact-head iOS/macOS CI `41119977677` green.
Its 559-test local checkpoint retains operational old alpha entry points; no
experiment implementation was merged. Native A4/A5 results remain historical
backend evidence, not acceptance of replacement sync.

The [package-only exclusive coordinator](graphevo-2-graph-coordinator.md),
[#106](https://github.com/bbruno84/GraphEvo/pull/106), is reviewed/merged as
`c3e7583` with exact-head iOS/macOS CI `41123609834` green and 574 local tests.
It provides one graph/store and independent leases; custom engines/public
activation remain unimplemented.

M18 selects Persistent History after the retained PH01 experiment, instead of a
per-mutation intent journal. [S03 runtime adoption, #107](https://github.com/bbruno84/GraphEvo/pull/107)
is reviewed/merged as `25ba9c9`, with exact-head iOS/macOS CI `41133455664` green.
It supplies six preservation flags and schema.3 with no new entities/columns;
its local checkpoint passes 578 tests and the Swift 6 consumer.

The focused `codex/v2-history-pending` increment implements the package-only
[PH processor, durable pending checkpoint and immutable attempts](graphevo-2-history-processing.md).
It has not yet been integrated. Local validation passes 595 tests and selected
iOS Simulator checks (35 functions / 44 expanded cases). Controlled incoming
patches are observed without upload feedback; engine transport, full incoming
operations and real crash/cloud acceptance remain open. No experimental
implementation is merged.

## Integrated alpha implementation

| Area | Implemented | Remaining acceptance limits |
|---|---|---|
| A1–A3 | Resource ownership, awaited scopes, persistent IDs, GraphModel/GraphRecord and typed CRUD | Full distributed/platform boundary and concurrency stress gates |
| A4–A5 | Graph catalog/membership, paired resources, sharing and interrupted-assignment ledgers | Account/offline/conflict/recovery and scale gates |
| A6 files | Separate attachment identity, exclusive owner, split metadata/content, binary Data, integrity and cascades | Whole-content backups, providers and physical resource envelopes |
| A7 queries | Bounded descriptors, count/projection/aggregate/traversal, selective bodies and finite-ID guards | Inventory remains; budgets are not total memory/time/SQL-I/O bounds |
| A8 observation | Async current state, cold Combine adapter, shared per-handle query work and dependency invalidation | Live hints are not durable processing; O04 remains open |
| Consolidation | Selected metadata batching, file/query representation and shared-observation implementations | Synthetic measurements do not define production thresholds |
| Native identity | M16 removed application versioning; M18/S03 preserves graph/node IDs in deletion history through #107 | Defaults unchanged; selected-model and custom-sync device/cloud gates remain open |
| App/widget | Local read-only extension access and ownership safeguards | Broader lifecycle/account/protected-data/OS acceptance remains bounded by the reports |
| Application data | M16 supersedes M2b.1: consumer-owned meaning/optional versions, no registry or global format block | Production migration execution remains open |

Contracts: [typed store](graphevo-2-typed-store.md), [sharing](graphevo-2-user-sharing.md),
[files](graphevo-2-attachments.md), [queries](graphevo-2-queries.md),
[observation](graphevo-2-observation.md), [S02](graphevo-2-identity-schema.md),
[formats](graphevo-2-data-formats.md). The
[16-stage S01 device result](results/s01-native-sharing-recovery-2026-10-30.md)
proves its original S01 sharing/file/recovery fixture, not revised S02 or broader release gates.

## Laboratory-only and unfinished migration work

| Work | Actual status |
|---|---|
| Native schema SM01–SM03 | Bounded lightweight/staged local/cloud experiment, not full v1 conversion |
| M1 journal | Package-only checkpoint/intent foundation, no production consumer executor |
| M2a conversion | Isolated package-only model; atomic data/version/marker publication and native reopen/recovery tested; no public activation or CloudKit admission |
| Historical identity/observation alternatives | Retained probes and reports, not selected by default public opening paths |
| Complete M2 | **Not implemented**: protected-source lifecycle, process readiness, consumer-plan scheduling and public activation. The proposed application format registry is withdrawn |
| M3–M5 | **Not implemented** end to end: v1 source/codec matrix, full data/topology/file conversion, recovery and evaluated optional API adapter |
| M6 | **Not implemented**: durable discovery and later incompatible/partial/old cloud updates with bounded convergence |

See the [manager sequence](graphevo-2-migration-manager.md) and
[M2a](graphevo-2-data-migration-local.md). Consumers migrate application data;
native schema transitions are library-internal. Source API compatibility is
optional; v1 data migration is mandatory, with coordinated v1 writers stopped
before conversion. M16 removes public format DTOs rather than enabling a production manager.

## Next steps and operating rule

1. Review/check/integrate the focused PH pending increment before starting
   another implementation branch.
2. Add ContextManager engine ownership and zone routing over the pending foundation;
   establish engine/incoming recovery, then automatic sync, graph pause,
   conflicts/deletes/assets and sharing lifecycle.
3. Complete protected application-data migration and mandatory v1 conversion on
   the selected architecture; retain existing schema/format decisions and backups.
4. Resolve the [post-alpha beta/stable gates](graphevo-2-post-alpha-checklist.md).
   Prior native backend acceptance does not certify the replacement. Alpha
   integration is not beta acceptance or a release/tag request.

New focused `codex/v2-<topic>` branches start from `codex/graphevo-2` and return
directly through PRs to that branch. Finish review/checks/integration before the
next increment; do not accumulate another experiment-parent stack. If a framework
question needs an experiment, state the question, retain its result and explicitly
select adoption or rejection. Package-only probes may remain while their
production activation remains prohibited.

Update this page when implementation/integration status changes, with contract
and evidence links. Update the post-alpha checklist when gates change. Keep old
reports and dated checkpoints historical, rather than competing current-status
documents. No release branch/tag, schema/API freeze or cloud reset is part of
this reorganization.
