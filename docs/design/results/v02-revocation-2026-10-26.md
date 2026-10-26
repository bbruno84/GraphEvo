# V02 — revocation on an already-open participant

Status: observed through public sharing APIs on the disposable Development
fixture. This verifies the functional revocation case, without inferring
Core Data implementation details or a general synchronization deadline.

## Procedure and result

The existing [cross-account fixture](v02-cross-account-smoke-2026-10-26.md),
run `8A6E6A45-2D7D-44C9-B127-32A552C1F773`, was retained. The owner was the
iPad (iPadOS 27.0, 24A437); the participant was the other-account XR
(iOS 18.7.10, 22H374). This followed the
[read-only case](v02-readonly-replica-2026-10-26.md), using the ordinary
participant stores, never the consumed read-only write probe.

The participant first opened its original private/shared stores and recovered
all three A objects, their links and identities. It announced readiness at
07:48:06 UTC and kept the same container open for the observation window.
The owner then removed only the authorized participant from A's `CKShare`
and called `NSPersistentCloudKitContainer.persistUpdatedShare`. No purge,
fixture rewrite or owner object deletion was performed.

At 07:48:34 UTC the participant observed A's removal: three shared objects
became zero. The final snapshot remained empty at 07:51:06 UTC, with no B
objects imported. The owner operation returned successfully. Both its final
snapshot and a separate owner reopen retained all five A/B objects, exact
values, links, record identities and share identities. A was owner-only;
B was unchanged. The participant's prior edit remained on the owner.

This satisfies V02.6 for this fixture and supplies a narrow V02.8 result:
revocation reached an already-open participant. It does not certify every
live update, background delivery, permission transition or offline case.

## Evidence and limits

Case `F17BC725-3DDB-460F-B9D9-25DDEC09D230`; demo source `d8d0b73`, Swift
source SHA256 `cefd1d3bbea59429e121c2029edafdd850016f8d29edacd60cb43b6f90429912`.
The app suite passed 78 tests before the physical-device run. Xcode 27.1
(27A9275), Swift 6.4 in Swift 5 language mode; GraphEvo pin
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. Signed Development entitlements,
test container, source provenance and provisioning were verified.

Intervals are UTC on 2026-10-26:

| Stage | Interval | Final report SHA256 |
|---|---|---|
| participant-watch | 07:48:01–07:51:06 | `88e2abacc0e8b2096ededb7ea9a432a47a6dd78d702cccc35aa865c31fd3e20c` |
| owner-revoke | 07:48:24–07:49:03 | `a7b96086dba83015570c195c123587f7634e62b28157be2a6d3a02ac98e68838` |
| owner-verify | 07:50:46–07:51:24 | `49eb439f5b9fa6dd33680ddf9deecbc9115de4a281044bc193405f2cb4785726` |

All stages ended without operation or sampling errors. Final reports were
retained, stores detached, and each process explicitly stopped afterwards.
The bounded participant report omitted 20 intermediate samples; its explicit
baseline, first absence, retained later samples and final absence remain
available. No complete sample-by-sample timeline is claimed. Event/trace
drops and trace-write failures were zero. History observations are accessory
and are not used as causal or completion barriers.

The private evidence archive is
`2026-10-26-V02-revocation-F17BC725-3DDB-460F-B9D9-25DDEC09D230`, including
independent comparisons of complete values and identities. Account identifiers,
invitation URLs, reports and device logs remain outside Git. No wipe or
Production resource was used. The next functional check is reinvitation and
participant-initiated leaving through the supported sharing API.
