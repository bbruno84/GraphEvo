# T08 — revocation, leave and empty rejoin

Date: 2026-10-31. Development test container, new zones and stores, no reset.
This is package-only custom CKSyncEngine evidence, separate from historical
NSPersistentCloudKitContainer experiments. S03 and cloud record formats are unchanged.

## Source and protocol

The mutation matrix uses committed source `9a28da0f81361977fbfea34ec9ff0896299be873`.
Owner: iPad on the maintainer account. Participant: iPhone XR, iOS 18.7.10, on a
different iCloud account. Bruno's iPhone is not required. The disposable signed
host exports committed library code; private handoffs, launch receipts, native
documents and raw reports remain in protected external evidence.

Every mutation is reserved before effects. No consumed mutation was replayed.
An initial host launch raced an unfinished XR installation and failed before
protocol acknowledgement; that fixture was abandoned and a new run UUID used.
The active run has 14 passed reports and one deliberately interrupted stage:

| Stage | Device | Result |
|---|---|---|
| identity | XR | Container-scoped recipient identity; no graph created |
| seed | iPad | A read-write share with file, C read-only share, private B control |
| accept | XR | Independent A/C inventories, contents/file and permissions verified |
| pending | XR | Two A consumer changes retained locally; no upload |
| downgrade | iPad | A participant permission changed to read-only |
| read-only | XR | Two pending changes retained, writes refused, C import progresses |
| revoke | iPad | A participant removed without changing owner graph data |
| revoke-start | XR | Durable purge intent and blocked application admission observed; process killed before destruction |
| recover-purge | XR | Restart registers current URL and removes A without application opening; C survives |
| reinvite | iPad | Explicit fresh invitation to A |
| rejoin | XR | Empty new store recovers original A/file; discarded edits absent; C survives shared-engine replacement |
| leave | XR | Local A removed; shared CKShare leave completed; C survives |
| stop | iPad | C sharing stopped without deleting private graph data |
| stop-all | XR | Foreground control worker removes paused C without manual refresh/fetch/apply |
| audit | iPad | Exact private A/B/C inventories, original values/file and empty outgoing work |

The interrupted `revoke-start` has a ready checkpoint and intentional process
termination evidence, **not** a completed-stage report. Writers remain alive
through independent participant observation. Owner audit checks actual CloudKit
zone changes decoded as GraphEvoNode plus full scoped local inventories; A has
exactly entity/file, B and C one entity each. Discarded participant edits never
appear in the owner's independent inventory.

## Final correction checks

Library source `cc93c78` adds session-stop drainage of admitted purges, preserves
control backoff across hints/activity (including a hint arriving during failure),
and avoids substituting a participant account for a hidden owner identity.
Its independent read-only owner `final-audit` passes on the same fixture. These
checks do not attribute the original mutation matrix to the corrected source.

The initial XR `removed-state` check fails because its laboratory assertion
incorrectly requires the entire shared inbox to be empty. The copied session
document shows both memberships removed, no pending commands/receipts, zero
events for their zones and 30 retained events for unrelated earlier experiments.
Those events must not be erased. The failed report is retained; the corrected
`removed-scope-state` uses a new stage name and inspects the entire bounded inbox
only for removed zones. Laboratory-only correction `4c24f5c` changes no library
source relative to `cc93c78`.
The corrected XR `removed-scope-state` passes on the same fixture: both durable
removals and absent SQLite/WAL/SHM resources survive restart, no former zone has
pending inbox work, and unrelated scope events remain intact.

## Review corrections

The review of `f4eafe9` reproduces one P1 and two P2 defects with three focused
tests. The corrective implementation preserves session format 5 and S03:

- Post-destruction cleanup fingerprints retained artifacts and retires each
  removed path. Tests replace the SQLite file both before artifact cleanup and
  after cleanup failure; retries refuse the replacement unchanged, then resume
  after explicit repair without releasing native claims early.
- Interrupted acceptance reconstructs only a missing unaccepted marker on the
  same untouched native store/generation. Application reads remain fenced until
  explicit acceptance resumes. Nonempty, previously active and conflicting
  generation states remain refused.
- Inbox saturation still blocks data transport but permits verified sharing
  control and bounded removal. Tests cover event/byte saturation, offline leave,
  retained unrelated inbox events, restart, paused-graph foreground detection,
  activity changes and a later sticky account failure. Retired-zone bodies are
  discarded before payload validation/capacity accounting.

The first complete correction run also exposes native metadata reads racing
destruction during URL registration (Core Data 134070). A simulator run narrows
the same race to filesystem URL resolution (missing-file error). Registration
now joins the retained purge before probing disappearing files, and checks the
membership generation again after waiting. The post-native-destruction gate
provides a committed regression. These intermediate failures are retained in
external evidence rather than reported as passing runs.

The corrective tests are deterministic local/macOS and iOS Simulator evidence.
The earlier physical matrix and later hardware read-only checks retain their
original pins; they are not reattributed to this correction.
Corrected-source validation passes 757 macOS functions (331 legacy, 332 store,
71 runtime, 23 model), 402 iOS 18.5 Simulator store/runtime tests, the Release
GraphEvoStore build, Swift 6 ModelConsumer and manifest/diff checks. The three
original reproducers are committed as strengthened regressions alongside six
additional boundary/race functions. Remote CI remains pending review completion
and maintainer authorization.
The [corrective review of `70909cf`](https://github.com/bbruno84/GraphEvo/pull/120#pullrequestreview-5725012469)
closes the three findings with no additional blocker in the reviewed paths.
Subsequent status edits are documentation-only; the tested library/test source
remains exactly that commit. CI and merge still require maintainer authorization.

## Local validation and limits

Deterministic coverage includes aliases and query lifecycle, owned attachment
cleanup while consumer exports survive, admitted-work drainage, offline leave
and restart, quarantine/retry before and after native destruction, journal-write
interruption after destruction, moved/current URL registration, foreign-store
refusal, read-only incoming work with pending uploads, new generations, late
driver callbacks, other-graph work on engine replacement and retry timing.

Pre-review macOS validation passes 748 functions (331 legacy, 323 store, 71 runtime,
23 model). iOS 18.5 Simulator validation passes 391 store/runtime tests, followed
by a passing 14-test lifecycle rerun after the final URL/observer regressions.
The counts overlap and must not be added as unique tests. Manifest/diff checks,
the Swift 6 ModelConsumer and Release GraphEvoStore build pass.
The Debug purge barrier is absent in Release. Remote CI and integration
remain after review, under the agreed checkpoint workflow; experiments and
physical probes do not run in CI.

This bounded fixture does not certify background/APNs delivery, immediate
offline revocation, cross-process destruction, secure erasure, restored backups,
every graph topology, production-scale traces, broad account/cache policy or
distributed owner-command ordering. Offline leave recovery is deterministic
test evidence, not a physical airplane-mode result. See the
[contract](../graphevo-2-sharing-lifecycle.md) and
[protocol](../../../Experiments/SharingLifecycleProbe/README.md).
