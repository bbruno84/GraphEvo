# MF01 — local maintenance and backup results

Date: 2026-11-01. Candidate based on T08 #120 at `8dda893`, developed on
`codex/v2-migration-foundations` for the combined #120 checkpoint. This report
does not extend the historical T08 physical results to MF01.

## Verified behavior

- Write reservations drain admitted and queued writers, reject new writes across
  aliases, allow ordinary reads and preserve independent graph progress. Nested
  holds, cancellation, final-handle closure/reopening and late releases preserve
  ownership. Exclusive maintenance also drains readers.
- Participant aliases can reopen under a write reservation without upgrading
  permissions. Unverified participant backup is refused. Confirmed removal keeps
  the runtime generation terminally fenced despite stale metadata reads or
  maintenance release.
- Native SQLite copying preserves a 2 MiB attachment with its digest and PH.
  After backup, changing the source leaves the restored graph at its original
  value and the source at the newer value. The restored PH produces the expected
  two pending primitive changes. The restore is independently opened and read.
- Manifests retain the caller reason, graph/store identities, relative inventory
  and checksums. Immutable caller journals and graph-scoped cloud recovery
  evidence survive; other graphs and opaque shared-engine state are excluded.
- Verification rejects corruption, missing external attachment content even with
  a rewritten inventory, symlinks and traversal. It validates a disposable native
  copy without changing the source bundle. Occupied restore destinations and
  invalid artifacts are refused without replacing consumer data.
- Backup cancellation releases only its own local/cloud restrictions. A manual
  pause requested before or during backup remains in effect. Automatic workers
  treat local reservation failures as temporary busy admission.
- Durable retention survives manager replacement and simulated restart without
  holding a lifetime file lock. Altering the manifest identity cannot bypass its
  matching ownership marker. Moved unretained bundles verify; interrupted owned
  stages can be removed without deleting unrelated files.

The implementation uses the native coordinator's store-copy API rather than raw
SQLite/WAL copying or derived Core Data external-storage paths. S03, record wire
formats and cloud session formats are unchanged.

## Local validation

- `swift test`: **774 test functions passed**: 331 legacy, 345 store, 75 runtime
  and 23 model. Parameterized invocations are not additional functions.
- iOS 18.5 Simulator: **419 selected store/runtime functions passed**, 483
  invocations including parameters, zero failures/skips and no runtime warnings
  in the result summary.
- Release package build, Swift 6 `ModelConsumer`, package manifest and
  `git diff --check` passed on the final source before delivery.
- New coverage includes 12 backup functions, four runtime reservation functions
  and parameterized automatic busy-admission recovery. Existing pause, sharing,
  PH, query, attachment and transport suites remain passing.

Raw logs, native stores and `.xcresult` bundles remain local. Expected native
errors from deliberately corrupted fixtures are not successful backup evidence.
No remote CI or integration merge is performed during implementation; review
precedes the one combined CI checkpoint.

## Limits and follow-up

No MF01 physical-device or live CloudKit claim is made. Cloud evidence tests use
injected sessions. This does not certify cross-process writer fencing, widget
maintenance, protected-data transitions, OS suspension, power-loss durability,
large-library memory/disk cost or arbitrary consumer artifact completeness.
Retention convenience release is best effort; explicit durable release can
report an error and be retried.

Restore materializes a new empty local destination only. It does not replace an
active graph, rewind shared engines/session cursors, roll back CloudKit or activate
consumer migrations. Shared control metadata, working-copy execution/publication,
legacy conversion and integration with actual migration recovery remain in the
[migration roadmap](../graphevo-2-migration-foundations.md) and
[post-alpha checklist](../graphevo-2-post-alpha-checklist.md).
