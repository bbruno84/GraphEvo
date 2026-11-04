# H02 public invitation — first physical checkpoint

2026-11-04. This is a bounded, in-progress two-account Development trial using
the public demo, not closure of PA03 or a global synchronization certificate.
The shipping starting point is library `6dc37bbe` and demo `8f476fc`. Local
signing overrides use the existing laboratory identity/container; no provisioning
registration or repository signing values are introduced.

## Observed failure and diagnosis

The owner used iPad13,18 / iPadOS 27.0 (24A437); the participant used iPhone11,8 /
iOS 18.7.11 (22H384). The iPad owner presented Apple's sharing UI and sent a native
invitation. The
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
leaving the original one note. After permission restoration to readWrite, the
participant created a second note. It arrived on the owner after a delay; native
observations match both saved note IDs/titles on both devices, and the user
confirmed visibility. No duplicate insertion was used to force convergence.

The participant was then force-quit and reopened through the same public
workspace/connection/join. Both notes remained visible. Leave shared graph was
confirmed through the demo's destructive dialog: the participant became empty,
the owner retained both notes, and the durable membership reported removed/left
with no pending remote command. The owner's Apple UI still displayed the former
contact as invitation sent; this is not evidence of active participant access.
The owner resent the link through Apple's UI. Acceptance in a fresh participant
workspace retained the join, but opening failed before creating a native file.
After restarting the participant app and resuming that same workspace/join, both
notes arrived. No additional invitation or application mutation was replayed.

An offline regression identifies two workspace ownership boundaries: the demo
must retire its old GraphContext when selecting a new workspace, and a completed
participant purge must release the idle context graph claim. The old context
remains blocked. An unsettled remote leave or failed native detachment must keep
its claim. The new regression retains both old context and handle while a fresh
context accepts the same graph into an independent empty store; it covers normal
leave, deferred remote leave and confirmed access revocation. This is automated
evidence, separate from the restart-assisted physical continuation.

Private instrumentation lives outside shipping checkouts and is not a proposed
public diagnostic API. Live directory copies are forensic observations rather
than certified backups or fresh replicas. A debugger attachment attempt failed
to obtain state and the participant process subsequently was not active; the
continuation therefore does not claim an uninterrupted original writer lifetime.
Two demo identities briefly existed on the iPad after initial signing setup;
the correct laboratory app was explicitly restored before the confirmed checks.
No retrieved crash report establishes a crash cause.

## Reviewed integration

The library correction integrates through [PR #153](https://github.com/bbruno84/GraphEvo/pull/153).
Reviewed full [checkpoint #41872809620](https://github.com/bbruno84/GraphEvo/actions/runs/41872809620)
passes on 012b5083082b7674dd6a525fdade32f8e9e2eb3d: 1,040 macOS functions,
1,037 passed iOS functions with the known skip, and both Swift 6 consumers.
The first attempt acquired no hosted runner and executed no steps; GitHub
reported macOS arm64 capacity constraints. Its sole retry on the same reviewed
head supplies the passing checkpoint above.
Local focused iOS passes 35 functions; the strengthened import regression passes
five repeated runs in both permission modes. Final integration notes change only
documentation; shipping/test/consumer/workflow inputs match that checkpoint.
Companion demo delivery uses the final library integration pin and corrects the
misleading participant zone presentation separately. This does not retroactively
turn the original failed trial into a success or close broader device gates.

## Remaining scope

Fresh reinvitation recovered after an app restart, as recorded above; acceptance
without that restart on the final workspace/claim corrections remains separate.
Permission restoration/reverse transfer, participant restart and local/remote
leave settlement have the bounded observations above. Repeat any required acceptance on the reviewed final library/demo
pins. This checkpoint does not validate attachments, large-store sharing,
Production deployment, background delivery, protected-data/account transitions,
App Group writers or interruption/crash durability. Retain the initial failure
and candidate continuation as distinct evidence.
