# V01 T6 — independent iPhone recovery preserves owner-only graph zones

Status: observed on two physical devices using the same owner iCloud account.
The iPhone recovered the exact five objects previously written by the iPad,
including relationships, record identities and distinct per-graph share zones.
This completes T6's initial independent-device recovery check under these
conditions; broader R01 guarantees and the v2 topology remain undecided.

## Procedure and provenance

This continues the [iPad diagnosis and successful writer](v01-t6-ipad-diagnosis-2026-10-24.md).
The existing writer run `649A26B8-C2A1-439B-A6B1-B7462E8E671D` was reused as
cloud evidence. No new writer or share creation was launched. The maintainer
connected and authorized the iPhone; the same-account prerequisite had already
been confirmed. The iPad was not needed for this reader stage.

The same fixed signed Development binary was installed on the iPhone after
verifying its authorized test destination, runtime identifier and source
provenance. Source corresponds to demo commit
`0df51b82a746804370306bb69826e5e19e1fe61a`, Swift-source SHA256
`48792e052296391d14099d2167dff832bd08edd1e6300d45a6e228f0e06581b0`.
Build metadata retains base `378221e` plus the then-frozen fix; its source hash
matches the published fix. Xcode 27.0 (27A266a), Swift 6.4 toolchain in Swift 5
language mode, and GraphEvo pin `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`
are unchanged from the writer. Hardware was a physical iPhone running iOS 27.0.1
(24A446), compared with the iPad writer on iPadOS 27.0 (24A437).

The launch used `t6-reader`, the existing run ID, a 120-second maximum sampling
window, Development verification and opt-in T6 tracing. A new process/stage
opened a new SQLite path. The reader inserted no fixture objects, created or
persisted no shares, accepted no invitation and copied/restored no writer store.
Queries covered the entire run without a graph filter. No debugger was attached.

## Observed result

The reader started at **11:48:29 UTC** and completed at **11:48:33 UTC** on
2026-10-24, exiting sampling early when the exact fixture and zone checks passed.
Four seconds is this observed stage interval, not a synchronization latency guarantee.

| Graph | Recovered members and links | Preserved zone |
|---|---|---|
| A | A-root → A-001/alpha, A-002/beta | `com.apple.coredata.cloudkit.share.158AB0D4-0AC1-46EA-8ABA-5AC23CD329C2` |
| B | B-root → B-001/gamma | `com.apple.coredata.cloudkit.share.B65658B5-5DB6-4A43-BAF6-D9DDCFF745E0` |

All five member DTOs matched the archived writer exactly: graph, node, kind,
value, parent/children, record name, zone name and share metadata. Both shares
had one owner, zero other participants and public permission `.none` (raw 1).
Each graph's members belonged to its own share zone. Both share record names
were `cloudkit.zoneshare`; the zone/record pair distinguishes their identities.

The reader reported `fixtureSaved = false`, no share operations and no stage
errors. Completed native setup/import/export events succeeded without errors;
started-only event snapshots are not failures. No diagnostic writes failed and
no trace entries or native event snapshots were dropped. Writer and reader
store, stage and process identifiers differed. The iPhone reader store identifier
was `D288B29E-A10E-4230-9E4A-4093F7A25614`.

## Evidence, checks and limits

Reader JSON SHA256:
`4abf3a38de868e69126b18f44784779aecbcce64690f9280adbbcebc54bc2d84`.
The local GraphEvoLab archive `2026-10-24-T6-independent-reader` retains the
final JSON, trace, console/copy/stop logs, original build manifest and comparison
summary. The earlier iPad archive remains unchanged. The original build manifest
records that earlier iPad-only scope; this separate reader stage was subsequently
authorized. The reader process was explicitly terminated after retaining its
final report; console exit 1 follows SIGTERM. No wipe, purge, app removal or
store deletion was performed.

This was a hardware verification with unchanged app code. The existing 45-test
passing regression result still applies to that binary; tests were not rerun for
documentation-only updates. Documentation links and `git diff --check` were checked.

The result establishes a recovered cloud zone boundary on an independent device.
Both graphs still downloaded into **one local SQLite**. It does not demonstrate
selective synchronization, separate local stores, cross-user sharing, permission
changes, graph deletion/recreation, scale, or every supported OS version. R01
remains open for those broader requirements; this is feasibility evidence for
owner-only share zones, not a final GraphEvo 2 architecture decision.
