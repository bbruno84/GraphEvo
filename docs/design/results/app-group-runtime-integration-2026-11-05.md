# Dedicated App Group runtime validation

The reviewed implementation at `61222813` uses the package-only S04 App
Group path. Ordinary stores retain their writer and presence policies.
The fixtures start fresh; they do not adopt an older App Group store or
exercise v1 conversion into this path.

The local v2 macOS profile passed 584 store, 100 runtime and 30 model test
functions. The 64 focused iOS 18.5 simulator tests cover the runtime writer,
App Group cancellation and attachments, participant lifecycle, backup, and
workspace cases. The participant regressions include both live and cold
purge refusal, exact retry after a competing generation clears, and pending
purge after a restart with a missing file and no completion receipt. They
use injected CloudKit transport.

On the same native write and destroy paths at `867dd533`, two independent
macOS processes each committed 25 distinct records on the same store. Cold readback matched all 50 keys with no duplicates. A separate
opener queued on the writer during native purge got `missingStore`. No
SQLite/WAL/SHM or owner claim remained at the purged path, and the adjacent
SQLite digest matched. An independent process killed with a live attachment
left its exact claim in place after cold readback; native purge refused.
The private timing run measured two Apple opening grants at a median of
233 ms, 52 grants on attached stores including close at 1.29 ms, and 50
native saves at 0.63 ms. These small macOS samples are observations, with no
latency target or cross-device comparison implied.

A signed iPadOS 27.0 harness exercises the package's real runtime through a
test-only bridge outside the library. In a controlled interruption after the
writer was acquired and before native detach, SIGKILL left one generation
registered. Cold reopen matched two exact records and their two payload
hashes. Cold purge refused without changing or adding a registration. A
separate fixture with a clean close passed cold purge and had no SQLite,
WAL, SHM or owner claim afterward.

The Xcode UI runner
could not enable automation mode and stopped before the first app/widget
cycle. The device interaction backend available for this run supports
simulators only. The 30 physical app/widget cycles on the integrated
runtime are therefore still pending. The earlier [candidate report](app-group-preintegration-candidate-2026-11-05.md)
retains its own separate physical app/widget evidence.

PA02 remains open. XR physical validation, supported public process roles,
real CloudKit, and production authority to clear abandoned registrations
are separate gates. No remote CI checkpoint was requested.

The follow-up review regression closes the app handle after a peer blocks
purge and before the peer detaches. The app's registration is already gone;
the later purge reopens the same replica and completes. A separate fault
after native destruction verifies that close surfaces the failure and retains
the exact claim until the original owner finishes cleanup. The corrected
runtime passed 715 local macOS v2 test functions and 40 focused tests on
iOS 18.5 Simulator. The physical widget replay remains pending.

## Apple coordination as the only interprocess exclusion

The fresh App Group v2 namespace at `0bb7961e` uses Apple grants for all
coordinated store access. The earlier hybrid namespace stays reserved. The
updated local v2 profile passed 716 macOS test functions and the focused
iOS 18.5 simulator run passed 64 tests. The prepared CloudKit asset case
also verifies that a published batch reopens and its files are removed after
a receipt. A rejected preparation removes its own staged files. Abandoned
staging from a process crash requires separate verified cleanup.

An independent macOS process harness checked two writers with 50 exact records
and a third process that rejected its stale preparation and removed its
staging. A live peer refused the Apple deletion grant. A separate opener
submitted while native destruction had finished and cleanup was still inside
the grant waited, then got `missingStore`. The adjacent SQLite digest stayed
equal and no advisory lock sidecars appeared in the App Group namespace.

On physical iPadOS 27.0, SIGKILL before native detach preserved the exact
two-record inventory and two payload hashes. Cold purge refused and kept the
same registration. SIGKILL after native destruction and before artifact
cleanup left the original registration. The cold harness refused the
remaining SQLite placeholders, so it could not publish a clean purge. A
separate clean purge removed SQLite, WAL and SHM and cleared the registration
without creating advisory lock sidecars. These are native lifecycle checks with
a private bridge. The injected sharing suite separately verifies membership
stays `purging` where cleanup cannot be proved.

On the same iPad, the hybrid baseline `8cd6f90a` and the Apple-only candidate
each reopened six times and committed 150 exact, ordered records. Median
end-to-end reopen was 306.35 ms and 329.75 ms respectively. Median end-to-end
write was 14.46 ms and 13.84 ms. The runs were sequential on one device.

XCTest again stopped while enabling UI automation before starting the 30
physical app/widget cycles. That replay remains the integration gate.

## Reconciliation with backup coordination

[PR #173](https://github.com/bbruno84/GraphEvo/pull/173) was aligned with
`158ae21a` at `ac3ebe04`. Backup publication keeps Foundation catalog
coordination and the App Group path guards. The regression uses an alias
to an App Group directory and a missing descendant. Export, import and
restore refuse the destination without creating files there, and the
source backup still verifies.

The aligned runtime passed 719 macOS and 717 iOS 18.5 simulator tests
in the local v2 profile. A signed iPad build succeeded, but XCTest
timed out enabling automation before the first physical app/widget
cycle. Xcode's interaction tool available to this run accepts simulators
only. The 30-cycle physical gate remains open.
