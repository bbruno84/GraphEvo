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
