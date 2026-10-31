# GraphEvo 2 — T07 explicit zone sharing

Status: package-only implementation integrated through
[PR #119](https://github.com/bbruno84/GraphEvo/pull/119), after review,
corrective re-review, full CI and the authorized merge. The
[physical result](results/zone-sharing-2026-10-31.md) retains the actual runtime
pins and each checkpoint's scope. This replaces neither the public opening API
nor the historical A5 native mirroring backend.

## Boundary and Apple contract

Each owner graph keeps its custom zone in the **private** database. Explicit
sharing creates one zone-wide `CKShare` in that zone; participants access the
owner's zone through their **shared** database. It is not a move or a second
copy of the owner's cloud records. See Apple's [shared records](https://developer.apple.com/documentation/cloudkit/shared-records)
and [zone share initializer](https://developer.apple.com/documentation/cloudkit/ckshare/init(recordzoneid:)).
The existing ContextManager owns the private/shared engines; no per-graph engine
or alternate application-data sender is introduced.

`inviteCloudParticipant(_:to:permission:configuration:)` adds an explicitly
identified account with read-write (default) or read-only permission. Public
permission is always none. The zone must already exist; invitation creation
is not a barrier for graph publication. A private control graph remains unshared.
`cloudSharingIdentity(_:)` supplies the current container-scoped account identity
for protected host transport, not diagnostics or application data.

`acceptCloudInvitation(_:configuration:)` requires an explicitly created empty
coordinated graph with the invitation's GraphID. The host chooses a current local
URL; invitations contain no local paths. Graph identity comes from the protected
capability and is checked against every imported GraphEvoNode. It is not embedded
in custom CKShare fields or inferred from its title. Validate container,
environment, recipient, owner, zone-wide share identity, private participant role,
acceptance status and permission before native acceptance. An already accepted
invitation is inspected without repeating native acceptance. Acceptance does
**not** certify local import or convergence; fetch/apply and T06 perform that work.

## Durability, access and lifecycle

Session format **4** adds bounded owner share-attempt markers. Earlier alpha
session formats are refused without rewriting. S03, cloud node/asset formats and
transport format 2 are unchanged. Fixtures use fresh session/store locations and
zones without resetting the container. Mandatory v1 data migration is separate.

Complete the share lookup, zone check and participant preflight before reserving
creation. Immediately before the first possible create/save, the service invokes
an awaited session callback that durably records the deterministic zone share
identity. Preflight failures leave creation available, including after restart.
The callback is scoped to its admitted operation; late/duplicate reservations are
refused, and a persistence failure prevents the native write.
A retry fetches `CKRecordNameZoneWideShare`; if it is absent after an ambiguous
attempt, report `metadataPending` instead of creating another share. The marker
also counts against session event/byte limits. An operator recovery API is outside
this increment. A failed or concurrent scope admission must not consume that marker.
A failed acceptance keeps the replica write-protected; retry the same invitation
to inspect server acceptance and finish the exact route. Never substitute another
graph, native file or recipient.

Reserved local root metadata records participant binding/account, accepted state
and permission, bounded to 64 KiB. All consumer transactions (including attachment mutations) check
this metadata before invoking their body; all handles and reopenings share it.
Pending/read-only participants cannot write. Incoming imports use the privileged
existing path and do not require consumer write permission. Pending outgoing work
is preserved and refused when write permission has been reduced. Confirmed zone
deletion also refuses subsequent consumer writes.

CKShare records are control metadata, not GraphEvoNode payloads. Apply their
permission reductions in one idempotent metadata transaction per received cut before decoding
unrelated application data; retain inbox entries until that local commit succeeds.
Select CKShare controls before taking the bounded application prefix, preserving
application-event order and the requested total limit. Zone deletion retains
highest priority. A malformed earlier application record cannot hide a retained
permission reduction behind `maximumEvents`.
Private owner share deletion does not delete the graph. Participant share deletion
removes write permission; leave/revocation/purge, cached-read policy, stale control
hardening and reinvitation are subsequent gates. No offline cache is represented
as proof of current server authorization; CloudKit remains the authority.

Sharing operations use T05 graph admission and the existing per-scope session
exclusion. Pause rejects new operations and drains admitted work; stop waits for
admitted native sharing operations before releasing engine/session ownership.
No network await occurs inside a Core Data transaction. Sharing metadata uses the
sync metadata author, preserving timestamps, query invalidations and PH filtering.

## Validation and remaining scope

Deterministic checks cover exact binding, durable create intent, wrong recipient,
nonempty replica refusal, interrupted acceptance/restart, all-handle permission,
read-only and pending writes, pause, scope contention, stop drain, secure CKShare
archive separation and old-session refusal. Physical protocol:
[ZoneSharingProbe](../../Experiments/ZoneSharingProbe/README.md).

Production invitation UI/URL routing, leave/purge/revoke/reinvite, account/cache
access reduction, concurrent invitation edits, offline permissions, actual crash
faults and production CloudKit schema rollout remain alpha/beta gates. No global
synchronization or distributed lock is promised. Workflow: local validation and
physical probes, review/corrections, CI checkpoint, authorized PR merge.


Initial local validation on library source `d5e4693`: 725 passing macOS functions (331
legacy, 300 store, 71 runtime, 23 model), Swift 6 ModelConsumer, manifest and diff
checks. Selected iOS 18.5 suites passed 66 reported tests; the final T07-only
checkpoint passed 12 reported tests after the last correction. These are local
checks, not remote CI or a completed review. Physical evidence retains its own
pins above. Remote CI was deferred at that local checkpoint until review and corrections finished.


The [post-review result](results/zone-sharing-2026-10-31.md#post-review-p2-correction-check)
records corrected source `b171cde`, the two reproduced P2 closures, six committed
regressions and a three-stage real creation/import recheck. That source passes
731 macOS functions and 83 selected iOS tests, with no remaining blocking issue
found in the corrective re-review. The subsequent full macOS/iOS checkpoint
[41228512926](https://github.com/bbruno84/GraphEvo/actions/runs/41228512926) passes
on reviewed head `61b066a`. Final integration-status edits are documentation-only;
source, tests and workflow retain that exact validated content.
