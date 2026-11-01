# MF04b — isolated working-copy preparation

Date: 2026-11-01. Base: integrated MF04a/#123 (`3b0c326`). Implementation:
`codex/v2-working-graph`, direct PR to `codex/graphevo-2`, pending review and CI.
This is local preparation evidence, not publication/cloud-convergence acceptance.

## Delivered boundary

The package-only ContextManager preparer retains owned original-store local-write
and graph-data-sync holds, makes a complete native copy, validates it, strips its
operational checkpoint/transport authority and returns a normal editable GraphStore
without a sync session. No backup is created during preparation. Logical graph/node
identities, application values, files, deletion identities and conflict policy remain.

A native workspace-purpose UUID excludes ordinary manager/database/runtime
opening. A bounded relative descriptor binds graph/schema/source/working identities
and fresh tokens. One setup save on the working store establishes a numeric PH
anchor after a separately captured working token; source history and pending work
are outside the consumer range. Successful detach/move/reopen preserves that cut.
Close drains working access and releases only owned source holds. Explicit discard
checks physical directory/store identities, marker/descriptor and a bounded tree
without links. Unknown/replaced resources are preserved. Failed-open shutdown
errors retain their stage even when the registry returned no handle.

## Local evidence

Environment: Xcode 27.2, Swift 6.4.2, macOS 27.0.1; iOS Simulator 18.5.

- `swift package dump-package` and `git diff --check`: passed.
- Complete macOS package tests: 837 functions passed (331 legacy XCTest;
  407 store, 76 runtime and 23 model Swift Testing functions).
- Complete selected iOS store/runtime/model tests: 505 functions / 592
  invocations passed, no failures or skips.
- A final cleanup-error guard and two additional regressions followed those broad
  checks. Final focused macOS validation: 37 functions across workspace, backup and
  coordinator suites passed. Final iOS validation of the same suites: 37 functions
  / 40 invocations passed, no failures or skips. These are the final-source checks;
  the earlier broad runs are not represented as reruns of that correction.

The 11 workspace test functions (12 parameterized invocations) cover:

- Complete Entity/Relationship/Action copy, tags/groups, null/UUID values and a
  2-MiB attachment; independent edits/emptying preserve source content and files.
- Fresh baseline excludes pre-copy/setup history; a later consumer edit creates
  local-authored PH. No copy-side sync session is available.
- Frozen original batch remains acknowledgeable; a real encoded pending transport
  attempt is stripped only from the copy, preserving source retry identity.
- Conflict policy, modifiedAt presence and deleted-ID refusal survive preparation.
- Ordinary manager/database opening refusal, including after close, wrong workspace
  UUID and refusal to create a missing workspace store.
- Independent overlapping workspace/caller reservations, persistent manual cloud
  pause and unrelated graph progress; source reads remain available.
- Read-only and read-write participant refusal without removing their authority.
- Occupied/nested destinations, pre-cancellation, cancellation during validation
  and validation failure without changing the original or creating a backup.
- Working writer drain, query-observation termination and concurrent discard.
- Replaced directory/SQLite, corrupt descriptor and symlink refusal; corrected
  ownership-preserving cleanup is retryable and successful discard is idempotent.
- Failed-open shutdown classification without a returned handle retains the stage
  and exposes cleanup failure. This test injects the registry's error; it does not
  claim physical native-detachment fault recovery.

No physical/cloud protocol ran: isolation/preparation does not start network
transport. No CI checkpoint has been requested; review and corrections precede CI.
No generated stores, tokens, logs or device artifacts are committed.

## Remaining gates

Bounded PH reconstruction/sealing, explicit reopen and stale-source recovery,
interrupted durable preparation/seal recovery, participant lifecycle integration
and original-store publication remain unimplemented. Retained files cannot yet
be reactivated through a supported workspace API. Full native failure/power-loss,
external-process writers, filesystem races, scale/memory/disk envelopes and actual
cloud publication remain separate acceptance work. No beta/stable gate closes.
