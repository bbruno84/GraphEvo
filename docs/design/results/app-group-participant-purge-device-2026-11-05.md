# Participant replica purge in a physical App Group

The signed CoordinationLab host ran on iPadOS 27.0 and iOS 18.7.11
(iPhone XR). Both devices ran build 5 from `e8c6d269` plus private test
code, with a fresh disposable App Group fixture on each. The host used the
real `GraphContextManager.leaveCloudShare` path, an injected CloudKit adapter
and a test gate before native destruction. It passes an explicit SQLite URL
inside the App Group container.

| Check | Physical iPad | Physical iPhone XR |
| --- | --- | --- |
| First leave with an active test claim | Refused, replica intact, journal in `purging` | Refused, replica intact, journal in `purging` |
| Application read through the previous handle during `purging` | Refused | Refused |
| Explicit leave retry after the test releases the claim | Journal in `removed`, reason `left`, no pending leave | Journal in `removed`, reason `left`, no pending leave |
| Exact replica SQLite, WAL and SHM after retry | Absent | Absent |
| Neighboring SQLite store and byte sentinel | Preserved, SQL control row reads `742` | Preserved, SQL control row reads `742` |

The Mac independently checked the copied journal and store artifacts,
including opening the neighboring SQLite store read-only. The retained
evidence manifest covers the build and launch records, verifier and device
artifacts. Its SHA-256 is
`cf997558bf3c2de28e886819a524b9db281ef65fd189e62d6a8865603dc2d23e`.
A direct app launch supplied the physical coverage after the package test
runner stopped before executing tests because it lacked a device app host.
An earlier iPad launch exited with signal 9 before it recorded a verdict.
The build 5 pass comes from a fresh fixture.

The host injected the claim in-process and controlled its release. This
establishes the local leave and retry behavior with an injected refusal,
including access refusal through the original handle.
App Group owner recovery after interrupted close still requires evidence
that connects a second process, its exact claim and the real purge path.
The iPad widget in this build is static. The host runs creation and leave
in one execution, with no handoff stage for a second process. The earlier
[R device harness](apple-owner-r-device-validation-2026-11-05.md) drives
its own fixture and cannot establish attachment or exit for this replica.
The next composed probe needs a shared fixture with separate stages for
attachment, interrupted close, supervised exit and explicit leave retry.
The [supervised macOS experiment](app-group-verified-purge-2026-11-05.md)
separately verifies a laboratory proof tied to a reaped child. PA02 remains
open. Without proof that the exact prior owner exited, cleanup stays pending.
These runs use simulated CloudKit responses.

## Integrated opening regression

[PR #169](https://github.com/bbruno84/GraphEvo/pull/169) separately covers the
opening race reproduced by the macOS experiment. A queued open-existing
request rechecks the file under the writer fence before Core Data loads it.
If the replica disappears while purge recovery is waiting, the recovery
keeps its durable intent and a retry settles the removal. The reviewed
source commit `65ca148a` passed 50 focused macOS tests and 49 on the iOS 18.5
simulator. The physical build predates this source commit.
