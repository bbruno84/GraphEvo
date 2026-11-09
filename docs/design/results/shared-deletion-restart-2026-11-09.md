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
source review found no unresolved actionable findings. No hosted CI was requested
at the initial implementation checkpoint.


## Requested hosted checkpoint and test availability correction

The maintainer requested review, CI and merge on 2026-11-09. The first
[v2 checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/42667130923)
on `6452a7b2` fails the iOS build before tests: the older hosted Xcode 16.4
compiler requires an explicit availability annotation on the existing public
GraphContext deletion test. Its API requires iOS 17/macOS 14 while the package
still compiles test sources against the legacy floor. The correction annotates
only that public-entry test; it does not raise the package floor, skip the test
on the supported iOS 18.5 runner, reduce coverage or change production code.
The initial failure remains part of the evidence; the replacement checkpoint
is recorded separately after local re-verification.

The first checkpoint's macOS job and both Swift 6 consumers pass. After the
annotation correction, all 17 local deletion functions and all 794 iOS v2
functions pass again with no failures or skips. Source review confirms the
annotation matches GraphContext's declared platform availability; all shipping
source is byte-identical to the physically tested correction.


The [replacement checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/42668738093)
on `81bc4d88` advances past the deletion test but exposes the same missing
availability on three configured File-import tests; no iOS test runs. A full
inventory of test references to the public GraphContext/connection types also
finds two string-storage tests with the same omission. All five receive the
matching method-level iOS 17/macOS 14 annotation, preserving lower-floor internal
tests and runtime-guarded cases. Existing availability on the remaining public
context/connection references was checked before another checkpoint. No shipping
source, assertions, package floors or test selections change.


The [third checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/42670656253)
on `932798d6` passes macOS and both consumers but finds the remaining omission
on the native-outbox classification test; again no iOS test executes. Inventory
now includes every iOS-17-restricted type, not only public context/connection
references. The outbox method receives the same annotation. All 19 automatic
synchronization functions pass locally, and a complete local `build-for-testing`
with explicit `IPHONEOS_DEPLOYMENT_TARGET=16.0` succeeds. This exercises the
legacy compilation floor instead of relying on the destination's defaults.
The seven annotations across deletion, configured File import, string storage
and native-outbox tests match their existing API requirements. Assertions and
shipping Sources remain unchanged. The fourth checkpoint validates this grouped
compilation correction; earlier failures are not reclassified as passing.


## Final integration gate

The [fourth requested checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/42672501837)
on `0460072b` fails before creating any job: its check suite has zero check runs
and its downloaded log archive is empty. The API exposes no more precise cause;
the CLI's workflow-file hint is generic, not an established diagnosis. Workflow
files are unchanged from the preceding runs that executed successfully on macOS.
This latest run is unavailable evidence, not passing CI or a failed product test.
No infrastructure-only retry is requested under the alpha policy.

The final shipping Sources and manifest remain byte-identical to `6452a7b2`.
All seven test-availability corrections are reviewed against their existing API
requirements. Local verification comprises the original 796 macOS functions,
794 iOS functions with no failures/skips, repeated 17 deletion and 13 File/string
functions, 19 automatic synchronization functions, and a complete final iOS
`build-for-testing` with explicit deployment target 16.0. Both Swift 6 consumers
also pass locally and in all three executed macOS checkpoints (795 hosted
functions per v2 profile). Physical evidence above is unchanged.

The maintainer authorizes integration after review and the requested checkpoint;
alpha policy permits this locally verified merge with the documented hosted
startup limitation. No beta/release remote gate is declared closed. The companion
checkpoint also receives no runner; its own report records GitHub's explicit
macOS arm64 capacity annotation, 29 passing local model functions and signed
Release plus unsigned Simulator builds. Companion integration uses the merged
library revision, with all four pins aligned and a focused local recheck.
