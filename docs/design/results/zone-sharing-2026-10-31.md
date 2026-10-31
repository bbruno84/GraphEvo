# T07 — private zone sharing and participant recovery

Date: 2026-10-31. Development test container; fresh zones/stores, no reset.
This is bounded package-only custom CKSyncEngine evidence, separate from the
historical NSPersistentCloudKitContainer A5/S01 experiments.

## Runtime pins and devices

Owner: connected iPad, maintainer account. Participant: connected iPhone XR,
iOS 18.7.10, a different iCloud account. Private identity/capability handoffs and
raw reports remain in protected external evidence, not the repository.

The first eight stages run library source `02b294e`, verified against all 150
tracked source files after the disposable host's initial archive was patched
before its first build. The ninth stage uses a new clean host exported from
`d5e46935a5c0a5f8adf8e54819735c7124690d38`, without source patching. The final
source adds bounded/corrupt-control refusal, access through the retained graph
lease and single-transaction permission publication; cloud formats are identical.
Do not attribute the original eight-stage matrix to the final source pin.

Each process has a matching launch ticket/PID and active-scene receipt, plus a
separate passed protocol report. Mutation stages are reserved before effects;
none was replayed. Writers remain alive until independent peer observation.

## Nine passed stages

| Stage | Device / replica | Evidence |
|---|---|---|
| identity | XR / peer | Current container-scoped recipient identity; no graph created |
| seed | iPad / owner | Three distinct private zones; A read-write share + file, C read-only share, B private control |
| accept | XR / peer | Both native invitations accepted; exact A/C local and independent cloud inventories, file bytes, empty queues; C writes refused |
| peer-edit | XR / peer | Consumer changes A to 2 and publishes through the shared engine |
| observe-owner | iPad / owner | Independent private-engine import observes A2; B/C remain at 1, no upload feedback |
| owner-edit | iPad / owner | Consumer changes A to 3 through the private engine |
| observe-peer | XR / peer | Independent shared-engine import observes A3; read-only C remains at 1 |
| recover | XR / fresh | New empty SQLite/session files; already accepted invitations inspected and A3/C1 recovered without native store/token copying |
| recover | XR / current | Same independent empty recovery on final `d5e4693`, with exact inventories, file, read-only refusal and empty queues |

All owner zones remain private. The participant's shared-zone inventory excludes
B. Application inventories are exactly two records in A (entity + attachment),
one in B and one in C; shared A/C additionally have their zone-wide CKShare.
Each inventory decodes actual GraphEvoNode records and checks graph identity,
entity content and attachment bytes; local native inventory excludes hidden
roots/membership and is checked for unexpected application primitives. Every
stage checks no sticky session failure, no outgoing receipts and no PH feedback.

## Limits and follow-ups

The fixture exercises entities and an attachment, two participant permissions,
bidirectional edits, process reopen and genuinely empty recovery. It uses explicit
manual synchronization; T06 foreground scheduling retains its own evidence.
This does not certify every graph topology, notification delivery, background,
leave/revoke/purge/reinvite, offline permission changes, account/cache policy,
concurrent invitations, real crash faults or production schema deployment.

Native acceptance, complete local import, local permission enforcement and
independent cloud inventory are separate checks. No claim of global convergence,
distributed migration exclusion or current offline authorization is made.

See the [contract](../graphevo-2-zone-sharing.md) and
[protocol](../../../Experiments/ZoneSharingProbe/README.md).


## Post-review P2 correction check

Source `b171cde0dadd4a4fef1d56ce253a664c20a43087` corrects two findings from the
review of `2463e8f`: ordinary preflight failure consumed creation intent, and a
bounded inbox prefix could hide an access reduction behind malformed app data.
The original two deterministic reproducers failed on that reviewed head and now
pass as committed regressions. Additional cases cover restart after preflight
failure, an ambiguous save retaining intent after restart, disk failure before
the native write, late callback refusal, limits, zone isolation, application
ordering and zone-deletion priority.

A new clean signed host exported from `b171cde` passes three new physical stages:
XR identity, iPad seed/create and XR acceptance/import. Fresh zones and native
stores are used without reset or replay. The owner session contains exactly two
durable creation markers for the two newly saved shares. A read-write entity/file
graph, a read-only graph and an unshared control retain exact local/cloud
inventories, complete file content and empty PH queues; the owner remains alive
through independent participant observation. This is a focused creation/import
recheck, not a repetition of the original full bidirectional matrix on this pin.

Local validation: 731 macOS functions (331 legacy,306 store,71 runtime,23 model),
83 reported selected iOS 18.5 tests, Swift 6 ModelConsumer and manifest/diff checks
pass. Re-review of the corrections finds no remaining blocking issue in the
reviewed paths. Public activation and the broader lifecycle gates above remain
open. Remote CI and merge are still deferred.
