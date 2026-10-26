# GraphEvo 2 — execution checklist

Status: active verification register, started 2026-10-26. The maintainer
authorized autonomous laboratory preparation and execution using connected test
devices. This refines the [roadmap](graphevo-2-verification-roadmap.md); it is not
the GraphEvo 2 specification or a promise that every candidate API is feasible.

## How to read this register

**Observed** means retained evidence under stated conditions, not universal
acceptance. **Partial** separates completed subchecks from remaining coverage.
**Not run** includes missing instrumentation. **Prerequisite** identifies an
external condition; other independent checks continue. **Rejected** records an
unsupported tested native configuration. A local/injected test never completes
a real cloud row. Every completed row must link to its evidence and limits.

## Current scope: supported graph sharing

After the maintainer's 2026-10-26 clarification, active execution is focused on
whether graph ownership and sharing requirements can be implemented within the
supported public NSPersistentCloudKitContainer contract: incremental members,
chosen-graph sharing, permission-aware application writes, revocation, leaving
and coherent recovery. Observe application data, public metadata, errors and
lifecycle outcomes; do not reverse-engineer framework internals.

V03–V08 remain a future backlog. Local exploratory probes already performed
are accessory evidence, not prerequisites or acceptance gates for the sharing
choice. Do not expand them while the sharing feasibility question is pending.
When native permission advice is available, the application is expected to
honor it before mutation; a deliberately bypassed guard is a diagnostic control,
not the intended GraphEvo write path.

Close the missing V01 incremental-membership check first, then the focused V02
permission/lifecycle cases. Keep same-device and independent-device conclusions
separate. Unexpected application-visible results may get a bounded public-API
reproduction when needed to decide whether the objective is achievable.

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
| V02.3 | Owner adds/edits/deletes graph members after sharing; participant recovers exact graph and identities | Not run |
| V02.4 | Participant adds/deletes permitted members; owner recovers exact dependencies | Not run |
| V02.5 | Read-only participant: observe permission, application write guard and owner state | Partial: native canUpdateRecord false observed; deliberate guard-bypass saved locally while owner stayed unchanged in a bounded window; [result](results/v02-readonly-replica-2026-10-26.md). Supported application path must honor permission advice; no internal enforcement investigation planned |
| V02.6 | Owner revokes a participant; participant observes state/removal, B unaffected | Observed: owner revocation removed A from the same open XR container; owner A/B retained; [result](results/v02-revocation-2026-10-26.md) |
| V02.7 | Participant leaves a disposable share; owner retains graph, re-invitation/re-acceptance assessed separately | Partial: pending reinvitation/re-acceptance and XR shared-store purge A3→A0 observed; owner A/B retained, but its A share list still included the participant after 30s and another 120s; [result](results/v02-reinvite-leave-2026-10-26.md) |
| V02.8 | Already-open owner/participant containers observe remote changes and permissions without relaunch | Partial: revocation removed A from an already-open XR; other live changes/background delivery remain unverified; [result](results/v02-revocation-2026-10-26.md) |
| V02.9 | Fresh local replica after acceptance recovers the existing share without duplicate invitation or seed data | Observed on XR with new private/shared stores and existing read-only share; [result](results/v02-readonly-replica-2026-10-26.md) |
| V02.10 | Offline durable edits and recovery after connectivity restoration | Not run; controllable connectivity prerequisite |
| V02.11 | Concurrent same-property and disjoint edits; conflicts and eventual graph integrity | Not run; retain both local durable states and reconciliation outcome |
| V02.12 | Graph dependencies containing entity/relationship/action equivalents, cycles and optional references | Not run; current root/child fixture is narrower |
| V02.13 | Account unavailability/change and state exposure | Prerequisite: controllable account fixture; no unattended sign-out of personal devices |

## V03 — Swift 6 concurrency, ownership and transactions

| ID | Check | Status / evidence |
|---|---|---|
| V03.1 | Direct Core Data consumer builds in Swift 6 with complete concurrency checking | Observed locally on current macOS; [initial V03 probe](results/v03-local-concurrency-2026-10-26.md); iOS not tested |
| V03.2 | Async context access returns safe values/IDs; no managed-object transfer between executors | Partial: immutable values and 100 concurrent private-context increments observed in initial V03 |
| V03.3 | Two handles to one canonical store share an explicit ownership policy; independent stores remain independent | Partial: explicit registry coalescing and independent URLs observed; v1/native ownership, alias edge cases and release policy not certified |
| V03.4 | Transaction commit, thrown error/rollback and pending-edit ownership | Partial: deliberate rollback and clean next save observed; application-model/scoped contract pending |
| V03.5 | Cancellation before work, during work and around commit; distinguish cancellation from rollback | Partial: explicit pre-enqueue check, native-only pre-cancelled save and post-commit cancellation observed; queued/native-work windows pending |
| V03.6 | Close/reopen/invalidation while tasks are pending; main-thread responsiveness | Partial: durable close/reopen and closed-owner rejection observed; pending-work stress and responsiveness pending |
| V03.7 | Native sharing invocation timing versus callback completion; evaluate off-main context ownership | Partial: [T6](results/v01-t6-ipad-diagnosis-2026-10-24.md) proves synchronous work despite callbacks; off-main design not run |
| V03.8 | Concurrent remote import and local edits with explicit merge policy | Not run |
| V03.9 | App/extension access to one App Group store across processes | Not run; requires an extension consumer, not two in-process handles |

## V04 — typed application models

| ID | Check | Status / evidence |
|---|---|---|
| V04.1 | Minimal protocol-based application model mapping without dynamic-member access | Accessory partial: one fixed-shape ordinary-value protocol mapping observed locally; [accessory local results](results/local-model-files-queries-observation-2026-10-26.md); further work paused |
| V04.2 | Identity, optional/scalar/property round trips and unsupported/decoding errors | Accessory partial: identity/string/optional/integer and decoder errors observed locally; broader type matrix paused |
| V04.3 | Relationships/actions, edits/deletion and scope lifetime | Accessory partial: one parent/inverse deletion and cross-graph application guard observed; relationship/action facades not tested |
| V04.4 | Value snapshots versus live/scoped models; actor transfer and justified Sendable contracts | Accessory partial: immutable Sendable values compiled; live/scoped model comparison not run |

## V05 — attachments

| ID | Check | Status / evidence |
|---|---|---|
| V05.1 | Binary attribute with external storage permitted; filename/content type, byte-exact local reopen/export | Accessory local: byte-exact small/10 MiB round trips with external storage permitted; physical storage choice not inferred; [accessory local results](results/local-model-files-queries-observation-2026-10-26.md) |
| V05.2 | Replacement/deletion/rollback/cancellation and backups including external content | Accessory partial: replacement/deletion/rollback and closed whole-directory copy observed; cancellation/live backup not tested |
| V05.3 | Same-account and cross-account shared-graph transfer; byte/checksum equality and offline reads | Not run |
| V05.4 | Representative file-size envelope, peak memory and latency | Not run; report measurements, not invented limits |
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
| V08.3 | Candidate v1 local data transition and optional API adapter | Not run; target-model decision prerequisite |
| V08.4 | Cloud continuity, downgrade and incompatible-store behavior for a selected transition | Not run; v1 compatibility must not constrain v2 design |

Before the specification, reconcile the remaining rows explicitly: either retain
evidence, explain a verified unsupported capability, or record a deliberate
deferral and its effect. A green demo suite does not close this register.
