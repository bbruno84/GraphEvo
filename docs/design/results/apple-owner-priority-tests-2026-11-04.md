# Apple owner pre-integration priority results — N

2026-11-04. **NO GO for production adoption.** The
[selected protocol](../graphevo-2-apple-owner-test-protocol.md) is exercised in
a separate private laboratory on integrated `3638bc4e`, using the actual S04
model and Graph adapters with the retained-owner prototype. The shipping lock,
public API, schema and CloudKit accounts remain unchanged. H02 and its stores
are excluded. No remote CI is requested.

N extends the [M/M2 experiment](apple-owner-coordination-2026-11-04.md).
K/L/M/M2 evidence, including their failures and limitations, remains historical.
Positive N results do not authorize a production lock substitution or close PA02.

## Priority gates

| Gate | Result | Scope |
| --- | --- | --- |
| Partial opening and failed cleanup | PASS on macOS | Three repetitions of existing-store after-add/initialization failure and constructed failed detach; three fresh-store repetitions per opening fault. Actual native owners and presenters remain retained. Independent deletion/replacement is refused until verified cleanup. |
| Physical failure/background recovery | BLOCKED | iPad foreground after-add quarantine and controlled-termination recovery are observed. The Mac locked before the intended Home/admin probe; physical background and other fault stages are unverified. |
| Thirty physical lifecycle cycles per OS | PARTIAL | Thirty iPadOS 27 cycles pass. XR iOS 18.7.11 interaction is blocked by Device Hub's iOS 27 screen-sharing requirement on this Mac. Prototype observation remains a surrogate. |
| Async work and attachments | PASS on macOS | Three repetitions each of real Task cancellation during preparation, coordination wait, native edits, before save and after save. Rollback/committed results, exact content and prepared-file cleanup pass. Physical interruption remains unverified. |
| Synchronization lifecycle | PARTIAL | Actual manager/session/disk and backup leases pass repeated stop/reopen, checkpoint and retired-callback checks with injected private transport. Coupled outbox/ack/account transitions under the retained owner remain unverified. |
| Independent physical app/widget processes | PARTIAL | iPad ordering and native readback pass. XR is signed, installed and launched; no physical widget cycles are established. |

## Deterministic evidence

The final macOS matrices contain **29 and 22 PASS controls**. They cover actual
native quarantine after opening/cleanup failures, thirty logical lease cycles,
real cancellable file preparation and pre/post-save outcomes. A common two-phase
shell/load factory retains failed native owners for both foreground and
operation-bound paths. Ordinary retained writes reuse the same native stack.
The earlier operation-bound preparation branch is synthetic; the additional
retained-owner controls use real Swift Task cancellation.

Administrative refusals have the expected presenter error, with no entry into
the destructive native body. A committed write remains committed when subsequent
cancellation or cleanup failure occurs; no arbitrary body is replayed. The
fixture retains serialized array/dictionary/Codable values and two 4 MiB Graph
attachments with exact byte counts, identities and digests.

Thirty strengthened disk cycles keep strong references to stopped sessions:
lock release follows awaited stop, rather than actor deallocation. They check
retired callbacks immediately before the next state update, callbacks after stop,
restored state, exact inbox growth and actual session/backup lock release.
The real directory leases are exercised inside the physical App Group too.
The **99 passing existing adapter tests** are separate baseline evidence for
session, transport, account, pause, observation, attachments and backup; they do
not establish coupling to the new presenter lifecycle.

## Physical iPad result and retained incomplete attempts

On iPadOS 27.0 / 24A437, all thirty actual Home/widget/app cycles pass with
host PID 9741 and widget PID 9739. Every widget grant follows an actual
background notification after the preceding ready state. Independent native
readback verifies counters 1–30, exact record IDs, complex values and both
4,194,304-byte attachment bodies. Old leases refuse reads and the old surrogate
stream ends; a new lease reads the peer's write.

All collected checkpoints have zero dropped frames. Ordering is:
app native detach → presenter removal → widget grant → widget native detach →
coordination completion → checkpoint immediately before intent return. Normal
session/backup locks release. Stable processes and the collected crash inventory
show no new normal-path termination in this observation window; they do not
certify a particular suspended state, indefinite execution or future OS behavior.

An interim iPad run reached twenty correct values, but repeated pause callbacks
overwrote the same report filename. Preserve it as value/liveness evidence only.
Unique checkpoint ordinals correct the instrumentation; the final thirty-cycle
run uses a new fixture. No runtime lifecycle change was needed for that fix.

An earlier macOS launcher timeout also stopped a logical-cycle run at twenty
intact commits. It is retained separately from the successful final bounded
run; it is neither an observed OS termination nor evidence of deadlock.

The physical after-add fault reached foreground quarantine. The subsequent
explicit SIGTERM and cold read-only restart recover counter 0, the four original
IDs and exact content. This is controlled recovery evidence. Home/admin refusal,
failed-close background behavior and pre/post-save device interruption are not
proven by it. The XR interaction blocker concerns the automation tool, not an
observed library failure or a changed OS support floor. No OS upgrade, new
provisioning or simulated suspension substitutes for that missing matrix.

## Bounded costs

Three repetitions per topology, fifty writes per process, **450 verified timed
commits**. These are small-fixture batch wall times, not individual latency or
a large-store performance envelope.

| Workload | Historical final M2 median | N final median |
| --- | ---: | ---: |
| One process, 50 writes | 503.73 ms | 562.56 ms |
| Two processes, 100 writes total | 1,827.20 ms | 1,879.39 ms |

The M2 measurements are historical with matched fixtures, not a contemporaneous
paired causal comparison or statistical regression proof. All nine N process
traces show exactly one native opening and detach per lease. Initial native
open/bootstrap timings are copied into operation samples; they do not represent
repeated opens. Owner open/close, body/save and request timing outputs remain
distinct. Operation samples include total time; coordination wait is inspected
from submission/grant trace timestamps, not a dedicated M2 JSON wait field.
No arbitrary acceptance threshold is inferred.

## Review and remaining work

Private `REPORT.md` SHA-256:
`89a797e4649042ca188219e640454ec1d87b553a9fd28a33983da5775d2d0be8`.
Private `Evidence/final-checksums.json` SHA-256:
`8df073d83690489c0e23e5fffb0ae10d29a0f7569ae35c3a70ea5af6924274f7`.

Independent review reruns the deterministic verifier, checks all final manifest
artifacts (2,931), recomputes medians, inspects cancellation classification and actual
presenter refusal causes, and checks native opening counts from raw traces.
It also verifies the complete physical ID/content/ordering evidence and the
actual background event between each preceding ready state and widget grant.
The original M/M2 report, manifest and its 32 artifacts remain unchanged.
The experimentation chat reviews this summary for fidelity; its scope clarification
is incorporated. Review also corrects the private report's timing description
without changing any executed code, test, benchmark or device evidence.
Raw stores, source archives, device journals and signing material remain private;
live native copies are diagnostic snapshots, not certified backups.

Complete the physical fault/background matrix, obtain a supported physical
interaction path for iOS 18, and couple the real outbox/ack/account and public
observation lifecycle to the retained owner in the private laboratory. These
priority gaps block production adoption. The protocol's deferred layout,
migration-workspace and broader platform acceptance remains pre-beta work.
