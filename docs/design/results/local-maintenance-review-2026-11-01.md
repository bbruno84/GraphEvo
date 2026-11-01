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
