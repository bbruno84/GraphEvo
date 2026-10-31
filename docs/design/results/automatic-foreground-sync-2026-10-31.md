# T06 — real automatic foreground synchronization, 2026-10-31

Result: **nine protocol reports passed**, followed by **one additional independent
empty replica on the lifecycle-hardened runtime**. Same-account iPad/iPhone,
automatic foreground orchestration, real CloudKit transport and private A/B zones.
No manual send/fetch/apply call was used to force a successful stage.

## Provenance

- Branch codex/v2-automatic-cloud-sync directly from reviewed/merged #117 (f459ae2).
- First nine stages pin production runtime
  `52fed77f0bdbe76cd18ae4ee1a0de9316538afb3`, exported into a disposable signed demo
  with the [external bridge](../../../Experiments/AutomaticSyncProbe/README.md).
- Signed entitlements checked: iCloud.com.valerioburiani.GraphCKDemo, Development.
  Owner iPad10/iPadOS27.0, peer/fresh iPhone18 Pro/iOS27.2. Account identities
  compared privately and matched; bindings contain only graphID and zone.
- New GE2-T06 zones and owner/peer/fresh stores. No reset, purge, copied store,
  old-file conversion, consumed-stage replay or failed physical stage.
- Writers remained live through independent observation. Planned restarts used
  only acknowledged process IDs. Launch/scene receipts, reports, builds, stores
  and session documents remain externally retained, not committed.
- The host aggregates actual scene activity. Native automaticallySync stays false;
  notification forwarding is disabled for the periodic and paused-peer stages.

## Protocol results

| Stage | Observed result |
|---|---|
| seed owner | Consumer A1/B1/date10 publishes automatically; exact full local/server inventories and empty queues. |
| read-baseline peer | Genuinely empty stores automatically recover A1/B1, without upload feedback. |
| periodic-peer, spanning owner update | After initial catch-up, peer announces ready and stays active. A2/B2 arrives through the actual 60-second reconciliation timer, with notification forwarding disabled. The fixture refuses completion earlier than 35s after ready. |
| update-owner | Only after ready, independent owner publishes consumer A2/B2/date200 automatically. |
| pause-peer, spanning control update | A paused/B active at 2/2. After owner update, consumer saves A4/date500 while paused; B reaches3 automatically. A retains one pending change and no A record-change/deletion envelope appears in its inbox. Resume automatically resolves/publishes A4; final A4/B3 agree. A pauses again before exit. |
| update-control-owner | Owner automatically publishes A3/B3/date400 after the peer announces A paused. |
| observe-owner | Independent automatic convergence to A4/B3, exact inventories and empty queues. |
| reopen-peer | Process recreation starts user pause active and automatically retains/recovers A4/B3 with empty queues. |
| read-final fresh | Independent empty stores automatically recover complete A4/B3 without feedback. |

Ready/continue files are external coordination barriers, not scheduler triggers.
Verification compares all scoped logical IDs, complete GraphRecords, exact edit
and creation dates, and full server-zone modifications from nil tokens, limit100
with moreComing refused and real nonempty server change tags. Paused A was not
queried through an independent CKDatabase during its scoped-fetch assertion.
There is no inference from SQL internals or launch success alone.

## Lifecycle hardening and additional recovery

Subsequent local checks protect owner removal across an awaited session-failure
lookup, terminate old status streams on generation replacement, order overlapping
activity requests and exclude reactivation while session stop drains. Failed
opening/stop cleanup cannot poison a later session; admitted receipts survive stop
and settle after restart without consumer-body replay or duplicate upload.

Runtime `0c25ea649322866e8977bc50bd47c303db9c9723` then performs an additional
read-final/current stage, using a new guarded current replica over the same run's
zones. The acknowledged previous peer process was terminated before installing
the newly pinned host. That stage passes exact empty recovery to A4/B3 and empty
queues, while the independent owner remains live. No original mutation was replayed.
The original nine reports retain their earlier pin; they are not relabeled.

A final retry-only adjustment caps client jitter at 300s while honoring larger
server retryAfter values. It is covered with virtual jitter 1.0/1.2 and a 600s server
hint. Physical evidence remains explicitly pinned to the runtimes above; it does
not claim a physical rate-limiting/backoff test.

## Validation and limits

Full local validation passes **711 functions**:331 legacy,286 store,71 runtime,
23 model. Selected iOS18.5 passes **112 functions/128 expanded executions**, covering
automatic scheduling, native store integration, pause, assets, sessions, transport,
policies and coordinator lifecycle. ModelConsumer, manifest, script parsing and
diff checks pass. Final source head is `3e2d8ce0e35feefb487545753e698b8441b8289a`; following delivery edits are
documentation/protocol-only. [PR118](https://github.com/bbruno84/GraphEvo/pull/118)
awaits review before any remote checkpoint or merge.

Deterministic tests cover debounce/max latency,60s recovery, filtering before
coalescing, round-robin/scopes/backlogs, retry progression and server advice,
partial/permanent errors, pause/inactivity, generation/observer lifetime, weak
idle ownership, stop/reactivation, failed startup and restart receipt recovery.
Actual S03 integration tests use real PH and demonstrate post-activation consumer
commits and import without feedback. They remain distinct from real CloudKit.

This closes bounded active-app private-data orchestration only. It does not
certify APNs delivery, background/silent launch, shared participant permissions,
physical offline/rate-limit behavior, power loss, backup/migration exclusion or
supported performance/resource envelopes. Polling and full-document costs remain
post-alpha work. No schema/wire/document change, public opener or release tag.
Remote CI is intentionally deferred until review and the authorized pre-merge
checkpoint, following review → CI → merge.

## PR118 review corrections

Review of `7c5d773392611f4fe7c0aa74dbf512bd5084911d` finds two P2 issues:

- A pending fetch could immediately reschedule a worker while its required initial
  turn was still debounced. The virtual-clock regression failed before correction.
  Fetch wake calculation now waits for that initial deadline; the test verifies
  sleep, no early turn and subsequent progress.
- Send completion released scope admission before a separate retryAfter lookup.
  Another operation could replace that advice. Error and retry advice now return
  in one immutable, nonpersisted outcome captured before releasing the scope.
  Success/failure tests replace the scope's advice with a later fetch and verify
  that the completed send retains600s; manual send still throws its original error.

Post-review local validation passes **713 macOS functions** (331 legacy,288 store,
71 runtime,23 model) and **114 iOS18.5 functions/131 expanded executions**. The
physical reports above keep their original pins; no device test is relabeled as
evidence for these corrections. Review-only work requests neither remote CI nor
merge. The required checkpoint remains after review, before an authorized merge.

Both corrected review regressions pass10 repeated local runs. ModelConsumer,
manifest and diff checks pass. Focused re-review finds no remaining blocking
findings; PR118 stays open without the checkpoint label or merge.
