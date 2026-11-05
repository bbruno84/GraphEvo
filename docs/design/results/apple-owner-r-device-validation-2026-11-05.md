# App Group lifecycle with Apple owner coordination

The physical R experiment carries the [macOS prototype](apple-owner-presence-replacement-2026-11-05.md)
into the isolated CoordinationLab host and widget. Both use the actual
`GraphContext` and the S04 model for a dedicated store in the laboratory App
Group. They keep the writer flock, use finite Apple access for native open,
ordinary writes and final detach, and omit the lifetime `owners` flock.

## Normal cycles

| Platform | Result |
| --- | --- |
| Physical iPad, iPadOS 27.0 | **PASS**. Thirty Home, widget write and host reopen cycles with stable, distinct host and widget PIDs. No new CoordinationLab crash report was observed in the run. |
| iOS 18.5 simulator | **PASS**. Thirty equivalent cycles driven by XCTest against SpringBoard and the installed widget, with distinct host and widget PIDs. |
| Physical iPhone XR, iOS 18.7.11 | **BLOCKED**. The signed XCTest runner installed and launched. On two attempts it timed out enabling UI automation before any test body ran. |

The independent verifier checked background entry, the host's native detach
and presenter removal, the widget's open and write grants, widget detach before
return, and fresh native attachment before host readiness. The old graph handle
refused reads and its change stream ended. Every readback checked the complete
ID set, the consecutive sequence values, nested array and dictionary values,
decoded Codable values, structural integrity and the digests of both 4 MiB
payloads. The writer sidecar remained and no owners sidecar appeared. The
simulator run establishes its own lifecycle result. Physical iOS 18 stays open.

## Contention and recovery

During the held-write control, the app entered background and the widget
started while the host still had a pending save. The host committed about 1.23
seconds after the widget started, then detached. The widget obtained its
opening grant, committed and detached. The host reopened and read both distinct
changes exactly once with the expected original data and digests. A second
run added an explicit admission probe. A new read received the closed-handle
error after closure began and before the held write committed.

The controlled interruption tests reached native checkpoints on two fresh
iPad fixtures. After entering background, the host received a deliberate
SIGTERM. A new process recovered exactly the two original records in the
before-save case and the two originals plus the one committed record in the
after-save case. Both cold readbacks validated the expected IDs, values and
payload digests.

The natural quarantine tests covered three failed closes, three partial
opens after native attachment and three failures during initialization.
Eight trials captured a deletion or replacement refusal in the transition
before `didEnterBackground`. All nine reached physical background and the
console later reported signal 9. Every fresh process recovered the two
original records and verified values and digests. The cause of signal 9 and
the exact ordering between process exit and independent dry-run grants
remain unverified. No probe removed or replaced a file.

The separate background-budget control requests finite execution time in
the test host before backgrounding. The runtime and widget are identical
to the natural fault build. Both types of dry-run request received a
presenter refusal after `didEnterBackground` while the failed owner was
still alive in all three failure modes. After the budget ended and the host
received a deliberate SIGTERM, both probes received dry-run grants in the
two partial-open cases. The failed-close case recorded the deletion grant.
All three stores reopened with the expected two records. The timing control
exercises background execution with an explicit budget. Natural suspension
remains a separate acceptance condition.

## Evidence

The private simulator and XR manifest verifies 67 files. SHA-256
`54ffd6a123e71b7b68c1b1b872f35815bb1e39b02aa1c56f2624917d68f32af4`.
The private iPad evidence manifest verifies 374 files. SHA-256
`ff0f76c378502d58e8f5ce039090ffe557d22033b439cf6dc6a8ddb81492b377`.
Independent iPad fault and admission verification manifest SHA-256
`88956c77e8a6ae44dd2ad1b1a9e39233e3eea9ff329e1ad46f69168dd38d0475`.

PA02 stays open. The fixture exercises local lifecycle and coordination.
Destructive maintenance, older uncoordinated binaries and live CloudKit
remain separate acceptance work.
