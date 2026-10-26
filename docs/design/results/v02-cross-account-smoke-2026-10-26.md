# V02 — private sharing, participant edit and reopening across accounts

Status: the initial direct-framework cross-account control was **observed** on
physical iPad and iPhone XR devices with different iCloud accounts. This is not
completion of V02's full permissions/lifecycle matrix or a final v2 topology.
See the [procedure](../graphevo-2-v02-procedure.md) and
[verification roadmap](../graphevo-2-verification-roadmap.md).

## Configuration and provenance

Run `8A6E6A45-2D7D-44C9-B127-32A552C1F773` used a new synthetic fixture and new
laboratory paths. The maintainer authorized the iPad as owner and the XR as
participant. The owner ran iPadOS 27.0 (24A437); the XR ran iOS 18.7.10 (22H374).
Developer Mode and usable developer services were verified; both devices were
unlocked. No other iPhone was used. Device/account identifiers remain outside Git.

Both devices received the same signed Development binary. Source was demo
`7199135`, with application Swift-source SHA256
`036202fcec89cf963a24d6d4bc689602bf700fe3cd54e73f9b35f9411aa3353c`.
Runtime cloud destination, signed entitlements, embedded source provenance and
provisioning for both devices were checked before execution. The dedicated test
container was unchanged from V01; no Production resource was used.

The toolchain was Xcode 27.1 (27A9275), Swift 6.4
(`swiftlang-6.4.0.34.1`) in Swift 5 language mode, with GraphEvo dependency
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. This differs from the earlier V01
Xcode 27.0 build; source/toolchain provenance is retained separately.

Each side used one NSPersistentCloudKitContainer with separate private/shared
SQLite stores and explicit scope assignments. The direct-framework fixture
reused the experimental root/child model; GraphProvider and public GraphEvo
facades were not initialized or changed.

## Executed stages

The owner created A-root with A-001/alpha and A-002/beta, and B-root with
B-001/gamma, with inverse parent/child links confined to each graph. Both graphs
first received their own owner-only share zones:

| Graph | Zone |
|---|---|
| A | `com.apple.coredata.cloudkit.share.A1A4549C-9103-47EF-A8F3-2825387E95E7` |
| B | `com.apple.coredata.cloudkit.share.EA522E35-A82E-4BBE-B804-0AB0B3C343C3` |

The XR's active account identity was exported to a local sensitive envelope.
Core Data resolved only that account as a participant; the owner added it to A
with private-user/read-write permission and persisted the changed share through
Core Data. Public permission remained `.none`. B retained only its owner.
The private invitation envelope was transferred locally only to the XR.
No email, phone number or Messages delivery was required; account identities
and invitation URLs were neither printed nor committed.

The XR validated container, recipient, owner, share identity and permission
metadata before accepting into its shared store through Core Data. Its empty
run baseline was retained. The completed reader contained exactly A's three
objects in shared scope, no run objects in private scope and no B in either
store. Values, parent/child links, record names, zone names and normalized
share identities matched the owner's A fixture exactly. Owner-relative zone
owner names were normalized using the actual share owner for comparison.

The participant then changed only A-001 to `alpha-from-participant` and saved
once. Its stores remained open for a full 60-second post-edit sampling window.
A separately launched owner-observe process recovered that exact value while
the participant process was still running. All A record/share identities and
relationships remained stable. B's complete member DTOs were unchanged from
owner preparation through owner reopening.

After retaining reports and terminating each process, both sides reopened their
existing stores. Their edited member DTOs matched their preceding snapshots
exactly. Per-side private/shared store identifiers were preserved across stages;
each stage had a new process/stage identifier. No fixture insertion, invitation,
acceptance or edit was replayed. Exactly one stage reported each corresponding
write/acceptance flag.

## Retained reports

All intervals below are UTC on 2026-10-26. Windows were 30 seconds for owner
preparation/invitation, 120 for acceptance/owner observation, and 60 for the edit
and reopening stages. Read stages could finish early on an exact snapshot;
these intervals are not synchronization latency guarantees.

| Stage | Interval UTC | Final JSON SHA256 |
|---|---|---|
| identity | 06:31:42–06:31:43 | `58aa44996f1ef025cd302fd0e92d40c87b05ec2e4ce79c0d0d6df593ee89fffd` |
| owner-prepare | 06:31:45–06:32:32 | `ee0c964737afa875dd06c6718f8a579a77aa4577852bfc18832cf2f2ced2775a` |
| owner-invite | 06:32:45–06:33:22 | `c4053f97837fb8649de2e97ff40cd9bad60e87b85e8d0a745f39187cb7dda751` |
| participant-accept | 06:33:39–06:33:46 | `2edb21d8c5a3421d626ab31610608bc8e44fc7d85e513771e0d5a639ac46f2be` |
| participant-edit | 06:34:13–06:35:15 | `5615849c5cbb9ca229b3405e8a6befefa18857ae82efd5832a0058941f0ef615` |
| owner-observe | 06:34:40–06:34:43 | `ba84cfecc403eb28a445f83c3bf9e34bedaf88ffc83351a66749b176164d70d2` |
| owner-reopen | 06:35:09–06:35:10 | `4f518ed44beed1bce9f821690cc7c1a09046b14771cce1ac8b3056c49f6b24ca` |
| participant-reopen | 06:35:30–06:35:32 | `733454baf35540d6e80f32cec92be12a08d5567e5c83f209b5ec38443377ab4f` |

All eight final reports were retained. There were no stage errors, completed
native event failures, trace-write failures, dropped trace entries or dropped
native event snapshots. Started-only native event snapshots were not treated
as failures. The exact fixture and identity comparisons were performed outside
the app in addition to its stage predicates.

The local GraphEvoLab evidence archive
`2026-10-26-V02-8A6E6A45-2D7D-44C9-B127-32A552C1F773` retains reports, traces,
build/install/transfer/stop logs, a verified build manifest, a comparison summary
and restricted sensitive transport files. All processes were explicitly sent
SIGTERM only after completed reports were copied; console exit 1 follows that
stop. No debugger was attached. No wipe, purge, app removal, store deletion or
cleanup of previous V01 fixtures occurred. Synthetic shares remain for follow-up.

## Validation and limits

The frozen demo implementation passed **56 tests**, including scoped local
persistence, staged lifecycle/side-effect checks, input validation, owner-relative
identity normalization and post-edit observation-window retention. Simulator
checks do not establish sharing; the hardware reports above supply that evidence.
The signed device build succeeded. Subsequent documentation-only edits required
no new runtime test run; whitespace and relative documentation links were checked.

This demonstrates the initial private invitation, acceptance, exact A recovery,
participant edit, owner recovery and reopening paths under these conditions.
Absence of B is an observed negative control for this fixture, not an exhaustive
security proof. The owner observation used a newly launched container after the
edit, so this does not establish live import into an already-open owner container
or background push delivery. Reopening reused local stores; a fresh post-acceptance
cloud replica was not tested. Different devices and OS versions were used together,
so no comparative attribution to an OS version is justified.

Full GraphEvo entity/relationship/action dependency fixtures, read-only enforcement,
offline/concurrent changes, revocation, leaving, account changes, selective download,
zone scale and deletion/recreation remain unverified. The V01 incremental-membership
follow-up also remains separate. V02 and broader R01 remain open.
