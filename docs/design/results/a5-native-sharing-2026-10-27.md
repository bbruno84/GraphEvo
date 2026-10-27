# A5 — paired native ownership and user sharing

Date: 2026-10-27. Status: positive within the scenarios below, not a release
certification. Read the [A5 contract](../graphevo-2-user-sharing.md) and
[reproducible probe](../../../Experiments/A5NativeProbe/README.md).

## Environment and boundaries

The authorized Development container was `iCloud.com.valerioburiani.GraphCKDemo`.
An iPad (iPadOS 27.0) used the owner's account; an iPhone XR (iOS 18.7.10) used
a different account. Builds used Xcode 27.1 / Swift 6.4. Each process opened one
actual `NSPersistentCloudKitContainer` through `GraphDatabase`, with separately
reserved private/shared SQLite files. Ordinary stages consumed public GraphEvo
APIs; the deliberate process-interruption control used one internal Debug seam.

The library source evolved during these trials, before its A5 commit. This is
working-source evidence, not a claim that every stage ran from one immutable
commit. Native model hashes remained unchanged. The disposable configured demo
was outside the original demo checkout, preserving its local configuration.
There was no container reset, schema wipe, account switch or manual native
metadata modification. No SQLite files, tokens, invitation payloads, recipient
identities or raw native logs are committed. Protected app-data transports
carried only the pinned fixture and account-bound identity/invitation values.

A and B each started with two Entity, two Relationship and one Action objects,
a cycle, binary properties, tags and groups. Every application UUID was pinned.
A was invited; B stayed personal. XR also had a pinned personal control C.
Checks counted all application nodes/IDs and selected every owned native row
for mapping verification. They checked representative exact values/references,
binary bytes and tags/groups, rather than every field/timestamp byte-for-byte.

## Retained failures and corrections

The first run (`4B70CEC5-9996-40F3-9FFC-1A3CABF0030D`) loaded local stores but
failed its sharing-metadata preflight with `NSCocoaErrorDomain` code 256. Local
readiness had been treated as enough to attempt metadata work, and intent was
recorded too early. The library now observes completed public setup events for
both stores and performs its read-only metadata preflight before recording a
share-creation request. The failed run was retained without replay or cleanup;
its ambiguous requests were not reinterpreted as safe share recreation.

In the subsequent run, `owner-observe-rw` timed out after the XR had successfully
saved the restored-permission edit locally. The probe immediately closed its
writer owner. A distinct `resume-writer` stage reopened those same files and
made no mutation; it retained the native owner. A new read-only observation
`owner-observe-rw-recovered` then recovered the exact saved value on the iPad.
This supports writer-lifetime correction in the harness; it does not establish
an exclusive cause for the timeout or a delivery-time guarantee. Writer stages
now retain their owner through independent observation. Closing remains local
resource shutdown, not a cloud export barrier.

## Positive second run

Run: `413B4030-89B7-4C69-BAD6-55B6BD7DDC2D`. Each stage reserved a unique report
before work. Failed/interrupted tickets were never replayed.

| Stage | Actual observation |
|---|---|
| iPad seed / XR identity | Both stores completed native setup. A5/B5 had distinct personal share zones; XR prepared personal C and its protected recipient identity. |
| Invite / accept | Only the pinned XR recipient joined A. After native acceptance, XR recovered exact A5 in its shared store with participant role; pinned B was absent. All 35 selected native rows mapped to A's zone. |
| Participant add / owner observe | XR edited an existing value, then inserted Entity, Relationship and Action together using one explicit existing-share assignment, including every owned detail row. Independent iPad recovery found exact A8/links and unchanged B5; all 51 selected rows mapped to A. |
| Participant details / owner observe details | XR used `patchShared` to add two properties, a tag and a group to an existing entity. iPad independently recovered exact values (`note`, integer count), tags/groups, original binary content and A8/B5. All 55 selected rows mapped to A. |
| Read-only | Owner persisted read-only permission. XR waited for that actual local participant metadata; an attempted patch was rejected by GraphEvo with `permissionDenied` before save. This tests the library guard, not arbitrary-write server enforcement. |
| Restore read/write | Owner persisted read/write permission. XR observed it and saved `note = read-write-restored`. After the retained timeout/correction above, independent iPad observation recovered that exact value and all details. |
| Interrupted assignment | XR staged a new property patch, performed the actual native existing-share assignment and paused before graph finalization. Both `ASSIGNMENT-PAUSED` and `INTENT-VISIBLE` were observed; public pending diagnostics worked while the writer was paused. This interrupted stage was not reported passed. |
| Real process recovery | A new `--terminate-existing` launch killed that process and reopened the same files. `recover-patch` finalized the original recorded operation without another share call, emptied local intent, and retained A8 with the new value. Independent iPad recovery found `interrupted = survived-interruption`, exact A8 and unchanged B5; all 56 selected rows mapped to A. |
| Revocation | Owner revoked only the pinned participant. XR observed A disappear from its local catalog while C and its pinned value remained available. Owner retained A8/B5. |
| Reinvite / reaccept | Owner persisted a new invitation for that same recipient. With the new protected transport, XR accepted and recovered exact A8, all 56 mappings and no pinned B. |
| Leave / owner after leave | XR explicitly left A's zone in the shared store. A disappeared locally while C remained intact. A separate iPad launch independently recovered A8/B5 and all 56 mappings. |

Counts are fixture-specific. This run began while an earlier working-source
version used an extra empty reserved root property. Current operations use the
local ledger instead; that existing empty row was preserved. Counts 35/51/55/56
must not become universal constants or a claim that the fixture was recreated
under the final source. The additional interrupted-patch staging facade was
removed on finalization; its new detail remained on the application target.

## Local checks and remaining scope

The full macOS suite passed 430 tests: 322 legacy, 56 runtime, 34 typed-store and
18 model tests. Targeted Thread Sanitizer checks passed ten tests covering paired
resource lifecycle/setup and local journals, without a reported race. The
independent Swift 6 `ModelConsumer`, package manifest validation and Release
build passed. Release object symbols contained no recovery-hook implementation.
A pre-existing unused-variable warning remains outside this change. CI separately
checks supported Xcode 16.4 macOS/iOS Simulator builds on the PR commit.

These observations validate a usable A5 alpha path through supported public
native sharing APIs. They do not certify simultaneous structural writers,
same-key property additions, every partial-error/crash boundary, cached access
after account changes, background delivery, quotas, scale, native sharing UI or
mandatory coordinated v1 cloud cutover. Those remain explicit beta/release
work. No global synchronized flag, selective graph download or distributed lock
is inferred from this run.
