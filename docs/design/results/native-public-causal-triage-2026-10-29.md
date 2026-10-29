# Public native adoption — causal triage, 2026-10-29

Status: investigation open; see the later maintainer disposition below. The
maintainer initially requested causes before continuing to app/widget work,
and PR #92 was held as draft. The previous positive functional result is retained,
but neither the historical black screen nor the lost invitation recipient is
closed by later successful runs. No Graph library fix or automatic retry was
selected from an unproven hypothesis.

## Reproduced launch acknowledgement defect

CoreDevice can report launch success, echo requested new arguments in its JSON,
and return the PID of an already-running process. The process retains its old
arguments; application startup and its CLI dispatcher do not run again. This
was first observed with the diagnostic host, then reproduced on both physical
devices using a fresh request UUID: the returned PID equalled the previous
acknowledged PID and the new UUID's on-device receipt did not exist.

This explains missing stage reports for that reproduced reactivation case.
It does **not** establish that the two historical reportless launches were
reactivations. Their driver recorded a separate termination command followed by
launch without `--terminate-existing`; the termination output acknowledged a
signal, not process exit. Those launches did not retain launch JSON/PID binding
or startup receipts. Later process observations alone cannot reconstruct which
request the app actually received.

The disposable host now optionally accepts `--launch-ticket <UUID>` and writes a
payload-free receipt before selecting any probe, then records fixed scene/start
milestones. `launch_probe.py` requests termination of an existing instance and
requires an exact UUID/PID receipt through scene activation. A missing receipt
is a host failure, never a successful Graph stage. No stage is retried, and the
script explicitly distinguishes host acknowledgement from the separate native
operation/report. Positive receipt checks passed on both devices; reactivation
with new tickets produced the expected absence on both.

## Historical black screen remains unexplained

A no-Graph launch with a console reached UIKit's normal main run loop. LLDB
showed `mach_msg2_trap` / `__CFRunLoopRun` / `UIApplicationMain`, with worker
threads idle. Read-only UI inspection showed an active scene and key window;
no Graph operation had been requested. The debugger was detached afterward.
The available same-day jetsam record listed GraphEvo as active/frontmost, but
identified another process as its per-process-limit victim. No GraphEvo-named
crash report was available. These are limited observations, not proof that no
historical crash/hang occurred.

On instrumented disposable hosts, six ordinary instruction-screen launches
(three/device), ten ordinary native diagnostic launches (five owner reopens and
five peer metadata reads), and ten launches using the historical separate
terminate/launch sequence (five/device) all reached an active scene. Two acknowledged-launch checks on instrumented hosts and two on clean,
uninstrumented hosts also passed. No debugger bootstrap was needed.
The historical black-screen/reportless failure was not reproduced. In
particular, a launcher acknowledgement flaw must not be relabelled as a proven
cause of the maintainer's black screen.

## Invitation trace and controlled follow-up

Apple documents the persistence completion as occurring after export finishes;
the API is not simply a local-save acknowledgement. Its sample adds the
participant and calls the same persistence method used here. See
[persistUpdatedShare](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/persistupdatedshare(_:in:completion:))
and [Sharing Core Data objects](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users).
Consequently, the historical owner-only server response after a successful
invitation remains unexpected; waiting for generic export cannot be asserted
as its cause or fix.

An external copy of the library was instrumented at the existing invitation
steps. Only counts, intended-recipient membership booleans and change-tag
equality booleans were logged. No account identifiers, share URLs, record IDs,
payloads or raw tags were emitted by the instrumentation. Native mutation still
used only NSPersistentCloudKitContainer. Extra documented read-only local/server
lookups followed persistence. These reads change timing and can fail separately;
the diagnostic result is not an unmodified consumer success certificate.

A fresh native alpha.2 A6 fixture was seeded once in the approved Development
container, without a reset or modification of previous fixtures. Both first
invitations below used the existing public API, with no re-invitation:

| Checkpoint | Graph A: participant count / recipient present | Graph B: participant count / recipient present |
|---|---|---|
| Initial native share fetch | 1 / false | 1 / false |
| Participant lookup completed | 1 / false | 1 / false |
| After addParticipant | 2 / true | 2 / true |
| Before persistUpdatedShare | 2 / true | 2 / true |
| Native persistence response | 2 / true | 2 / true |
| Local native share readback | 2 / true | 2 / true |
| Owner server share readback | 2 / true | 2 / true |

For both shares the native response had a changed tag, and local/server readbacks
matched that returned tag. XR accepted A on its first attempt and independently
recovered/exported the original exact 10-MiB file. Five owner reopens retained
two accepted participants and the intended recipient on the server; five peer
metadata reads remained accepted. B's first invitation was subsequently readable
as pending on XR, without acceptance or a retry. B was intentionally invited
in this new diagnostic fixture; the previous functional run's B control and
its evidence were not altered.

This rules out a deterministic failure in these two executions, including a
consistent participant loss when setting publicPermission to none or returning
from persistence. It does not rule out native import/export races, stale native
metadata or service behavior in the historical failed execution. The earlier
unknownItem, owner-only server read, identical-capability continuation and
unversioned seed error 134060 remain retained, not retrospectively explained.

## Reproducibility and next closure evidence

The [host guide](../../../Experiments/PublicMirroredProbe/README.md#acknowledged-launches-and-causal-triage)
documents exact launch receipts and `prepare_invite_triage.py`. The latter copies
tracked library sources into a new external directory, applies the checked-in
payload-free trace patch only there, and prepares a disposable host referring to
that copy. The configured demo and shipping library implementation remain
unchanged. A clean, uninstrumented public host also builds with the new receipt
source. Python syntax/preparer checks and diff checks pass. Earlier 513 package
tests and 14 selected sanitizer tests cover the unchanged library implementation;
this follow-up does not claim a new full-suite run or a new sanitizer campaign.
Disposable instrumented source copies, raw logs, launch JSON, private
transports, stores and operating-system records remain outside the repository.
Both devices were finally restored to the clean public host; no instrumented
library build was left installed.

Before closing the historical launch incident, capture a failed launch's exact
request/PID receipt boundary and live stack or termination record. Before closing
the invitation incident, retain a failing attempt's checkpoint sequence and
native/local/server recipient states, with documented error details. Those data
are missing from the original failures and the failures did not recur here.
More successful repetitions alone cannot supply the missing cause. Keep PA03
open and do not promote #92 or proceed to app/widget under a claim that these
causes have been established.


## Later maintainer disposition

The maintainer explicitly authorized waiting for recurrence of the non-reproduced
incidents, fixing the launcher and proceeding. This supersedes the temporary
hold on further work; it does not close either historical cause. The launcher
fix was included in #92, reviewed at d2e095cc71e58308b27b113526ea90137a6c0513 with
both jobs of CI 40937899273 successful, and merged into the consolidation parent
at 7a21bf6ae82022d1f362c6ae39f6dfa9a1ea8175. Retain failure telemetry on recurrence;
no speculative CloudKit workaround or automatic invitation retry was selected.
