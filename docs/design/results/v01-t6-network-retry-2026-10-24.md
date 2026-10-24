# V01 T6 — repeat after reported network recovery

Follow-up: [iPad diagnosis](v01-t6-ipad-diagnosis-2026-10-24.md) reproduced and
fixed the laboratory observer wait cycle, then observed two owner-only zones
and fresh same-device recovery. This historical repeat remains inconclusive.

Status: **inconclusive**. After the maintainer reported that the network appeared
operational again, the same frozen T6 implementation was run with a new fixture
and local store, without a debugger. The first share stage again retained no
completed result within the bounded observation. This does not establish the
cause of the wait or demonstrate native rejection of owner-only shares.

This is a follow-up to the [original T6 attempts](v01-t6-2026-10-23.md), not a
replacement for them. The filename uses the maintainer's local date, October 24
in Europe/Rome; timestamps below are UTC on October 23.

## Controlled configuration

- New run: `710BC717-0682-4277-8130-2E4FD72937AF`, with a fresh SQLite path.
- Same signed binary and source: demo
  `fdf4d6b0499c832260405f44b0ba0ac2a82c49b8`, app Swift-source SHA256
  `b477e5a6bf7d868ff80338a5515b9c9990d7ebfdf8f8c9c7cbd815e92f5f42f9`.
  Source hash, embedded provenance, authorized cloud destination and signed
  Development entitlements were reverified. Both devices received that binary.
- Same physical iPhone and private scope, model and fixture as T6: two
  disconnected roots with three children, optional inverse relationships,
  one new share requested per root, no additional participants or invitations.
- The iPhone was unlocked; the maintainer also unlocked the iPad for a possible
  reader stage. The iPad reader was never launched because the writer did not
  reach the required share-creation evidence.
- No code change, debugger attachment, custom zone, direct CKRecord write,
  fallback, wipe or schema reset was introduced. The previous 41 passing local
  tests apply to the unchanged implementation; they were not rerun or counted
  as cloud evidence for this repeat.

## Observed sequence

The writer started at 22:21:54. It saved all five fixture objects. Its retained
initial setup, import and export events completed successfully. Initial object
mappings remained in the ordinary private zone without share associations.
These are useful control observations, not proof of share creation or a full
network diagnosis.

The checkpoint immediately before requesting share A had device modification
time 22:21:57. At 22:27:16, 319 seconds later, the retained report still had:

- `fixtureSaved = true` and five initial members;
- lifecycle `Requesting a new owner-only share for root A`;
- `shareOperations = []`, `errors = []`, and no finished timestamp;
- outcome `Running; not completed evidence`.

After retaining that checkpoint and confirming the process was present, the
coordinator explicitly terminated the writer with SIGTERM. Console exit 1
reflects this intentional stop. The original running JSON was left unchanged;
an external summary records the end of observation. Share persistence, share B,
the 120-second post-share sampling window, and the independent reader were not
reached.

As in the original T6 attempts, callback entry is not independently traced before
metadata conversion and returned-object lookup. The evidence therefore cannot
localize the wait to the native API versus subsequent callback-result processing.
Neither an empty error array nor the absence of a completed report proves success
or rejection. No reliable conclusion can be drawn about unconfirmed remote side
effects of the pending operation.

## Evidence and implication

Incomplete checkpoint SHA256:
`68e801e6bde2151f9e79cad6e5a869894b8ddb3a9856b18a1d248f39c8c5a4f1`.
The original checkpoint, source/run manifest, installation and console logs,
device report metadata and external summary are retained outside Git in the
local GraphEvoLab archive for `2026-10-24-T6-network-retry`. Personal resource,
device and provisioning details are not committed.

The share-stage wait recurred after reported network recovery. That observation
does not establish a network cause, exclude every network issue, or prove a
framework bug. R01's owner-only share-zone candidate remains unverified. The
next useful work is focused share-stage tracing and system-log diagnosis rather
than more blind fixture creation. No local stores or remote records were deleted,
and no invitation or merge was performed.
