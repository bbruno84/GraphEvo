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
