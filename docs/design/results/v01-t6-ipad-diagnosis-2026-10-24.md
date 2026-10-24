# V01 T6 — observer deadlock fixed; owner-only zones recovered on iPad

Status: the laboratory deadlock was reproduced and diagnosed on a physical iPad.
After correcting event delivery, both owner-only shares were created and
persisted, and a fresh SQLite replica recovered their exact data and share/zone
identities on the **same iPad**. Independent-device recovery was pending at this stage; the subsequent
[iPhone reader result](v01-t6-independent-reader-2026-10-24.md) records that follow-up.
The iPhone was not used in this investigation, as requested by the maintainer.

This follows the [initial inconclusive T6 attempts](v01-t6-2026-10-23.md) and
[network follow-up](v01-t6-network-retry-2026-10-24.md). Those original checkpoints
remain unchanged; the findings below explain the reproduced laboratory path
rather than recasting the old unfinished reports as completed trials.

## Diagnosis before changing event delivery

Opt-in `--v01-t6-trace` instrumentation writes bounded, synchronized JSONL
outside the MainActor. It marks invocation entry/return, native callback entry
before metadata or object lookup, continuation resumption, share persistence,
and a five-second MainActor heartbeat. A separate structured Logger records
the same phase names. The recorder contains no account identities or payloads.
Tracing and periodic report writes can affect timing; this is diagnostic evidence,
not a performance benchmark.

The pre-fix iPad run `07132211-4640-4609-9423-1CFB8C231FAE` started at 08:07:13
UTC. Its root fetch completed and `shareCallEntered` was retained at 08:07:17.
There was no invocation-return marker or heartbeat before the diagnostic attach.
An interactive LLDB attachment obtained this concurrent wait:

| Queue | Relevant stack |
|---|---|
| Main thread | `_PFRequestExecutor wait` inside `NSPersistentCloudKitContainer shareManagedObjects:toShare:completion:` |
| Core Data CloudKit queue | `NSOperation waitUntilFinished` while posting `eventChangedNotification` through NotificationCenter |

The laboratory had registered that notification observer with `queue: .main`.
Native sharing waited for Core Data work, while event publication synchronously
waited for the occupied main queue. This supplied a concrete wait cycle, rather
than inferring an API rejection or missing callback from a running checkpoint.
The debugger was explicitly detached and the pre-fix process then terminated;
this diagnostic intervention is retained separately from the successful runs.

## Focused correction and verification

T6 now registers its observer with `queue: nil`, snapshots the immutable event
on the posting queue, and asynchronously hands the value to a MainActor Task
for report/UI delivery. Core Data no longer waits for the main-queue observer.
The model, main-queue share context, fixture, share calls and cloud resource were
kept unchanged for the controlled follow-up. Callback tracing uses explicitly
Sendable closures; no managed object is marked Sendable or moved across queues.

The regression suite passes **45 tests**, including concurrent/bounded trace
retention and an event-delivery test that requires a background notification
post to return while the MainActor is occupied. The earlier `.main` registration
would fail that bounded test. Simulator tests execute no native cloud sharing.

The fix source is demo `0df51b82a746804370306bb69826e5e19e1fe61a`, with app
Swift-source SHA256
`48792e052296391d14099d2167dff832bd08edd1e6300d45a6e228f0e06581b0`.
The build records base `378221e` plus the then-uncommitted frozen fix; its hash
was verified against the subsequently published commit. The pre-fix diagnostic
source was `378221e`, hash
`ddfe7dd1407ed1ff2371bfbc84b84eda7a6fcbe17e8a3724e4422805bbd10b15`.

Both use Xcode 27.0 (27A266a), Swift 6.4 toolchain in Swift 5 language mode, and
GraphEvo pin `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. Signed Development
entitlements, the dedicated authorized cloud destination, runtime identifier
and source provenance were verified before installation. Hardware was the
physical iPad, iPadOS 27.0 (24A437). Personal identifiers remain outside Git.

## Successful writer and fresh same-device reader

Run `649A26B8-C2A1-439B-A6B1-B7462E8E671D` used one private SQLite and the
unchanged five-object fixture: A-root with A-001/alpha and A-002/beta, B-root with
B-001/gamma. Relationships link only each root and its own children.

The writer ran from 08:14:39 to 08:15:24 UTC, including 30 seconds of post-share
sampling. Share A completed creation/assignment at 08:14:47 and share persistence
at 08:14:48; B completed those stages at 08:14:51 and 08:14:53. Callback-entry
markers preceded invocation-return markers, confirming that these native calls
can perform synchronous work despite exposing completion handlers. The fix
removed the cycle; it does not make those calls nonblocking on the main thread.

| Graph | Exact members | Assigned zone |
|---|---|---|
| A | A-root, A-001, A-002 | `com.apple.coredata.cloudkit.share.158AB0D4-0AC1-46EA-8ABA-5AC23CD329C2` |
| B | B-root, B-001 | `com.apple.coredata.cloudkit.share.B65658B5-5DB6-4A43-BAF6-D9DDCFF745E0` |

Each share had one owner, zero other participants and `publicPermission = .none`.
The share record name was `cloudkit.zoneshare` in each distinct zone; identity
is the zone/record pair. Returned callback members were exactly A's three objects
and B's two, with no lookup errors. Final per-object mappings and share membership
matched these boundaries. No participant was added or invitation sent.

After retaining the completed writer report, its process was terminated. A new
reader process on the same iPad opened a new SQLite path and ran from 08:16:12
to 08:16:16 UTC. It created neither fixture objects nor shares, accepted no
invitations, and copied/restored no writer store files. It recovered all five
objects, their exact values and parent/child links, and identical record names,
zone names and share metadata. Writer and reader had different local store,
process and stage identifiers. Reads used the entire run, without a graph filter.

Both final reports had no stage errors, no completed native event errors,
and zero trace-write failures or dropped entries. The reader recovered both
graphs into its single local store: distinct cloud zones do not imply separate
SQLite stores or selective download.

## Retained evidence and limits

| Completed artifact | SHA256 |
|---|---|
| Writer JSON | `25a3b8291a105af1aa167b928000590f265e2f7009fa3198893e4d7d54bdb617` |
| Reader JSON | `52f02abef98c3bf396bcb66cda98ae2cff264dd4b84020bf12f956871fc4d3d4` |

The local GraphEvoLab archive `2026-10-24-T6-ipad-diagnosis` retains pre-fix
traces, stack and provenance separately from post-fix writer/reader reports,
traces, signed build/install logs and comparison summary. All iPad processes
were ended after evidence retention; post-fix console exit 1 follows explicit
SIGTERM. No wipe, purge, app removal or store deletion was performed.

This establishes owner-only zone creation and fresh **same-device** replica
recovery under these conditions. It does not complete independent-device T6,
cross-user sharing, selective recovery, lifecycle/scale checks, or a GraphEvo 2
architecture decision. R01 remains open with concrete evidence for this supported
zone boundary. Synchronous native work also remains relevant to v2's concurrency
design; a completion-handler bridge alone does not guarantee a nonblocking call.
