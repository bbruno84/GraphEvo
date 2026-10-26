# GraphEvo 2 — execution checklist

Status: active verification register, started 2026-10-26. The maintainer
authorized autonomous laboratory preparation and execution using connected test
devices. This refines the [roadmap](graphevo-2-verification-roadmap.md). The
[initial specification](graphevo-2-specification.md) and
[delivery plan](graphevo-2-delivery-plan.md) use this evidence; the checklist
itself is not a promise that every candidate API is feasible.

## How to read this register

**Observed** means retained evidence under stated conditions, not universal
acceptance. **Partial** separates completed subchecks from remaining coverage.
**Not run** includes missing instrumentation. **Prerequisite** identifies an
external condition; other independent checks continue. **Rejected** records an
unsupported tested native configuration. A local/injected test never completes
a real cloud row. Every completed row must link to its evidence and limits.

## Current scope: concurrency, realistic graphs and files

The maintainer selected an initial specification gate of Swift 6 concurrency and
ownership, realistic cross-account graph dependencies, and native file
transfer. Continue within the supported public NSPersistentCloudKitContainer
contract, observing application data, public metadata, errors and lifecycle
outcomes without reverse-engineering framework internals. Query, Watch and
v1-transition decisions follow after a candidate model is selected.

The V09 direct-framework fixture is a new disposable model and run. It does
not change the earlier V01/V02 stores or turn local probe results into cloud
evidence. Keep same-device and independent-device conclusions separate.
Unexpected results need a bounded public-API reproduction before shaping the
GraphEvo 2 design.

Use the authorized Development container and synthetic fixtures. Preserve prior
evidence, user configuration and ordinary app data. Revoke/delete only disposable
experiment shares or nodes needed for an explicitly listed lifecycle scenario.
Do not sign a personal device out of iCloud, erase/reset a device, change its
account, or alter the host LAN. Account-change and connectivity tests require an
appropriate controllable fixture or a specific human intervention. Do not merge
PRs as a side effect of laboratory execution.

## V00 — laboratory and provenance

| ID | Check | Status / evidence |
|---|---|---|
| V00.1 | Separate normal demo and direct-framework laboratory lifecycles | Observed locally; [assessment](graphevo-demo-initial-assessment.md) |
| V00.2 | Deterministic fixtures, isolated stores, bounded reports, source/environment provenance | Observed in V01/V02 runs; instrumentation continues per new experiment |
| V00.3 | Native event posting does not wait for MainActor; report/trace retention failures visible | Local regression and [T6 diagnosis](results/v01-t6-ipad-diagnosis-2026-10-24.md) |
| V00.4 | Device/OS/account role, signed Development destination and provisioning preflight | Observed per recorded run; repeat for each new binary/device |

## V01 — graph-zone separation and incremental membership

| ID | Check | Status / evidence |
|---|---|---|
| V01.1 | Working same-account cross-device mirroring control | Observed; [T0](results/v01-t0-2026-10-23.md) |
| V01.2 | Two same-scope stores in one container; two independent one-store containers | First configuration rejected, second unified cloud recovery; [T1](results/v01-t1-2026-10-23.md), [T5](results/v01-t5-2026-10-23.md) |
| V01.3 | Disconnected A/B owner-only shares retain separate zones on a fresh independent same-account peer | Observed; [T6](results/v01-t6-independent-reader-2026-10-24.md) |
| V01.4 | After share creation, add A-003 linked to A-root and edit A-001 using relationship/save only; preserve A zone and all B data | Observed on iPad; [incremental result](results/v01-incremental-membership-2026-10-26.md); no explicit-share fallback |
| V01.5 | Recover the added node, edit and inverse links from cloud into a new replica; compare exact identities | Partial: fresh same-iPad replica matched exact six-member state; independent same-account peer prerequisite |
| V01.6 | Delete A-003, recover its absence and corrected inverse links; preserve B and surviving identities | Partial: retained added/deleted snapshots and fresh same-iPad cloud recovery observed; independent same-account peer pending |
| V01.7 | Reopen the existing writer and fresh reader after the mutations without replaying writes or creating shares | Observed on iPad: original writer reopened and new deleted-phase cloud reader matched; no replay |
| V01.8 | If automatic membership fails, separately test explicit assignment to an existing share | Conditional, not needed for the observed automatic membership path; no such fallback executed |
| V01.9 | Delete/recreate a disposable graph zone while another graph remains usable | Not run; scoped experiment fixture only |
| V01.10 | Assess supported selective recovery/download and zone-count constraints | Not run; current same-owner replicas import A+B into one SQLite |

At the 2026-10-26 inventory, the iPad and different-account XR are connected;
the previously used same-account iPhone is disconnected. A fresh cloud replica
on the iPad can provide preliminary V01.5 evidence while that peer is absent.
The XR can supply independent cross-account checks after a private invitation;
it must not be mislabeled a same-account owner-only reader.

## V02 — separate-account sharing

| ID | Check | Status / evidence |
|---|---|---|
| V02.1 | Private invitation to one authorized account; exact A-only shared-store recovery with B owner-only | Observed; [initial control](results/v02-cross-account-smoke-2026-10-26.md) |
| V02.2 | Participant edits an existing A node; owner recovers edit; both sides reopen existing stores | Observed in initial control; owner used a newly launched container |
| V02.3 | Owner adds/edits/deletes graph members after sharing; participant recovers exact graph and identities | Partial positive: owner A-003 and A-001 edit recovered exactly on XR after reopening, not during the first 90-second live window. Owner deletion A4→A3 was observed on the already-open XR; B and surviving identities preserved. [result](results/v02-incremental-shared-members-2026-10-26.md) |
| V02.4 | Participant adds/deletes permitted members; owner recovers exact dependencies | Explicit existing-share path observed: XR added A-004 into its shared store with `share(_:to:)`, then linked it; already-open owner recovered exact A4+B2. XR deletion returned both to A3, with B and surviving identities stable. The earlier relationship/save-only participant insertion crashed and remains unresolved; it was not replayed. [positive result](results/v02-participant-explicit-members-2026-10-26.md), [earlier failure](results/v02-incremental-shared-members-2026-10-26.md) |
| V02.5 | Read-only participant: observe permission, application write guard and owner state | Partial: native canUpdateRecord false observed; deliberate guard-bypass saved locally while owner stayed unchanged in a bounded window; [result](results/v02-readonly-replica-2026-10-26.md). Supported application path must honor permission advice; no internal enforcement investigation planned |
| V02.6 | Owner revokes a participant; participant observes state/removal, B unaffected | Observed: owner revocation removed A from the same open XR container; owner A/B retained; [result](results/v02-revocation-2026-10-26.md) |
| V02.7 | Participant leaves a disposable share; owner retains graph, re-invitation/re-acceptance assessed separately | Observed: after A3→A0 and pending metadata, the XR reaccepted the same old URL once and recovered exact A3; owner A/B retained and A participant returned to accepted. A separate owner revocation then removed A from the XR and preserved owner A/B. Voluntary leave is not permanent revocation; [lifecycle](results/v02-reinvite-leave-2026-10-26.md), [fresh replica](results/v02-postleave-fresh-replica-2026-10-26.md), [old-link result](results/v02-old-link-reaccept-2026-10-26.md) |
| V02.8 | Already-open owner/participant containers observe remote changes and permissions without relaunch | Partial positive: revocation and owner deletion reached an already-open XR; explicit participant addition/deletion reached an already-open owner. Owner addition was absent for the first 90 seconds but recovered after reopen. Normal participant insertion crashed before a cloud result. [revocation](results/v02-revocation-2026-10-26.md), [mutations](results/v02-incremental-shared-members-2026-10-26.md), [explicit path](results/v02-participant-explicit-members-2026-10-26.md) |
| V02.9 | Fresh local replica after acceptance recovers the existing share without duplicate invitation or seed data | Observed on XR with new private/shared stores and existing read-only share; [result](results/v02-readonly-replica-2026-10-26.md) |
| V02.10 | Offline durable edits and recovery after connectivity restoration | Not run; controllable connectivity prerequisite |
| V02.11 | Concurrent same-property and disjoint edits; conflicts and eventual graph integrity | Partial: [V09](results/v09-shared-graph-files-2026-10-26.md) coordinated disjoint edits converged on both accounts with graph integrity retained. Same-property conflicts and merge policy remain untested |
| V02.12 | Graph dependencies containing entity/relationship/action equivalents, cycles and optional references | Partial: [V09 result](results/v09-shared-graph-files-2026-10-26.md) observed initial cross-account recovery, participant addition of Entity/Relationship/Action equivalents, edit, owner deletion and independent XR recovery with exact A zone/B control. Cycles and optional missing endpoints remain untested |
| V02.13 | Account unavailability/change and state exposure | Prerequisite: controllable account fixture; no unattended sign-out of personal devices |

## V03 — Swift 6 concurrency, ownership and transactions

The [A1 runtime increment](graphevo-2-store-runtime.md) now adds library-level
local ownership evidence alongside the standalone probes. It is package-internal
and does not yet replace the legacy public Graph facade. The [A2 contract](graphevo-2-async-transactions.md) adds local writes and cancellation evidence; those 46 runtime tests pass on macOS and iOS Simulator.

| ID | Check | Status / evidence |
|---|---|---|
| V03.1 | Direct Core Data consumer builds in Swift 6 with complete concurrency checking | Observed: [A1 runtime](graphevo-2-store-runtime.md) and its 31 tests, including the post-review identity regression, compile in Swift 6 and pass on current macOS/iOS Simulator; its macOS Thread Sanitizer run reported no races. Legacy facade remains mode 5. Earlier [V03 probe](results/v03-local-concurrency-2026-10-26.md) and [follow-up](results/v03-cancellation-process-2026-10-26.md) retain their separate 11-test scope. Physical integration/minimum runtime matrix pending |
| V03.2 | Async context access returns safe values/IDs; no managed-object transfer between executors | Partial: immutable values and 100 concurrent private-context increments observed in initial V03 |
| V03.3 | Two handles to one canonical store share an explicit ownership policy; independent stores remain independent | Partial: [A1](graphevo-2-store-runtime.md) verifies concurrent lease coalescing, independent memory IDs, schema/access conflict rejection, symlink/case/missing-path rules and independent close. Public graph integration, legacy/v2 exclusion and multi-store/cloud sets remain pending |
| V03.4 | Transaction commit, thrown error/rollback and pending-edit ownership | Partial: deliberate rollback and clean next save observed; application-model/scoped contract pending |
| V03.5 | Cancellation before work, during work and around commit; distinguish cancellation from rollback | Partial: [V03 follow-up](results/v03-cancellation-process-2026-10-26.md) shows native work does not inherit caller cancellation; explicit pre-commit signal rolls back, while post-commit cancellation does not. Queued-before-execution window pending |
| V03.6 | Close/reopen/invalidation while tasks are pending; main-thread responsiveness | Partial: [A1](graphevo-2-store-runtime.md) drains admitted native reads, orders reopen after final detach, releases deallocated handles and retains failed-shutdown ownership. Earlier [V03 follow-up](results/v03-cancellation-process-2026-10-26.md) covers a probe save; [A2](graphevo-2-async-transactions.md) additionally drains active and queued admitted writes during a cancelled close. Broader stress/responsiveness pending |
| V03.7 | Native sharing invocation timing versus callback completion; evaluate off-main context ownership | Partial: [T6](results/v01-t6-ipad-diagnosis-2026-10-24.md) proves synchronous work despite callbacks; off-main design not run |
| V03.8 | Concurrent remote import and local edits with explicit merge policy | Partial: [V09](results/v09-shared-graph-files-2026-10-26.md) coordinated disjoint edits at a common future start on two accounts; both independently recovered the combined graph. Remote import/save overlap and same-object conflict policy remain unverified |
| V03.9 | App/extension access to one App Group store across processes | Partial local control: [two macOS processes](results/v03-cancellation-process-2026-10-26.md) exposed duplicate insertion and Core Data merge error 133020 without distributed ownership. Physical iOS App Group/extension test remains unrun |

## V04 — typed application models

The [first A3 library increment](graphevo-2-application-models.md) now supplies
16 model/adapter regressions and a standalone public Swift 6 value consumer.
These pass on the current Mac and iOS Simulator. Evidence includes detached
Entity/Relationship/Action mapping, typed errors, graph-aware references,
partial patches preserving unknown bytes/metadata, main-actor transfer and
candidate SQLite patch/reopen. The null bridge limitation is retained explicitly.
This extends the earlier accessory probes below; typed public database CRUD,
durable identity translation and full value migration remain incomplete.

| ID | Check | Status / evidence |
|---|---|---|
| V04.1 | Minimal protocol-based application model mapping without dynamic-member access | Accessory partial: one fixed-shape ordinary-value protocol mapping observed locally; [accessory local results](results/local-model-files-queries-observation-2026-10-26.md); further work paused |
| V04.2 | Identity, optional/scalar/property round trips and unsupported/decoding errors | Accessory partial: identity/string/optional/integer and decoder errors observed locally; broader type matrix paused |
| V04.3 | Relationships/actions, edits/deletion and scope lifetime | Accessory partial: one parent/inverse deletion and cross-graph application guard observed; relationship/action facades not tested |
| V04.4 | Value snapshots versus live/scoped models; actor transfer and justified Sendable contracts | Accessory partial: immutable Sendable values compiled; live/scoped model comparison not run |

The [A3 typed store continuation](graphevo-2-typed-store.md) additionally exercises
persistent local graph/node IDs, public typed CRUD and scopes, full new-value
envelopes, current-schema local adoption/backups, cyclic references, endpoint
patches, deletion preserving empty actions, ownership exclusion and UI-state
transfer. This extends V04 locally; cloud identity/membership, full legacy source
conversion and the deployment-floor runtime matrix remain separate pending work.

## V05 — attachments

| ID | Check | Status / evidence |
|---|---|---|
| V05.1 | Binary attribute with external storage permitted; filename/content type, byte-exact local reopen/export | Accessory local: byte-exact small/10 MiB round trips with external storage permitted; physical storage choice not inferred; [accessory local results](results/local-model-files-queries-observation-2026-10-26.md) |
| V05.2 | Replacement/deletion/rollback/cancellation and backups including external content | Accessory partial: replacement/deletion/rollback and closed whole-directory copy observed; cancellation/live backup not tested |
| V05.3 | Same-account and cross-account shared-graph transfer; byte/checksum equality and offline reads | Partial: [V09 result](results/v09-shared-graph-files-2026-10-26.md) observed owner-to-XR 512-byte and 10 MiB recovery, participant replacement and deletion recovered by owner, with exact checksum and A share identity. Same-account and offline file reads not run |
| V05.4 | Representative file-size envelope, peak memory and latency | Partial: [V09 result](results/v09-shared-graph-files-2026-10-26.md) records 512-byte/10 MiB sizes and observed replacement/deletion recovery windows; peak memory not measured |
| V05.5 | Actual exposed availability/progress, streaming/eviction/selective-download capabilities | Not run; unsupported capabilities must remain explicit |

## V06 — query engine

| ID | Check | Status / evidence |
|---|---|---|
| V06.1 | Typed predicates, relationship filters, sorting, count and projections | Accessory partial: native relationship predicate/count/sum/projections observed locally; no final typed query API |
| V06.2 | Stable pagination with duplicate sort keys and intervening writes | Accessory partial: keyset ties/insert-before-cursor observed; moving current state, not arbitrary-write snapshot stability |
| V06.3 | Aggregations, cycles and bounded traversals; unsupported expressions | Not run |
| V06.4 | Store execution versus in-memory traversal; latency/object count/memory by dataset size | Not run |
| V06.5 | Visibility under local writes and remote imports, including incomplete structures | Not run |

## V07 — observation and Watch alternatives

| ID | Check | Status / evidence |
|---|---|---|
| V07.1 | One-shot queries, live results and processing streams as separate consumers | Accessory partial: local one-shot fetch and newest-state stream compared; durable processing not tested |
| V07.2 | Membership/value/order/deletion changes, including relationship-dependent membership | Accessory partial: direct value/order/deletion updates observed; related-property membership invalidation gap retained, not satisfied; [accessory local results](results/local-model-files-queries-observation-2026-10-26.md) |
| V07.3 | Slow consumers, buffering/coalescing, cancellation and resubscription | Accessory partial: bounded newest-state coalescing and cancellation/resubscription observed locally; not durable delivery |
| V07.4 | Duplicate events, history tokens, relaunch and any proposed replay behavior | Not run |
| V07.5 | Durable processing versus current-state observation; local and real remote scenarios | Not run; no exactly-once or cloud-completion inference from callbacks |

## V08 — recovery and transition feasibility

| ID | Check | Status / evidence |
|---|---|---|
| V08.1 | Open/configuration failures and unavailable services expose actionable states | Accessory partial: native model mismatch/bad-parent errors observed; account/cloud recovery matrix not tested |
| V08.2 | Interruption, explicit scoped reset and backup restoration | Accessory partial: closed copies/reopen observed; direct read-only metadata changes SHM (known failed guarantee), separate closed-copy inspection preserves originals; interruption/reset pending |
| V08.3 | Mandatory v1 local data migration; optional source API adapter assessed separately | Not run; inventory/fixtures start with the current schema candidate, migration mapping evolves through alpha and final validation occurs in beta |
| V08.4 | Required cloud data transition, downgrade and incompatible-store behavior | Not run; coordinated cutover selected with v1 writes stopped before conversion. Pending source writes, late old devices, duplicate prevention and recovery remain to design/test |

During specification and implementation, reconcile remaining rows explicitly:
retain evidence, explain a verified unsupported capability, or record a
deliberate deferral and its effect. Apply the delivery plan's beta gate before
consolidating the schema/API. A green demo suite does not close this register.
