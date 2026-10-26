# V03 — initial local Swift 6 ownership and cancellation probe

Status: eight direct Core Data checks passed locally. This is partial V03
evidence, not Swift 6 compatibility of GraphEvo v1 or an accepted v2 API.

## Configuration

The standalone demo package `Experiments/ConcurrencyProbe` was committed as
`38768d5`. It imports CoreData/Foundation, not GraphEvo, UIKit or CloudKit.
Both package targets use Swift 6 language mode; complete concurrency checking
is explicit for the prototype target. Default declaration isolation is
nonisolated. No managed object escapes a context operation; the prototype adds
no unchecked Sendable, unsafe isolation or preconcurrency import escape hatch.

Execution used Xcode 27.1 (27A9275), Swift 6.4 (`swiftlang-6.4.0.34.1`) on
macOS 27.0.1 (26A434), arm64. The package declares macOS 12 as a deployment
floor; that runtime and iOS were not tested. No physical device, account or cloud
resource was used. Application Swift sources were unchanged by this package.

Source SHA256:
`0ca9bb447d46b11684845dc754dd448deaf4581c70f44a92cf9cb4cd322aca82`.
The hash appends each sorted repository-relative path and its bytes, without
separators, for `Package.swift`, `Sources/ConcurrencyProbe/ProbeStore.swift`
and `Tests/ConcurrencyProbeTests/ProbeTests.swift`, each prefixed with
`Experiments/ConcurrencyProbe/`.

## Candidate ownership policy and observations

An actor owns one container and one private writer context. The context's async
`perform` encloses the complete fetch/modify/save-or-rollback operation and
constructs an immutable Sendable result before resetting the context. Actor
reentrancy alone is not used as a transaction lock across suspension points.
A separate process-local registry coalesces concurrent canonical-URL opens into
one actor; this is application code, not native Core Data behavior.

| Check | Observation |
|---|---|
| 100 concurrent increments | Distinct committed values 1–100; final persisted counter 100; context work off the main thread |
| Concurrent canonical-URL aliases | Both registry handles referenced the same owner and saw the same saved value |
| Independent URLs | Different owners; an A-only row was absent from B |
| Deliberate failure before save | Error propagated, original value retained, next mutation saved cleanly |
| Close and new owner | Saved value survived; old closed owner rejected another write |
| Explicit cancellation check before enqueue | Cancelled task threw CancellationError and created no row |
| Native-only perform from a pre-cancelled task | Operation still saved and returned its committed value on this runtime |
| Cancellation after durable commit | Task was cancelled but its successful result and persisted value remained |

`swift test --package-path Experiments/ConcurrencyProbe` completed with **8
Swift Testing tests, zero failures**. The separate XCTest compatibility runner
reported zero tests; this does not replace the eight-test Swift Testing result.
Fixtures used unique temporary SQLite directories, closed their owners before
removal, and left no generated stores in Git. The local GraphEvoLab archive
`2026-10-26-V03-local` retains the test log and environment/source manifest.

## Implications and limits

Native async context access and immutable results can be compiled without
concurrency suppression in a small Swift 6 consumer. The tested registry and
single-writer-context policy avoid the exercised in-process overlap, but do not
repair or certify the v1 context manager. Canonical path handling, release and
reopen policy, case-insensitive/hard-link aliases and cross-process ownership
need separate coverage before any library contract is selected.

Cancellation must be specified relative to enqueue and commit: a cancelled
Swift Task is not evidence that Core Data cancelled or rolled back a save.
The prototype checks cancellation before enqueue and does not invent a
post-save cancellation failure that would imply the committed data disappeared.
Cancellation during queued/native work and interruption at other commit windows
remain untested.

There is no remote import, CloudKit callback, extension process, UI responsiveness
benchmark, pending-operation close stress, application-model transaction or
query-generation consistency proof here. V03 remains open for those checks.
