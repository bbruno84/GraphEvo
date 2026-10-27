# A4 — actual GraphEvo native membership, 2026-10-27

## Scope and provenance

This is GraphEvo integration evidence using the candidate native model, not a
repeat of V01/V09 with their separate fixture models. The host is a disposable
copy of the configured demo, linked to the working `codex/v2-graph-separation`
checkout. See [the source and procedure](../../../Experiments/A4NativeProbe/README.md)
and [A4 contract](../graphevo-2-graph-separation.md). Physical evidence precedes
this document's commit; no assertion of testing the eventual commit SHA is made.

Owner run: `BC1F6439-450F-44F9-BAF4-42B28D270A59`. Devices: iPad (10th generation,
iPadOS 27.0), and the previously authorized owner's iPhone (same private account,
reachable over the network). The dedicated synthetic Development container was
used without a reset, account switch or invitation. Existing laboratory runs
were not purged. The original demo checkout and its local configuration were
not edited; installation updated its app while retaining app data.

Only synthetic graph/node IDs in `case.json` were transferred to the phone.
No SQLite, native record metadata, history token or invitation was transferred.
The phone's reader stages use distinct newly created local store files and do
not invoke share creation, seed, mutation or adoption.

## Observations

| Stage | Application A/B | Selected owned native rows A/B | Result |
|---|---|---|---|
| iPad seed | 5 / 5 | 34 / 34 | Two owner-only shares, distinct zones; every selected owned row mapped with no zone mismatch |
| iPad fresh initial reader | 5 / 5 | 34 / 34 | Separate local resource imported the fixture; same-device control only |
| iPad mutate, original writer reopened | 8 / 5 | 49 / 34 | Added disconnected Entity, empty Relationship and empty Action; edited an existing Entity; ordinary typed save only |
| Owner iPhone fresh `read-added` | 8 / 5 | 49 / 34 | Full application ID sets/counts, updated label and empty endpoints recovered; B control values/binary/tags/groups and structure retained; no pending/mismatched mappings |
| iPad delete, original writer reopened | 5 / 5 | 34 / 34 | All three added members deleted; B retained and remaining owned rows mapped into distinct zones |
| Owner iPhone fresh `read-deleted` | 5 / 5 | 34 / 34 | Full application ID sets/counts exclude added IDs, existing edit retained, B retained; no pending/mismatched mappings |
| iPad repeat preparation | 5 / 5 | 34 / 34 | Both preparation calls reused their pre-call share/zone identities; imported async share-persistence API completed |

The initial independent phone reader also reported 5/5 and 34/34, but it used
an earlier probe oracle that checked selected expected IDs rather than the
complete application ID set. Its scheduling overlapped the owner mutation.
It is retained as preliminary, not used as the decisive independent initial
baseline. The later reader oracle checks the complete ID set and count before
passing; added/deleted recovery evidence above uses that stronger oracle.

The native membership enumeration includes roots, hidden membership Actions,
application nodes and their owned property/tag/group rows. The original native
schema and hashes were unchanged. No additional explicit share call assigned
the three late members. These owner-private observations must not be generalized
to participant insertion; earlier V02/V09 evidence showed a distinct assignment
procedure was required there.

## iOS 18 owner-private smoke

A separate run `4CF6125F-27A9-4A65-A7EE-3BF1F11E651F` uses the connected iPhone
XR on iOS 18.7.10 and its different iCloud account. It sends no invitation and
creates synthetic personal graphs in that account. Seed, reopen/mutate and
reopen/delete observed A/B 5/5→8/5→5/5 with native owned-row counts
34/34→49/34→34/34, no pending mappings and no zone mismatches. The inserted
Entity/empty Relationship/empty Action used normal typed save only. This is an
older-OS owner-private smoke, not cross-account sharing or independent-device
recovery for the XR account.

## Interpretation and limits

The selected membership links can carry two personal GraphEvo graphs, including
cycles, details and disconnected/empty structures, through owner-private native
share zones and independent recovery. This is a positive implementation path
for A4, with an observed 5→8→5 lifecycle and unchanged B control.

Native opening, local commits, share callback/persistence completion, local
record mappings and remote application recovery were checked as separate facts.
The probes poll for current state; they do not prove live invalidation in an
already-open UI or infer transaction causality from Persistent History.

This run does not certify private/shared multi-resource ownership, invitations,
participant writes, automatic recovery after ambiguous share creation, coordinated
v1 cloud cutover, offline concurrent writers, account changes, zone quotas,
selective graph downloading or arbitrary legacy value conversion. Boundary
identities were explicitly compared before/after repeat preparation; the probe
did not persist identity pins before every earlier lifecycle stage. B's control
checks are representative values/structure and the full ID set/count, not a
byte-for-byte comparison of every field and timestamp. Native mapping coverage
is for the adapter's selected owned rows, not a certification of every possible
unrelated/orphan row in an arbitrary damaged store.

## Local verification

The final source also adds catalog separation/lifetimes, explicit A3 upgrade and
backup-failure regressions, native-operation writer/drain/cancellation checks and
an external Swift 6 product consumer with `MemberImportVisibility` when supported.
Final local results: 412 tests passed (322 legacy, 49 runtime, 23 store/adoption/
catalog, 18 model/mapper), ten focused tests passed under Thread Sanitizer, the
external Swift 6 typed/catalog consumer passed with MemberImportVisibility, and
signed demo builds passed. The first broad run exposed an A4 comparison that
incorrectly included the original URL spelling for already-canonicalized keys;
the existing case/symlink alias controls caught it. Compatibility now compares
access/schema/cloud identifier after canonical key resolution, and the final
full suite passed. Affected controls were not disabled or weakened.

These local tests remain distinct from hardware CloudKit evidence. Raw device
logs, case envelopes and store files remain outside Git.
