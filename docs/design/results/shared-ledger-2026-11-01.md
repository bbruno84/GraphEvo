# MF03 bounded shared ledger — 2026-11-01

## Source and scope

Candidate runtime: `9c6ee82e19bfcb8973db50bd1b899f809984e600`, directly from
`d17676d` (#121), on `codex/v2-shared-ledger`. Documentation-only follow-ups do
not alter that runtime pin. This implements the
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
application-data completion. Review/corrections precede CI; remote CI and merge
have not been requested for this candidate.
