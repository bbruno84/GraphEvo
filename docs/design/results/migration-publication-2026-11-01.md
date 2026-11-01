# MF05 — original publication result, 2026-11-01

Implementation and physical source pin: `a143f32e50308cef5467f240a6f94966c09ea41f`,
based on MF04c/#125 (`607adb4`), delivered by
[PR #126](https://github.com/bbruno84/GraphEvo/pull/126).
The single full [CI checkpoint #324](https://github.com/bbruno84/GraphEvo/actions/runs/41321832287)
passes on reviewed head `2c37e587d6dccbbe3e3971b7e1efe07455294484` after local/device
verification and review. macOS: 873 functions plus both consumers. iOS: 871 passed
functions, 969 passed invocations and one known legacy temporary-directory-alias
skip, no failures/crashes. Runner: macOS 15 / Xcode 16.4 / Swift 6.1 / iOS 18.5.
Final integration notes are documentation-only; shipping code/tests match the
checkpoint exactly. No second full run is required for those notes.

## Local verification and review

- Full macOS package: 873 test functions passed (331 XCTest, 443 store,
  76 runtime, 23 model Swift Testing functions), no failures.
- iOS 18.5 Simulator: 541 selected runtime/store/model functions passed, no
  failures/skips. The complete iOS matrix belongs to the final CI checkpoint.
- Manifest, diff formatting, Swift 6 ModelConsumer and independent ProcessConsumer
  pass. Local toolchain: Xcode 27.2/Swift 6.4.2, macOS 27.0.1.
- New tests cover original/native identity preservation, typed values and dates,
  file/cascade/surviving action publication, wipe/repopulate, no-op, bounded
  refusal, malformed intent/reason, failed backup validation, atomic rollback,
  corrupt pinned backup refusal, retry reuse, lost-result restart after later
  source edits, cancellation on both sides of save, close drainage, other-manager
  refusal and independently owned reservations.
- Actual persistent frozen transport is retained across publication: confirmed
  old value 3 cannot acknowledge current value 4; a separate empty fake-transport
  replica receives 4 without feedback. The fixture was corrected to stop the
  first cloud session before opening another engine for that database in the
  same process; its original native writer stays retained. The ownership guard
  was not weakened.

Review examined the native publication capability, source freshness, atomic
receipt, immutable intent, backup verification/pinning and cancellation/lifecycle
paths. No remaining blocking defect was identified. The latest-only receipt,
atomic-publication limits and retained failed backups are explicit limitations,
not indefinite recovery or production-scale acceptance.

## Physical CloudKit protocol

An external disposable signed demo archives the exact source pin above. Its local
bridge is not committed or distributed. iPad is the owner; iPhone XR uses another
iCloud account and an explicitly accepted read-only participant replica. Signing
was verified for only `iCloud.com.valerioburiani.GraphCKDemo`, Development. Fresh
run/zone IDs were used without resetting the container or touching old fixtures.
Seven reserved stages produced independently retrieved passing reports:

| Stage | Evidence |
|---|---|
| XR identity | Protected account capability only; no graph store created. |
| iPad seed | Two fresh graphs; A has entity/edge/action and 2-MiB file, B is a private control. Real sends and direct native zone inventory verified; invitation and shared ledger established. |
| XR accept | Empty independent replica accepts the read-only invitation, imports exactly five application primitives, verifies 2-MiB bytes and refuses consumer mutation; no upload feedback. |
| iPad publish | Source value 3 is frozen in the production transport. Working copy changes it to 4, deletes the target entity/edge/old file, updates the surviving action and adds a new 2-MiB file. Verified backup precedes original atomic commit. Frozen attempt remains equal; its successful old send leaves newer work pending. Normal bounded sends drain the final manifest. |
| XR read-published | Owner process remains alive while the independent guest sees exactly three final primitives, value 4, reduced action endpoints, deleted IDs absent and exact new file bytes. Queue remains empty. |
| iPad recover | After process restart, an ordinary edit sets 5. Reopening/publishing the old workspace recovers the identical native receipt, preserves 5 and leaves exactly one backup. Normal transport publishes 5. |
| XR read-final | Restarted guest independently reads 5 and the same final topology/file without feedback, while owner remains alive. |

Owner stages compare native zone inventories, original native store UUIDs,
unchanged share URL, shared ledger revision/information and unchanged graph B.
All checks pass. The two-phase 3→4 and later 5 observations are separate; local
commit is not treated as the peer's acknowledgement. No working PH/store is
copied into a replica or attached to cloud sync.

One CoreDevice terminate-existing launch returned no PID before the publication
stage started. Read-only directory inspection confirmed no stage reservation;
launching the absent process then completed the stage once. Subsequent restart
used explicit termination of the verified demo PID. This launcher condition is
not a reproduced runtime crash or a reason to replay a consumed mutation.

Raw stores, capabilities, reports, signing and local bridge remain outside git.
The evidence root is `/tmp/graphevo-mf05-evidence`; no sandbox paths are persisted
in runtime documents. Per-stage reservations forbid replay.

## Remaining gates

This proves bounded owner publication through the production transport to an
existing read-only participant, with restart receipt recovery and real assets.
It does not prove globally atomic cloud migration, consumer compatibility across
devices, fresh-after-publication shared bootstrap, participant-origin migration,
physical kill/power-loss during native save, external-process writers or scale.
The ledger is preserved, not an automatic migration executor. Larger staged
publication, orphan retention policy, mandatory v1 conversion and beta gates
remain separate work. S03 and cloud/session formats are unchanged.
