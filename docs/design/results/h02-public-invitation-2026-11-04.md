# H02 public invitation — first physical checkpoint

2026-11-04. This is a bounded, in-progress two-account Development trial using
the public demo, not closure of PA03 or a global synchronization certificate.
The shipping starting point is library `6dc37bbe` and demo `8f476fc`. Local
signing overrides use the existing laboratory identity/container; no provisioning
registration or repository signing values are introduced.

## Observed failure and diagnosis

The iPad owner presented Apple's sharing UI and sent a native invitation. The
independent iPhone XR account received it, opened the demo and completed the
public join. The participant reported active/readWrite, and GraphID matched.
The one owner note did not appear after explicit sync/refresh or foreground
checks. No invitation or application mutation was replayed.

Private session snapshots show identical container/environment/graph/zone name,
with the participant zone owner matching the owner's account. The participant's
workspace card displayed its separately generated local zone name: that is a
presentation defect, distinct from the actual route. Raw account, invitation,
engine state and store artifacts remain private and are not committed.

A private diagnostic build exposed an automatic `history:4` block, corresponding
to `GraphSyncError.historyUnavailable`. The participant's retained history began
with trusted bookkeeping only. The first-checkpoint check filtered those
transactions before requiring native transaction 1, refusing the complete cut.
The initial automated H02 test only checked that a read-only participant fetched;
it did not require imported rows or cover a writable participant's initial turn.

The corrected regression requires the complete remote record (including Data),
checks no outgoing echo, and covers read-only and read-write participants. Both
variants reproduce the failure on `6dc37bbe` before correction. The repair checks
the bounded unfiltered first native cut, still requires transaction 1, excludes
bookkeeping from application work, and persists a real last-native token even
for an empty cut of application rows. Later scans keep the original metadata
filter and migration-workspace processing is unchanged.

## Candidate continuation

A private build containing that repair resumed the exact participant workspace
and already accepted join. It reached idle with no pending work or failure.
The independently copied participant store contained the same saved note ID and
title as the owner; the user also confirmed the note in the participant UI.
No new store, account switch, invitation or owner-note insertion was used.

The owner then changed the native participant permission to readOnly. The user
confirmed the participant's inspected status and that Add demo note was refused,
leaving the original one note. Upgrade/reverse transfer and later stages are
recorded separately as they complete; they are not implied by this result.

Private instrumentation lives outside shipping checkouts and is not a proposed
public diagnostic API. Live directory copies are forensic observations rather
than certified backups or fresh replicas. A debugger attachment attempt failed
to obtain state and the participant process subsequently was not active; the
continuation therefore does not claim an uninterrupted original writer lifetime.
Two demo identities briefly existed on the iPad after initial signing setup;
the correct laboratory app was explicitly restored before the confirmed checks.
No retrieved crash report establishes a crash cause.

## Remaining scope

Complete and record permission restoration/reverse transfer, restart, leave and
reinvitation. Repeat any required acceptance on the reviewed final library/demo
pins. This checkpoint does not validate attachments, large-store sharing,
Production deployment, background delivery, protected-data/account transitions,
App Group writers or interruption/crash durability. Retain the initial failure
and candidate continuation as distinct evidence.
