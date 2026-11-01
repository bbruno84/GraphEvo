# MF01 review — 2026-11-01

Reviewed source: `1e9a16d4db3534ac4606e57ae0c26df025e7720c` in #120.
Scope: local write/maintenance reservations, backup creation/verification,
retention/restoration, cloud-pause composition and the new participant access
fences. T08's earlier corrective review remains separate historical evidence.

## Findings

### P2 — reject nested restore destinations before creating their parent

`GraphBackupManager.restore(at:to:)`, lines 132–133, calls the mutating
`directory(destination.deletingLastPathComponent())` before checking whether that
parent is inside the source backup. A destination such as
`<backup>/Nested/Restored` is refused, but leaves `Nested` inside the previously
valid immutable source. Subsequent verification rejects this extra top-level
entry as `invalidBackup`.

Reproduced on a fresh graph and verified backup: request the nested restore,
expect its rejection, then assert that `Nested` does not exist and verify the
original again. Both source-preservation assertions fail. Validate canonical
source/destination containment without creating directories first, including
parent aliases, then create only an admitted destination parent. Keep a
regression asserting unchanged source inventory and successful verification.

### P2 — emit recovery invalidation when cancelling maintenance

`StoreResources.cancelReservation(_:)`, lines 305–307, removes the reservation
directly. For `.all`, this bypasses the `.storeChange` notification emitted by
`releaseReservation`. The later catch/release sees no remaining mode and cannot
publish it either. An observation that encounters `resourceReserved` while
maintenance drains an existing reader therefore receives no automatic recovery
hint when acquisition is cancelled. It can remain in failure until an unrelated
write or explicit refresh.

Reproduced deterministically with a blocked admitted SQLite reader, an installed
invalidation feed and a maintenance request: new reads are refused, cancel the
request and await its CancellationError, confirm reads work again, then finish
the feed. No `.storeChange` was buffered. Use the same idempotent release path for
cancellation, preserving notification only for a restriction actually removed.
Cover query recovery without a new write or manual refresh.

## Review checks and checkpoint

Two temporary targeted test functions were run with
`swift test --filter 'MF01.*ReviewProbeTests'`. Both fail on the reviewed source
with the behavior above. Probe source and logs remain local; no failing probe
was added to the committed test suite. The prior full-suite success remains
valid for its existing coverage and does not cover these counterexamples.

No other blocker was identified in this bounded review. Correct both findings,
add committed regressions and re-review before the combined CI checkpoint.
Actions quota is available again, but CI and merge were not requested by this
review. No physical mutation or container reset was performed.

## Corrective re-review

Corrected source: `c174e4a`. The maintainer subsequently authorized correcting
both findings and continuing through review, CI and merge if successful.

- Restore now resolves the existing ancestor of the destination before appending
  missing path components. It rejects containment before creating directories;
  this also covers a symlink pointing into the source when its requested child
  directory does not exist. Regression tests compare the original directory
  inventory and reverify the complete source for direct and aliased paths.
- Cancellation uses the same idempotent release path as normal release. A removed
  maintenance restriction emits exactly one recovery hint; a stale second release
  does not. A committed runtime regression checks buffered hints after cancellation.
- An additional integration regression observes a query before maintenance,
  forces a rescan during drainage to expose the busy failure, cancels acquisition
  and receives a recovered query value without any post-cancellation manual
  refresh or new write. The admitted reader stays alive through recovery.

The first direct-path correction did not cover a missing child beneath a symlink;
the strengthened test caught this before delivery. The final ancestor-resolution
implementation passes both cases. An initial observation test attempted a new
subscription during maintenance and was adjusted to exercise an existing live
query, matching the reported recovery contract.

Re-review of the final corrective diff found no remaining blocker in these paths.
The targeted backup/reservation suites pass with the committed regressions.
Final local validation passes 777 macOS functions (331 legacy, 347 store,
76 runtime, 23 model), 422 selected iOS 18.5 Simulator functions (487 invocations
including parameters), Release package build, Swift 6 ModelConsumer, manifest
and diff checks. The simulator summary reports no failures/skips/runtime warnings.
The combined remote checkpoint is recorded in the development status and PR.
Compression/portable import remain planned
follow-up work; this correction does not expand the backup format or schema.

The combined [CI run 41286055397](https://github.com/bbruno84/GraphEvo/actions/runs/41286055397)
passes on `bcac4bc` after corrective re-review, including macOS/iOS suites,
ModelConsumer and independent-process local reading. Final integration-status
edits are documentation-only; the validated source/tests/workflow are unchanged.
