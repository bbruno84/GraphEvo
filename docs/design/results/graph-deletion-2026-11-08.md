# Definitive graph deletion — 2026-11-08

## Scope

[PR #195](https://github.com/bbruno84/GraphEvo/pull/195), reviewed implementation
`05c3f773` on `codex/v2-graph-deletion`, starts from integrated private discovery #194
(`9894f3a8`). It adds ordinary-context local/owner-private deletion, bounded
progress lookup/resume, exact native destruction recovery and prevention of
automatic missing-zone recreation. The [contract](../graphevo-2-graph-deletion.md)
defines admission, identity, ownership and completion. Native S06/S07 and the
CloudKit node/descriptor formats stay unchanged; session state advances to 12.
The companion Notes application remains a separate increment, not completed here.

## Review and corrections

Source review covered account/zone/store binding, creation ambiguity, terminal
read/write admission, resumed native preparation and cleanup, replacement
refusal, live-owner contention, relative paths and opaque engine-state handling.

- A destruction response can leave a native SQLite cleanup artifact. Recovery
  now recognizes only captured artifacts from the exact owner generation instead
  of treating any remaining SQLite filename as a live replacement.
- Same-GraphID replacement testing required checking device/inode before Core Data
  load, independently of native metadata, and before remote destructive work.
- An early journal lookup introduced a competing opening grant and rejected
  system-managed App Group permissions. The normal terminal check now joins the
  existing Apple opening grant; App Group directory identity follows its existing
  system-container contract. The queued-opening and App Group regressions pass.
- Terminal journals/receipts are located relative to SQLite. A recorded previous
  coordination root is validated as a relative component; recovery obtains both
  Apple grants after a quiescent container move. Exact file/generation checks remain.
- The oversize migration test raced asynchronous account verification after reopen
  under full-suite load. It now awaits the public account-state feed from its
  existing injected account adapter before reading; no identity guard was removed.
- New owner deletion entry points explicitly refuse App Group contexts. The
  existing participant leave path remains supported there; expansion is not implied.

No unresolved actionable findings remain within this increment's selected scope.

## Local checkpoints

- Final macOS v2 checkpoint: 790 functions (663 store, 94 runtime, 33 model),
  followed by 11 focused deletion functions after the final ordinary-context guard.
- iOS18.5 Simulator checkpoint: 787 passed, zero failures/skips, before the final
  corrupt/symlinked-journal test and defensive guards. Final Release device builds
  compile those guards; their negative cases pass on macOS. This is not relabeled
  as a new full iOS run on the final two-line public-context restriction.
- Both Swift 6 consumers pass independently. Manifest and diff checks pass.
- No hosted CI requested under the selected alpha policy.

Tests cover local deletion with File content and neighboring graph preservation,
offline/ambiguous server outcomes with exact operation reuse, wrong-account refusal,
missing initial publication, stale-private-zone recreation refusal, another owner
registration and successful detach, the native/journal gap, same-GraphID replacement,
quiescent container relocation, and corrupt/empty/symlinked journal refusal.

The first broad run exposed the App Group/opening regressions above. A later run
exposed the existing oversize fixture race. Their failures are retained separately;
only corrected runs are reported as passing.

## Separate-process macOS faults

The Debug-only laboratory executable creates fresh fixtures and SIGKILLs itself
before native destruction, after native destruction and after artifact cleanup.
Each fixture includes a 32 KiB File. The parent moves each stopped fixture's
container directory, then a new process resumes the exact operation. All three
pass; library-owned File roots disappear and the consumer input remains unchanged.

A fourth case uses an independently running holder process. Deletion is deferred,
the deleting owner closes normally, the holder releases its native store and a new
process finishes removal. This passes without removing an unverified registration.
External evidence: `ge-deletion-relative-files-final` under the temporary evidence
root. Earlier failed and corrected trials remain separate; no consumed mutation
was replayed. These are process-death and quiescent-move checks, not power-loss or
arbitrary live relocation certificates.

## Physical Development CloudKit

Three fresh Release trials pass on the connected iPad. The last includes portable
journals and defensive file guards; the subsequent public ordinary-context check
was verified locally. An ordinary graph publishes a note, a 128 KiB cover,
a 256 KiB File and an edge. Direct server reads verify content before closing its
original owner. A fresh catalogue/session and empty SQLite recover all content.

The recovered owner deletes the graph. The zone disappears from private discovery,
local terminal status is completed, and a restarted session resumes that same
completed operation. The returning original replica is refused zone recreation
and retains its local content. All owners/connections close successfully.

External evidence directories: `ge-private-deletion-ipad-20261108-a`, `-b`, `-c`.
Generated stores, reports and account values stay outside Git. These are sequential
independent sessions on one physical device. They do not certify same-account
cross-device convergence, participant UI delivery, all account-switch interleavings,
protected-data/storage/power faults or beta readiness. The XR has a different
account and remains for shared Notes acceptance in the companion app increment.

## Follow-up: ordinary process death before deletion

[PR #196](https://github.com/bbruno84/GraphEvo/pull/196) fixes the gap.
The Notes force-quit smoke exposed a case outside the original three destruction
crash points: SIGKILL during ordinary opening left a nonretiring registration and
blocked a later, newly requested deletion. The terminal protocol now recovers
only exact same-graph nonretiring peers after an exclusive Apple deletion grant,
matching durable intent, source inode and native UUID verification. It validates
the complete registration set before deleting any peer evidence. Foreign or
retiring registrations remain protected; ordinary opening does not clean them.

Separate macOS processes pass five fresh cases: the original three SIGKILL
points with container relocation and File cleanup; ordinary holder SIGKILL
followed by fresh deletion and independent completion resume; and a still-live
holder that defers deletion until normal detachment. Consumer input bytes remain
unchanged. External evidence: `ge-deletion-stale-owner-process-20261108`.
Focused deletion tests pass all 14 functions, including parameterized foreign and
retiring claims. The complete macOS v2 profile before the additional missing-intent regression passes 792 functions (665 store,
94 runtime, 33 model). The corresponding iOS 18.5 Simulator profile passes
790 functions with zero failures or skips before that additional regression.
The final missing-intent regression also passes separately on iOS (1 test,
zero failures/skips). This follow-up does not add new real-CloudKit evidence.
