# MF03 bounded shared ledger — 2026-11-01

## Source and scope

Candidate runtime: `9c6ee82e19bfcb8973db50bd1b899f809984e600`, directly from
`d17676d` (#121), on `codex/v2-shared-ledger`. This is the original physical validation pin; the corrective
review section below records the later runtime changes. This implements the
[MF03 contract](../graphevo-2-shared-ledger.md), not a migration executor,
distributed lock, public activation or beta acceptance.

S03 and application-node/asset formats are unchanged. Session format 6 refuses
older alpha documents without modification. All tests use disposable fixtures;
the physical run used a new graph/zone in the existing Development container,
without reset or mutation replay.

## Local checks

macOS 27.0.1, Xcode 27.2 (`27B52`), Apple Swift 6.4.2:

- Full `swift test`: **808 functions** passed (331 legacy, 378 store, 76 runtime,
  23 model). Expected corruption/read-only diagnostics belong to negative tests.
- iOS 18.5 Simulator: **476 selected functions / 561 parameterized invocations**
  passed across store/runtime/model targets; zero failures, skips or runtime
  warnings in the result summary.
- Release `GraphEvoStore`, Swift 6 `ModelConsumer`, package manifest and
  `git diff --check` passed.

The 22 new deterministic functions cover 100 completed operations with full
current/previous retention and a 32-event ring; 2000 consumer retries without
history growth; canonical bounded JSON, malformed input and stale/no-op commands;
restart recovery; independent concurrent writers and explicit conflict acceptance;
edit 3→4 during successful or ambiguous send; one targeted tag retry and refusal
of further collisions; read-only incoming refresh; control hints while application
inbox limits block data; account-change stream termination; failed durable writes;
stop drainage and ambiguous success after restart; terminal participation and
late callback refusal; native codec preservation of unrelated CK fields and future
top-level JSON sections; graph-data pause, graph-scoped backup evidence and
foreground inactivity/backoff behavior. Broader T08/T06/backup regressions also
pass in the full suite. Clock time does not order competing control updates.

The stop test initially expected `stopped` during drainage; the existing runtime
correctly reports `stopping`. The assertion was corrected and rerun. The first
external probe build needed a Sendable closure capture fix in the disposable
host only; no physical stage had started at that point.

## Physical protocol

Owner: iPad di Bruno, private database. Participant: iPhone XR / iPhone di Maria
Elena, a different iCloud account, shared database and **read-only** permission.
The configured test container was `iCloud.com.valerioburiani.GraphCKDemo`.
Fixture run: `65150C88-21F4-4C22-BF38-8A4DC7B451C2`. Writers remained alive until
independent peer observation. No background/APNs delivery claim is made.

Probe source SHA-256 for the first five stages:
`f7454367398f58f011bf89f815d7b34be3e063d414f276e80853500a51ae2b17`.
The audit-only extension added native inventory assertions without changing the
shipping library; its source SHA-256 was
`4dd755e42f8eda0bfebfb85258f289220ba98b3a2032104beeee457035ea5705`.

The disposable signed host pinned the runtime above and injected its bridge only
outside the checkout. Xcode's connector requested approval; CLI build/install/
launch/file transfer completed the already-authorized protocol. No laboratory,
store, session, protected identity/invitation, raw log or device result is committed.

| Stage | Device | Observed result |
|---|---|---|
| identity | XR | Recipient identity prepared without creating a graph. |
| seed | iPad | One application record sent, read-only invitation created, then graph data paused. First operation finished after 100 retries; second operation progressed through 40 phases. Full previous information, separate current/global JSON and exactly 32 events confirmed in the published ledger. |
| accept | XR | Accepted into a fresh empty replica, paused application sync and fetched the exact ledger control record. Content matched the owner; local control mutation was refused. Application replica and upload queue remained empty. |
| update | iPad | Process restart exposed recovery-required. Explicit resume and a consumer metadata mutation published through automatic foreground control; no subsequent manual send/fetch/reconcile drove the update. Application data remained paused and unchanged. |
| watch | XR | After restart/automatic activation, observed the updated metadata without manual send/fetch/apply/reconcile. Data remained paused, the application replica empty and upload queue empty. |
| audit | iPad | Restart retained the current/previous state and updated JSON. Native complete zone inventory contained exactly one `GraphEvoNode`, one `GraphEvoControl` and one CKShare, with no pagination. Original application content and empty queue retained. |

Shared ledger payload was **7073 bytes** at seed/accept and **7066 bytes** after
resume/update, including the fixed event ring. This small fixture is a bounded
size check, not a performance or many-graph sizing claim. Every reserved stage
passed once. Native inventory was checked through CloudKit API, not SQLite
inspection. Final peer observation preceded restarting the owner for audit.

## Remaining gates

Physical evidence closes only this bounded control-record/permission/pause/
restart path. Injected tests provide concurrency, ambiguous-response, account,
persistence-failure and purge coverage; this run does not certify physical
revocation while control publication is in flight. It does not separately prove
a 60-second-only recovery, APNs, background operation, many-graph fairness or
production-scale rewrite/storage cost. Preserve 512-KiB per-enabled-graph reserved
headroom sizing as a post-alpha check.

An unmirrored local journal, working-copy migration executor, transactional
application commit-marker reconciliation, independent-user restore activation
and mandatory v1 conversion remain open. Control publication is distinct from
application-data completion. At the original candidate report, remote CI and merge had not yet been requested;
the corrective review and eventual checkpoint are recorded below.

## Corrective review before CI

Review of `77288fd` identified two P2 findings, corrected in
`7dd8ecf9b605d49cdbfaffb8f1d4c5f6f2a0d9c7`:

1. A hint arriving during a successful control turn could be deferred until the
   60-second timer. The new virtual-clock regression failed against the reviewed
   source. Success now retains that hint for the next turn immediately; failed
   turns still consume it into their existing backoff. A manager-level 3→4 send
   test confirms the newest revision reaches the fake server without advancing
   virtual time or calling manual reconciliation.
2. Error annotation looked up the latest ledger by GraphID after an await. A
   late result could therefore annotate a replacement participation. Failure
   persistence now requires the exact admitted ledger generation, captured inside
   the session. The control worker also fences results and resets old retry/block
   state when that generation changes. Removed graph state is pruned. A replacement
   read-only participation does not need a local write to escape an old block.

A generation lookup adds an actor suspension; inactivity is rechecked after it
before admitting work. Regression coverage includes inactivity at that boundary,
replacement during a held failure, replacement after a permanent failure and
refusal to annotate a replacement ledger. The first generation-worker test used
an unrelated ID that the fixture intentionally treated as successful; the fixture
was corrected to its designated failing ID. The final focused re-review suite
passed **52 functions** across ledger, control worker, sharing lifecycle and
automatic integration. No remaining finding was identified in the corrected
source. The physical six-stage evidence above retains its original source pin;
these corrective scheduling/generation cases are deterministic local coverage.

Final corrected-source verification at `7dd8ecf`: full macOS suite **813 functions**
(331 legacy, 383 store, 76 runtime, 23 model) and selected iOS 18.5 Simulator
**481 functions / 566 invocations**, all passed. The source remains unchanged
through the documentation-only review record. At that point remote CI was the next checkpoint;
no repeated physical claim is made for the corrected source.


## Remote checkpoint and integration

After corrective review, full [CI run #303](https://github.com/bbruno84/GraphEvo/actions/runs/41295379797)
passed the macOS and iOS jobs on reviewed head
`a2f029a056929e7ba6e57ac80b1f80cb2ebed558`. The checkpoint label was added only
after review/corrections and local checks. It was removed after success before the
documentation-only integration/evidence update, avoiding another unchanged full
run. The final PR head differs only in documentation; shipping source remains
`7dd8ecf`. The PR records the authorized merge into `codex/graphevo-2`.
Laboratories and physical probes were not run by CI. No release or beta gate
closure is implied.
