# V02 — fresh participant replica after voluntary leave

Status: observed **no active A recovery** for the participant during a bounded
three-minute fresh-store run, with the old invitation's public status `pending`
before and after. The owner retained A/B. This verifies the current participation
state under the tested conditions; it does not prove permanent inability to
rejoin using the still-pending invitation.

## Why this check was needed

The earlier [voluntary-leave run](v02-reinvite-leave-2026-10-26.md) showed that
`purgeObjectsAndRecordsInZone` removed A from the XR's existing shared store,
but the owner's `CKShare` still listed the XR. Inspection of those retained
public snapshots showed that the XR's acceptance status changed from
`accepted` (raw 2) to `pending` (raw 1). Participant count alone had therefore
hidden the important status transition.

Case `90B97D91-5F58-4C27-A91C-42096AB12404` used the same owner iPad and
other-account XR, original run
`8A6E6A45-2D7D-44C9-B127-32A552C1F773`, and prior lifecycle case
`88DA5EBE-FBD8-4A71-8B0F-E6D959703807`. The XR opened a **new** private/shared
store pair with identifiers distinct from its original stores. It created no
objects, used no prior probe path, and called neither invitation nor acceptance
APIs. An independent owner process reopened the original owner stores. Both
read the old invitation URL through the public
`CKContainer.shareMetadata(for:)` API before and after their full observation
windows. These are supported sharing metadata reads, not inspection of Core
Data internals.

## Observed application state

| Check | XR participant | iPad owner |
|---|---|---|
| Observation window | 180 seconds, 86/86 snapshots empty | 180 seconds, 85 snapshots with exact A/B5 |
| Old share URL metadata | Matching share/owner/container; `privateUser`, read-write, `pending` before and after | Matching share/container; owner role |
| Share participants from Core Data | No imported A or B | A: owner `accepted`, XR `pending`; B: owner only |
| Local store identity | New private/shared pair, disjoint from the prior pair | Original private/shared pair reused |
| Writes or acceptance | None | None |

No operation, snapshot, metadata-read, event or trace errors were recorded.
The owner-side metadata read reported `ownerMatches = false` for the
`ownerIdentity.userRecordID` comparison while its share ID/container matched
and its role was owner. The XR metadata matched owner, share and container.
This discrepancy was retained without assigning a cause and was not used to
classify the participant status.
Both processes detached stores and were explicitly stopped after final report
retention. The old URL still returned metadata, so this result is **not** a
claim that the invitation ceased to exist. Apple documents that accepted
participants can access shared records, whereas a pending participant must
accept the share before records become available:
[CKShare.Participant](https://developer.apple.com/documentation/cloudkit/ckshare/participant),
[CKShare.Metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata).
The tested XR had pending metadata and no A in its fresh replica. An actual
attempt to reaccept the old URL was not part of this read-only check.

The practical distinction for GraphEvo 2 is between **participant leaves**
(the accepted access and local shared graph disappear in this test) and
**owner revokes** (the owner removes that participant from the share, as in the
[revocation check](v02-revocation-2026-10-26.md)). The application must not
present a voluntary departure as owner-enforced removal from the participant
list. CloudKit does not offer a configurable synchronization deadline, so an
empty bounded replica alone would not prove universal or permanent access
denial; the matching public `pending` metadata is the additional permission
evidence here.

## Provenance

Demo source `f5a182c964d71dc6aafcb1474af186ec8ae09339`, app Swift SHA256
`a755b6d07ca14415fa523c59a04db60b245da4a93bc2d9726f6fa6bb91ab0ffe`.
The app suite passed 88 tests. Xcode 27.1 (27A9275), Swift 6.4 in Swift 5
language mode, GraphEvo pin `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`.
The same signed Development binary, test container, provenance and both device
profiles were verified before installation. No Production resource was used.

Intervals are UTC on 2026-10-26:

| Stage | Interval | Final report SHA256 |
|---|---|---|
| participant-fresh | 09:09:50–09:12:55 | `b6f347ecfcd36fcdaece6a71a262ece9bc867db57893183f97ff8b8c58eb83c7` |
| owner-snapshot | 09:09:50–09:12:53 | `361b850cb026e31590ca069ad5459fcfeb620a42c7529aaf33eb1550d31e5ec4` |

The private evidence archive
`2026-10-26-V02-postleave-90B97D91-5F58-4C27-A91C-42096AB12404` retains
final reports, exact comparison, build/install/stop logs and fresh-store
identities. Account identifiers, the invitation URL and raw reports stay
outside Git. No store deletion, wipe or fixture rewrite occurred.
