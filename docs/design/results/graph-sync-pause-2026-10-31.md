# T05 — real per-graph synchronization pause, 2026-10-31

Result: **all seven stage reports passed** on same-account iPad/iPhone, using one
manual private CKSyncEngine per process and two independent graph zones.

## Provenance and execution

- Focused branch `codex/v2-graph-sync-pause`, directly from #116 (`3b495ba`).
- Production runtime `3a3e47b450a68166bb135648dee7d76802f366cc`, with the
  [external bridge](../../../Experiments/GraphPauseProbe/README.md) in a signed
  disposable demo. A bridge compile error was corrected before any stage ran;
  production code did not change during the device protocol.
- Signed entitlements checked for `iCloud.com.valerioburiani.GraphCKDemo`,
  Development. New GE2-T05 run, separate A/B zones and new owner/peer/fresh stores.
  No reset, purge, copied store, source-body replay or consumed-stage retry.
- Owner: iPad10/iPadOS27.0; peer/fresh: iPhone18 Pro/iOS27.2. Accounts compared
  privately and matched. Durable routing remains graphID + zone, without paths.
- Owner seed passed first. Device lock-state discovery then timed out before
  launching the peer baseline. The owner remained live. After the user unlocked
  the phone, a continuation ran only the six remaining stages; seed was not
  replayed. This was a launcher interruption, not a failed protocol stage.
- Writers remained alive through independent observation. Only acknowledged
  process IDs were terminated for planned restarts. Raw reports, tickets, stores
  and session documents remain external and are not committed.

## Observed results

| Stage | Result |
|---|---|
| seed owner | A1/B1 published; complete local/server inventories, dates and native tags agree. |
| read-baseline peer | Independent empty stores recover A1/B1 without upload feedback. |
| pause-peer, spanning owner update | A reaches paused twice idempotently; B remains active. Local A3 saves and remains pending. A send/apply refuse. A record-change/deletion envelopes are absent from the scoped fetch inbox while B reaches2. After resume A3 publishes and final inventories/queues agree. A pauses again before exit. |
| update-owner | After observing the peer ready marker, owner publishes A2/B2 while peer A is paused. |
| observe-owner | Independent convergence to A3/B2, with empty upload queues. |
| reopen-peer | Without fetching, persisted A3/B2 and empty queues survive; process-local synchronization state starts active. |
| read-final fresh | Genuinely empty stores recover exact A3/B2 without feedback. |

The pause-peer ready/continue files are external laboratory barriers, not app
features or replay instructions. No direct CKDatabase query of paused A polluted
the scoped-fetch interval. Final verification compares all typed local IDs and
full GraphRecords, plus complete server-zone modifications from nil tokens with
limit100 and moreComing refused. Real nonempty change tags and injected edit dates
are checked. There is no inference from SQLite internals or launch success alone.

## Deterministic validation and limits

Full local macOS validation passes **690 functions**:331 legacy,265 store,71
runtime,23 model. Selected iOS18.5 suites pass **79 functions/94 expanded cases**.
ModelConsumer, package manifest and diff checks pass. Ten pause test functions
(including a two-case commit/rollback test) cover admitted sends/fetches/imports,
newer pending edits, independent graphs, cancellation, idempotence, errors,
alias/close/stop lifetimes, observation, all-paused fetch suppression and shared
attachment refresh coverage. Native in-flight timing is controlled in those
tests rather than inferred from physical network latency.

This closes bounded manual private-zone pause behavior. It does not certify
automatic/background scheduling, shared-account permissions, EDGE latency,
long backlogs, crash/backup behavior or migration exclusivity. Pause remains
process-local and does not exclude local or external writers. S03 and wire/state
formats remain unchanged. The final remote CI disposition belongs to the PR.

## Checkpoint correction

Initial checkpoint `41215698406` on `d1a1ed4` passed macOS but failed one iOS
assertion in the pre-existing shared-attachment cancellation test: the total fetch
count was not one. The test launched its second caller without proving it had
joined the held refresh before releasing the first operation. Under full-suite
scheduling, Task construction alone does not establish that overlap. The corrected
test waits for two registered refresh waiters before cancellation and barrier
release, preserving the exact one-fetch assertion. An internal read-only waiter
diagnostic supports this barrier; production synchronization behavior is unchanged.
Targeted local asset/pause suites pass 19 functions. The final PR records the
subsequent full iOS verification and corrected remote checkpoint; the initial
failure is retained and is not counted as a successful checkpoint.

Corrected full local iOS18.5 validation passes: 689 discovered functions,
688 passed and one existing platform skip; 743 expanded executions passed.
The corrected asset/pause subset also passes 19 local macOS functions.

Corrected source head `438be968a84efa740010dd329e54b5ade5881caa` passes full
macOS/iOS CI `41216918331`. A subsequent workflow/documentation-only change
removes the three historical experimental smoke steps at the maintainer's
request. Its YAML/remaining-step checks pass locally; the unchanged library
suite is not rerun merely for that removal.

## PR117 review correction

Review reproduced stale pause state when a concurrent open was waiting for the
last native detach. That waiter could remove the closed owner before the closing
caller resumed, leaving the old pause control attached to the reopened graph.
Both successful-close paths now use one generation-checked retirement/reset
helper. Failed detachment still retains ownership; a late old-generation cleanup
cannot reset a new owner. The existing concurrent-close/reopen regression now
pauses first and requires active on reopen; it failed before the correction.
Selected local iOS18.5 validation passes 91 functions/106 expanded executions.
The prior green CI run covers the earlier source, not this review correction.
No new CI or merge is requested during this review-only task.

Post-review full local macOS validation passes 690 functions (331 legacy,
265 store,71 runtime,23 model). The corrected concurrent-close/reopen regression
also passes 25 repeated executions. Manifest and diff checks pass.

## Post-review pre-merge checkpoint

At the maintainer's explicit request, reviewed source head
`3f5fd31b44a706125109231ec189a11a8e9e1dab` passes full macOS/iOS CI
`41218175454`. Model/process consumer checks pass; the three experimental smoke
steps are absent. PR117 integrates after this checkpoint and the authorized merge.
Final integration-status edits are documentation-only; code and workflow remain
identical to the reviewed, CI-tested head. No release tag or beta acceptance.
