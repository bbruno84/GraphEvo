# GraphEvo 2 — current development status

Updated: 2026-11-01. This is the single entry point for **integrated work,
laboratory-only work and next steps**. The specification defines contracts, the
delivery plan defines milestones, and experiment reports retain historical
evidence. A successful experiment or merged child PR alone does not establish
integration into the main v2 branch or beta readiness.

## Current focused work

MF05 protected original-store publication is in progress on
`codex/v2-migration-publication`, based directly on MF04c/#125. The
[contract](graphevo-2-migration-publication.md) adds a verified original backup,
bounded atomic final-state application and durable local commit/recovery evidence.
Local macOS/selected iOS tests, seven iPad/XR stages and review pass; the
[result](results/migration-publication-2026-11-01.md) separates their evidence.
The full CI checkpoint and integration are pending. Participant workspaces and mandatory v1 conversion remain
separate work.

## Latest integrated increment — MF04c workspace seal and recovery

[PR #125](https://github.com/bbruno84/GraphEvo/pull/125) groups bounded PH reduction,
authoritative native sealing, explicit restart/source-freshness recovery and
activation-bound owned cleanup directly from MF04b/#124 (`7c2b5a9`) into
`codex/graphevo-2`. A sealed GraphStore remains readable and rejects mutation;
new activations fence stale controls. Source bookkeeping is allowed only without
reconstructed application effects. Cleanup retains native/global claims through
detachment and deletion. S03, application cloud formats and session format 6 are
unchanged; format-2 workspaces refuse older alpha documents unchanged.

Review corrected two P2 findings (writer accounting and corrupt marker-row
admission); final focused macOS/iOS checks passed. The single full
[CI checkpoint #320](https://github.com/bbruno84/GraphEvo/actions/runs/41311865161)
passed on reviewed head `75b95b1419768934aced22e72d189fbf66b1906a`: macOS 860
functions plus both consumers; iOS 858 functions / 954 invocations passed, no
failures and one pre-existing legacy simulator-alias skip. Subsequent integration
notes are documentation-only and do not rerun unchanged code/tests.
The [scoped result](results/migration-workspace-sealing-recovery-2026-11-01.md)
retains the independent-process native-fault/recovery protocol at `a1334e2`
separately from corrective review and CI. No cloud publication, participant,
power-loss, external-writer, scale or beta acceptance is inferred.

## Earlier integrated increment — MF04b isolated working-copy preparation

[PR #124](https://github.com/bbruno84/GraphEvo/pull/124) delivers protected complete
copying, native working-purpose admission, a fresh working PH baseline and
close/ownership-checked discard directly from MF04a/#123 (`3b0c326`) into
`codex/graphevo-2`. The ordinary editable GraphStore has no sync session. Copied
transport/checkpoint authority is cleared without altering the original's pending
work, identities, files or policy. Preparation creates no backup. S03, cloud
record/asset formats and session format 6 are unchanged. Seal, restart activation
and publication are not implemented by this increment.

Review found no remaining blocking defect and added two negative admission
regressions. The single full [CI checkpoint #317](https://github.com/bbruno84/GraphEvo/actions/runs/41306827139)
passed on reviewed head `181b80cbb3321878e801f4cf380c8a810086c425`: 839 macOS
functions, Swift 6 and independent-process consumers; 837 iOS functions passed
with one pre-existing simulator alias skip. Subsequent integration/evidence notes
change only documentation and do not rerun unchanged code/tests. The
[local/CI result](results/migration-workspace-preparation-2026-11-01.md) preserves
original broad checks, corrective focused checks and the exact CI pin separately.
Native faults/power loss, external-process writers, filesystem races, scale and
participant/publication gates remain open. No physical/cloud protocol is claimed.

## Earlier integrated increment — MF04a logical emptying

[PR #123](https://github.com/bbruno84/GraphEvo/pull/123) delivers the
[MF04a GraphStore/GraphMutation.removeAll API](graphevo-2-logical-emptying.md)
directly from integrated MF03 (`5b22750`) into `codex/graphevo-2`. It uses normal
local transactions/PH-backed delete batches while preserving graph controls,
zone, share, ledger and other graphs. S03, application node/asset formats and
session format 6 are unchanged. This does not implement the workspace or certify
a global/atomic cloud wipe.

Review found no remaining defect. Two adversarial regressions were added for
cross-graph incoming actions and caught limit refusal without partial emptying;
focused validation passed 15 macOS functions and 12 iOS functions / 13 invocations.
The [result](results/logical-emptying-2026-11-01.md) retains the earlier complete
826-function macOS and 494-function iOS checks plus eight iPad/XR physical stages
at unchanged shipping pin `a19ae62`.

Full [CI checkpoint #311](https://github.com/bbruno84/GraphEvo/actions/runs/41301437693)
passed macOS and iOS on reviewed head
`5ca26449a45704e8ebbb95a51f72fba0e781c0ef`, including the added regressions,
after review and before merge. Subsequent checkpoint/integration notes change only
documentation and do not rerun unchanged library tests. The PR records the final
merge and integration commit. Physical RW guest, concurrent remote writers,
account/permission change, fault/scale and external-storage reclamation gates
remain open.

## Earlier integrated increment — MF03 bounded shared ledger

[PR #122](https://github.com/bbruno84/GraphEvo/pull/122) delivers
[MF03](graphevo-2-shared-ledger.md) directly from #121 (`d17676d`) into
`codex/graphevo-2`. It retains complete current/previous operations, 32 compact
significant events and bounded consumer JSON outside Core Data. Control transport
continues during graph-data pause, with explicit revision conflicts, durable
in-flight evidence and explicit restart recovery. Session format 6 refuses older
alpha documents unchanged; S03 and graph-node/asset formats are unchanged.

Corrective review closed two P2 findings in `7dd8ecf`: preserve hints arriving
during a successful turn and fence failure/retry state to the ledger generation.
The final local suite passed 813 macOS functions and 481 selected iOS functions /
566 invocations. The [scoped result](results/shared-ledger-2026-11-01.md) retains
six physical iPad/XR stages at the original `9c6ee82` pin, separately from the
corrective deterministic coverage.

The full [CI checkpoint #303](https://github.com/bbruno84/GraphEvo/actions/runs/41295379797)
passed both macOS and iOS jobs on reviewed head
`a2f029a056929e7ba6e57ac80b1f80cb2ebed558`, after review and before merge.
Subsequent integration/evidence changes are documentation-only, with unchanged
shipping source `7dd8ecf`; they do not rerun unchanged library tests. The PR records
the final merge and integration commit. Broad physical fault/concurrency, sizing,
background/APNs and actual migration execution gates remain open.

## Earlier integrated increment — MF02 compressed backup packages

[PR #121](https://github.com/bbruno84/GraphEvo/pull/121) integrates
[MF02](graphevo-2-backup-packages.md) directly into `codex/graphevo-2` from #120
(`2009582`). Completed local and exported backups use the maintainer-selected
`.geb` extension and the same manifest-first single-file format. Bounded SDK zlib
streaming preserves strict framing/input/expansion checks; legacy directory
backups remain readable/exportable. No schema, graph/cloud wire or session
format changes are introduced.

Snapshot-owned graph/cloud holds end after coherent native copying. Compression
and verification continue asynchronously, preserving manual/other holds. Export
copies an existing compressed package; import copies it into another collection.
Native validation, complete attachment checks and PH-preserving materialization
remain distinct from graph/cloud activation or in-place rollback.

[Original results](results/backup-packages-2026-11-01.md) retain source `3e509f0`,
compression measurements and successful native transfer/recovery in both
macOS/iOS Simulator directions. The mixed fixture reduces approximately 8.85 MB
to 4.26 MB. This is bounded local evidence, not physical/account/production-scale
acceptance. The [review/correction](results/backup-packages-review-2026-11-01.md)
reproduced one P2 in legacy import preflight; `8bf64b0` closes it with committed
direct/alias source-preservation regressions. Corrective re-review found no
remaining blocker in the examined paths.

Corrected validation passes 786 macOS functions (331 legacy, 356 store, 76 runtime,
23 model), 431 selected iOS Simulator functions/510 invocations, Release build,
Swift 6 ModelConsumer and manifest/diff checks. The one
[macOS/iOS checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/41289164075)
passes on reviewed/documented head `89644e1`, including ModelConsumer and
independent-process local read-only checks. Final integration-status edits are
documentation-only; no source/test/workflow changes follow the green checkpoint.
The maintainer authorized merge after successful review/corrections and CI.

## Earlier integrated increment — T08 and MF01

[PR #120](https://github.com/bbruno84/GraphEvo/pull/120) integrates
[T08 sharing lifecycle](graphevo-2-sharing-lifecycle.md) and
[MF01 local maintenance/backups](graphevo-2-local-maintenance.md) directly into
`codex/graphevo-2` from #119 (`3260627`). MF01 extended the unmerged T08 PR at the
maintainer's request; no dependent implementation PR or experiment parent is
introduced. Native S03 and cloud node/asset formats are unchanged. T08 explicitly
uses session format 5; MF01 does not change that document.

Confirmed revocation/leave removes the participant replica and pending work while
owner-private/control graphs survive. Read-only downgrade preserves pending
uploads and permits incoming changes. Owned local reservations cover all aliases;
verified complete native backups include attachment bodies, optional reasons,
graph-scoped recovery evidence and durable retention. Restore materializes a new
empty local destination and does not rewind shared engines/session state.
Current backups are uncompressed directory bundles.

The [T08 physical report](results/sharing-lifecycle-2026-10-31.md) retains its
actual iPad/XR source pins, independent owner inventories and corrective scope.
The [original MF01 local report](results/local-maintenance-2026-11-01.md) and
[corrective review](results/local-maintenance-review-2026-11-01.md) remain distinct:
MF01 adds no physical/live CloudKit claim. T08's corrective review at `70909cf`
closed its P1/two P2 findings. MF01 review at `1e9a16d` reproduced two P2 defects;
`c174e4a` closes them with committed direct/aliased destination preservation,
exact recovery-hint and actual observed-query recovery regressions. Corrective
re-review found no remaining blocker in those paths.

Final local checks pass 777 macOS functions (331 legacy, 347 store, 76 runtime,
23 model), 422 selected iOS Simulator functions/487 invocations, Release build,
Swift 6 ModelConsumer and manifest/diff checks. The one combined
[macOS/iOS CI checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/41286055397)
passes on `bcac4bc`, after corrective review. It also passes ModelConsumer and
independent-process local read-only validation. Final integration-status edits
are documentation-only; no source/test/workflow change follows that checkpoint.
The maintainer authorized merge after successful CI. Historical reports/branches
remain retained. Background/APNs, cross-process maintenance, power-loss/scale,
in-place/cloud restoration, migration ledger/executor and mandatory v1 conversion
remain separate gates.

## Earlier integrated increment — T07

[T07 explicit custom zone sharing](graphevo-2-zone-sharing.md),
[PR #119](https://github.com/bbruno84/GraphEvo/pull/119), integrates directly into
`codex/graphevo-2` from #118 (`9238b95`), after review, corrective re-review,
full CI and the maintainer-authorized merge. No experiment implementation or
new public opener is promoted. Native S03 is unchanged; the session document
advances to format 4, without changing cloud node/asset or transport formats.

Owner graph zones stay private; account-targeted read-write/read-only invitations
expose the same zones to participants through the shared engine. Acceptance,
local import and current cloud authorization remain distinct observations.
The first review reproduced two P2 issues: premature create intent and control
records hidden by a bounded application prefix. Corrected source `b171cde`
passes both original reproducers and six committed regressions; corrective
re-review finds no remaining blocker in the reviewed paths.

Reviewed head `61b066a0520bd2da81a7e477e4aaa5f9417c3ff6` passes full macOS/iOS
[checkpoint 41228512926](https://github.com/bbruno84/GraphEvo/actions/runs/41228512926),
requested after review. Final integration-status edits are documentation-only;
library code, tests and workflow remain identical to the reviewed, CI-tested head.
Local validation passes 731 macOS functions (331 legacy,306 store,71 runtime,
23 model), 83 selected iOS tests, Swift 6 ModelConsumer and manifest/diff checks.

The [physical report](results/zone-sharing-2026-10-31.md) retains the original
nine-stage matrix's `02b294e`/`d5e4693` pins and the three-stage `b171cde`
identity/create/accept recheck. It covers private/shared routing, permissions,
a private control, files, bidirectional edits and empty recovery within those
actual scopes. No reset, store/token copy or consumed mutation replay occurred.
Leave/revoke/purge/reinvite, account/cached-read policy, offline/stale permission,
crash/backup, protected migrations and public activation remain separate gates.
The workflow remains **review → CI → authorized merge**; this is not beta entry.

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
GraphCoordinator. The package-only engine foundation is now implemented on its
focused branch; public activation and end-to-end custom sync remain pending.
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

The reviewed implementation in [#108](https://github.com/bbruno84/GraphEvo/pull/108)
returns directly from `codex/v2-history-pending` to the v2 integration line. It supplies the package-only
[PH processor, durable pending checkpoint and immutable attempts](graphevo-2-history-processing.md).
The PR records exact-head automated checks and its merge disposition. Local
validation passes 595 tests, the Swift 6 consumer and selected
iOS Simulator checks (35 functions / 44 expanded cases). Controlled incoming
patches are observed without upload feedback; engine transport, full incoming
operations and real crash/cloud acceptance remain open. No experimental
implementation is merged.

The PH increment #108 is reviewed/merged as `0ddd613`, with exact-head iOS/macOS
CI `41139921643` green. Its merge tree matches reviewed head `53468a9`.

The reviewed implementation in [#109](https://github.com/bbruno84/GraphEvo/pull/109)
returns directly from `codex/v2-sync-engine-foundation` and supplies [shared engine sessions,
zone bindings and a durable incoming inbox](graphevo-2-sync-engine-foundation.md).
The PR records exact-head CI and merge disposition. Native engines are manually scheduled, package-only;
no upload, GraphRecord import or automatic synchronization is activated. The
state directory is separate from graph PH checkpoints; S03 is unchanged.
Its local checkpoint passes 616 tests (331 legacy, 191 store, 71 runtime,
23 model), selected iOS Simulator checks (55 functions / 65 expanded cases)
and the Swift 6 consumer. Physical native-engine delivery remains a separate gate.

The engine foundation #109 is reviewed/merged as `e26a0cd`, with exact-head
macOS/iOS CI `41143330378` green; the merge tree matches reviewed head `efc9fe9`.

The reviewed implementation in [#110](https://github.com/bbruno84/GraphEvo/pull/110)
returns directly from `codex/v2-cloud-record-format` and adds [CF01 logical record conversion](graphevo-2-cloud-record-format.md)
over immutable PH attempts and the incoming inbox envelope. The PR records
exact-head automated checks and merge disposition.
One GraphEvoNode record represents each application primitive; properties remain
serialized and S03 is unchanged. No outgoing worker, server metadata persistence,
incoming application/receipt, attachment transport or remote queries are activated.
Its local checkpoint passes 630 tests (331 legacy, 205 store, 71 runtime,
23 model), the Swift 6 consumer and selected iOS Simulator checks (69 functions /
93 expanded cases). The initial Xcode/CoreSimulator setup mismatch was resolved
before the successful simulator rerun. Physical cloud acceptance remains open.

CF01 #110 is reviewed/merged as `900d51a`, with exact-head macOS/iOS CI
`41184685226` green; its merge tree matches reviewed head `3d4150d`.

The reviewed implementation in [#111](https://github.com/bbruno84/GraphEvo/pull/111)
returns directly from `codex/v2-record-transport` and supplies [T01 manual record
send/import and durable effect receipts](graphevo-2-record-transport.md).
The PR records exact-head automated checks and its merge disposition.
Native driver hooks are connected to CKSyncEngine; deterministic local tests use
an injected bus, not physical CloudKit. Persisted graph routes contain only graph
and zone IDs; current store URLs are runtime registrations supplied on app bootstrap.
The engine document moves to format 2, refusing old alpha files unchanged; S03
and CF01 remain unchanged. Assets, automatic sync and public activation remain open.
Its local checkpoint passes 648 tests (331 legacy, 223 store, 71 runtime, 23 model)
and selected iOS Simulator checks (87 functions / 111 expanded cases). The first
iOS transport run failed on persisted/case-folded path use; the final path-free
container-relocation protocol passes. Native physical CloudKit validation remains open.

T01 #111 is reviewed/merged as `06b5ae5`, with exact-head macOS/iOS CI
`41190746167` green; the merge tree matches reviewed head `5d588ea`.
An initial CI store-test process exit (`41189893048`) did not reproduce in local
iOS 18.5 validation (222 functions / 262 expanded cases) or the final CI run.
The cause remains undiagnosed; explicit iOS result-bundle retention was added.
The focused [#112](https://github.com/bbruno84/GraphEvo/pull/112),
`codex/v2-record-transport-device`, supplies the
[real transport laboratory](../../Experiments/RecordTransportProbe/README.md).
Its external-only bridge does not activate a public production opener or merge
prototype sync code. [Ten real private-device stages](results/record-transport-cloudkit-2026-10-31.md)
now pass across iPad/iPhone: exact server/peer values, updates/deletions, real server
metadata reuse, owner reopen and genuinely empty final recovery. B remains unchanged
and imports do not feed upload; final complete local/server inventories contain no
unexpected records. Conflicts, assets, sharing and interruption gates
remain open. #112 is reviewed/merged as `30f7089`, with exact-head macOS/iOS CI
`41192210370` green; the merge tree matches reviewed head `ee073e8`.

## Concurrent conflict validation

The reviewed validation in [#114](https://github.com/bbruno84/GraphEvo/pull/114)
returns directly from `codex/v2-concurrent-conflicts` and adds an external-only
[conflict laboratory](../../Experiments/RecordConflictProbe/README.md) and its
[thirteen-stage real result](results/record-conflicts-cloudkit-2026-10-31.md).
On the integrated `31eac7c` runtime, real update/update collisions, partial success,
independent-graph progress, newer local generations, incoming refusal and restart
preservation pass on iPad/iPhone. Stale deletion removes a newer server value;
stale update after deletion returns unknownItem without resurrection. A fresh
replica recovers only the actual final server state. Production code/schema and
CF01 are unchanged. A consumer resolution/rebase boundary and structural conflict
matrix remain open. Reviewed head `de2667a` is merged as `4e9d30c`; the merge tree matches.
Remote full CI is intentionally skipped for this excluded bridge/report increment
under the new checkpoint policy; local review verifies the bridge matches the
signed device build and all thirteen original passed stage reports remain retained.

## Integrated alpha implementation

| Area | Implemented | Remaining acceptance limits |
|---|---|---|
| A1–A3 | Resource ownership, awaited scopes, persistent IDs, GraphModel/GraphRecord and typed CRUD | Full distributed/platform boundary and concurrency stress gates |
| A4–A5 | Graph catalog/membership, paired resources, sharing and interrupted-assignment ledgers | Account/offline/conflict/recovery and scale gates |
| A6 files | Separate attachment identity, exclusive owner, split metadata/content, binary Data, integrity and cascades | Whole-content backups, providers and physical resource envelopes |
| A7 queries | Bounded descriptors, count/projection/aggregate/traversal, selective bodies and finite-ID guards | Inventory remains; budgets are not total memory/time/SQL-I/O bounds |
| A8 observation | Async current state, cold Combine adapter, shared per-handle query work and dependency invalidation | Live hints are not durable processing; O04 remains open |
| Consolidation | Selected metadata batching, file/query representation and shared-observation implementations | Synthetic measurements do not define production thresholds |
| CF01 / T01 transport | Logical node CKRecords, manual engine send/import, durable attempts, server metadata/effect receipts (#110/#111); bounded private device recovery reported separately | Bounded real collisions verified in T02; consumer resolution/rebase, structural conflicts, assets and public activation remain open; S03 unchanged |
| Engine foundation | ContextManager-owned private/shared sessions, path-free zone routes, persisted inbox/results (#109/#111) | Package-only manual scheduling; broad account/sharing and automatic/background acceptance remain open |
| PH pending | Per-graph discovery, durable pending/checkpoint, immutable attempts and generation-safe acknowledgements (#108) | Package-only; T01/T02 add real transport/generation evidence, while crash/history rebaseline and broader convergence gates remain open |
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

## Alpha CI checkpoints

The maintainer selects [explicit CI checkpoints](graphevo-2-ci-checkpoints.md)
instead of a full macOS/iOS run on every alpha PR and every integration push.
Review and appropriate local verification still apply to each increment. Record
whether remote checks ran or were skipped; only an actual successful run is a
full checkpoint. Latest reviewed code checkpoint: #118, `2c61d40`, CI `41224009459`
(macOS/iOS green, after review). #117/#116/#115 remain the prior pause/asset/conflict
checkpoints. The following #112 runs remain historical checkpoints.
The policy is reviewed/merged through #113 as `31eac7c`; ordinary-alpha run
`41193277258` skipped all expensive jobs, validating policy rather than executing
tests. Stable/v1/release automatic checks remain enabled. The #112 integration
run `41192922760` also passed on `30f7089` before the new policy took effect.

## Next steps and operating rule

1. T03 conflict policies, T04 CKAsset transport, T05 per-graph pause and T06
   foreground automatic orchestration are integrated through #115/#116/#117/#118
   after review and full CI checkpoints. Structural conflicts, sharing and
   background scheduling remain subsequent work on the custom backend;
   protected application-data migration remains separate.
2. Complete protected application-data migration and mandatory v1 conversion on
   the selected architecture; retain existing schema/format decisions and backups.
3. Resolve the [post-alpha beta/stable gates](graphevo-2-post-alpha-checklist.md).
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


## T03 automatic conflict increment

`codex/v2-conflict-policies` starts directly from integrated #114 (`4e9d30c`).
[T03](graphevo-2-conflict-policies.md) implements local per-graph cloudWins/default
lastEditWins, Graph-owned edit dates, durable current-local resolution, grouped
receipts, one targeted retry and delete-wins traces. Native S03 is unchanged;
wire/session/transport formats become 2/3/2, refusing old alpha state unchanged.
The package-only boundary remains. The [device result](results/conflict-policies-cloudkit-2026-10-31.md)
records bounded physical convergence separately from the broader acceptance gates.
[PR #115](https://github.com/bbruno84/GraphEvo/pull/115) integrates this increment
into `codex/graphevo-2` following the maintainer-authorized merge.
Initial local validation passed 667 functions; the physical protocol passed all
eight stages on its pinned runtime. Initial exact-head CI `41199122433` passed
on `2f1f9bd`. Review found same-transaction identity reuse and loss of earlier
rebases under bounded selection. The focused corrections add tracker checks and
committed pending-ID propagation, with direct/cascade/rollback and bounded retry
regressions. S03, wire and persisted state formats remain unchanged.
Corrected local validation passes 671 functions (331 legacy, 246 store, 71 runtime,
23 model); selected iOS18.5 suites pass 57 functions / 75 expanded cases. The
corrected code head `85efea1986f51c1f7318df5dae8f7071106f9d78` passed full
macOS/iOS checkpoint `41201271653`. Final integration-status edits are
documentation-only and do not repeat the full checkpoint. S03 and the bounded
physical evidence remain unchanged. No asset implementation is included.


## T04 asset increment

`codex/v2-cloud-assets` starts directly from integrated #115 (`8d88532`).
[T04](graphevo-2-cloud-assets.md) adds automatic CKAsset content transfer, portable
byte snapshots and independent cancellable/deadlined async exports in the existing
package-only path. Wire3 attachments retain S03 and local legacy/split formats;
normal primitives remain wire2. No new public opener or on-demand network promise.

The [physical result](results/cloud-assets-2026-10-31.md) retains the initial fixture
error and the real missing-conflict-asset failure, plus guarded continuations.
Corrected runtime834e674 passes both policies, reopen/cascade and fresh recovery;
full local validation passes679 functions and selected iOS18.5 passes63/90.
[PR #116](https://github.com/bbruno84/GraphEvo/pull/116) integrates this increment
into `codex/graphevo-2` following final review and maintainer-authorized merge.
Final restoration hardening passes 680 local functions and iOS18.5 64/91.
Reviewed code head `698a94bc0786e3220dfd78ef965b904be1e7067c` passed full
macOS/iOS checkpoint `41205963479`. Final status edits are documentation-only;
the integrated code is identical to the CI-tested code. Extra durable copies
and broad account/sharing/crash/backup costs remain gates.


## T05 per-graph pause increment

[PR #117](https://github.com/bbruno84/GraphEvo/pull/117) integrates
`codex/v2-graph-sync-pause` directly into `codex/graphevo-2`, following review,
full CI and the maintainer-authorized merge. Its base is integrated #116 (`3b495ba`).
[T05](graphevo-2-sync-pause.md) adds process-local active/requested/paused state,
per-graph admission and orderly drain. Local writes retain the existing PH/pending
path. Other graph zones remain eligible on the same manual engine. Alias lifetime,
cancelled waits, failures and attachment refresh coverage are explicit; stop and
migration exclusivity remain separate. S03 and wire/state formats do not change.
The package-only boundary remains; this is not beta acceptance.

The [physical result](results/graph-sync-pause-2026-10-31.md) records seven passed
stages on runtime `3a3e47b450a68166bb135648dee7d76802f366cc`: paused A/local edits,
active B, resumed convergence, process reopen and empty recovery on same-account
iPad/iPhone. That evidence retains its actual runtime pin.

Initial checkpoint `41215698406` passed macOS but failed an iOS shared-asset
fetch-count assertion. The test now proves both callers joined the held refresh
before releasing it; the original assertion remains. Corrected head `438be96`
passed checkpoint `41216918331`, before the subsequent review correction.
Review then reproduced stale pause state when a waiting reopen retired the last
closed owner before its closing caller resumed. Both successful paths now use
one generation-checked cleanup helper. The extended regression failed before
the fix and passes 25 repeated executions afterward.

Reviewed source head `3f5fd31b44a706125109231ec189a11a8e9e1dab` passes full
macOS/iOS checkpoint `41218175454`, requested after review immediately before
merge. Local validation passes 690 macOS functions (331 legacy,265 store,
71 runtime,23 model), selected iOS18.5 passes 91 functions/106 expanded cases,
and manifest/diff checks pass. The final integration-status edits are
documentation-only; library code and workflow match the reviewed, CI-tested head.

The maintainer's order is **review → CI → merge**. PRs start without the checkpoint
label; review/corrections and local checks finish before requesting final CI for
an authorized merge. Earlier T05 runs keep their chronology and do not set policy.
SharedObservation, IdentityLookup and ConsolidationCosts smoke steps are removed
from CI. They remain local experiments with separate evidence; CI retains library
build/tests and model/process consumer integration. Broader scheduling, sharing,
account/crash/backup and protected migration gates remain open.


## T06 foreground automatic synchronization increment

[PR #118](https://github.com/bbruno84/GraphEvo/pull/118) integrates
`codex/v2-automatic-cloud-sync` directly into `codex/graphevo-2`, following review,
full CI and the maintainer-authorized merge. Its base is integrated #117 (`f459ae2`).
[T06](graphevo-2-automatic-sync.md) adds explicit package-only foreground scheduling,
consumer-only commit hints, fair scope workers, 60s reconciliation, transient retry
advice/backoff and operational status. T05 admission and existing PH/transport
paths remain authoritative. S03, wire and document formats remain unchanged.

The [physical result](results/automatic-foreground-sync-2026-10-31.md) records nine
passed stages on runtime 52fed77, including actual 60s catch-up without forwarded
notifications, A pause/B progress, resumed A4/B3 convergence, restart and empty
recovery. A tenth independent empty replica passes on lifecycle-hardened
runtime 0c25ea6. All reports retain their actual pins; no original mutation was
replayed or container reset. Retry/backoff is verified locally, not relabeled as
physical rate-limit evidence.

Review identified two P2 issues on 7c5d773: a fetch wake could spin while an eligible
initial turn was still debounced, and a separate scope-advice lookup could lose
the completed send's retryAfter to a later operation. The scheduler now gates
that fetch wake on the initial deadline; sends snapshot error/advice before
releasing scope admission. The original manual error contract is preserved.
The initial-debounce regression failed before correction. Both corrected
regressions pass 10 repeated runs; focused re-review finds no remaining blockers.

Reviewed source head `2c61d40b6433ed344f946ed63509a711c000fd49` passes full
macOS/iOS checkpoint `41224009459`, requested after review immediately before
merge. Local validation passes 713 macOS functions (331 legacy,288 store,
71 runtime,23 model) and 114 iOS18.5 functions/131 expanded executions.
ModelConsumer, manifest, script and diff checks pass. The final integration-status
edits are documentation-only; code, tests and workflow match the reviewed,
CI-tested head. No repeated unchanged-library checkpoint is requested.

The order remains **review → CI → merge**. Background/APNs delivery, broader
sharing/account/offline, resource/crash/backup and protected migrations remain
acceptance gates. This is neither public activation nor beta/release acceptance.
