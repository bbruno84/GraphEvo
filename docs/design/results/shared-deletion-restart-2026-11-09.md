# Shared-owner deletion restart — 2026-11-09

## Device finding and correction

The companion Notes run uses the physical iPhone XR (iOS 18.7.11) as owner and
iPad (iPadOS 27) as participant, with already accepted invitations. A guarded
external driver calls the production Notes model and public GraphEvo APIs in the
existing app context. It never copies stores into replicas or replays consumed
mutations. The maintainer explicitly identifies all graphs as disposable test
data; the run uses `Test 04 Sharing` and fingerprints `Test 03 Sharing` as control.

Exact owner-to-participant note/cover/File recovery and participant-to-owner
NoteEditor changes pass. Read-only retains reads and refuses writes. Participant
leave removes its catalogue/replica while owner content remains. Owner deletion
then completes, but the next owner process cannot start cloud transport:
`recoveryRequired`. The preserved format-12 document contains one share attempt
without a binding, for the valid completed deletion. No other unbound assets,
ledgers or activations are observed.

`finishDeletion` previously removed bindings/membership/queues without removing
that attempt. The correction removes it in the same publication. Opening also
recovers only this exact earlier completed-cleanup case, after verified account
and full existing document/asset validation, under the existing directory lease.
Unfinished, foreign, duplicate and otherwise corrupt states remain refused
byte-for-byte. Engine checkpoints and the client identity are preserved.

## Companion finding

A remote sharing refresh can legitimately return busy while automatic transport
already owns the refresh slot. Notes previously created its observation only
after that refresh succeeded. The device run reproduced CloudKit readWrite with
consumer canWrite false, also visible as Read only in the iPad UI. Notes now
subscribes before requesting remote refresh and keeps the observation on a
transient verification failure. No library permission guard is relaxed.

## Evidence and scope

External evidence directories `ge-notes-device-tests-20261109`, `...09b`, `...09c`
and `...09d` preserve the initial nonempty-fixture refusal, refresh-busy
diagnostic, consumer-observation failure and corrected run respectively. The
corrected run passes its first 13 stages; the original owner-restart failure and
subsequent active-scene/recoveryRequired diagnostic remain recorded. The post-fix XR restart passes: CloudKit is ready, the deleted catalogue entry
and SQLite remain absent. The iPad restart also passes after leave. Both final
neighbor fingerprints exactly match both initial fingerprints, including note
values, cover bytes and opened File content. The original failed report is retained.
The read-only iPad UI was inspected: editing and deletion were disabled, while
the shared document opened in Quick Look. Owner permission changes used the
public SDK against real CloudKit; the XR native Apple management UI was not
automated because Device Hub screen sharing requires iOS 27.
Raw session documents contain account/capability state and remain external; no
stores, SDK archives or account values belong in the repository.

Regression tests exercise removal of only the deleted attempt and session reopen;
recovery of an earlier orphan while preserving the neighboring binding/attempt,
client ID and opaque checkpoint bytes; and unchanged refusal for unfinished,
foreign-zone, duplicate and other-corruption cases. Local verification passes 796 macOS v2 functions, 794 iOS functions with no
failures or skips, both Swift 6 consumers, manifest and diff checks. Focused
source review found no unresolved actionable findings. No hosted CI is requested.
