# V02 — reinvitation and participant-initiated leaving

Status: **partial functional result**. Reinvitation, pending acceptance and
exact A recovery succeeded. Participant-side leaving removed A through the
public shared-store purge API. Owner A/B data remained intact, but the owner's
public share snapshot still listed the participant at both bounded checks.
The complete owner-only post-leave condition is unverified.

## Public API procedure

The [initial V02 fixture](v02-cross-account-smoke-2026-10-26.md) had already
undergone [revocation](v02-revocation-2026-10-26.md). The owner iPad
(iPadOS 27.0, 24A437) started with A and B intact, distinct owner-only shares,
and the original stores. Case `88DA5EBE-FBD8-4A71-8B0F-E6D959703807` reused
run `8A6E6A45-2D7D-44C9-B127-32A552C1F773`. The XR participant used its
original private/shared stores, never the consumed read-only probe.

The owner resolved the same authorized account, added it with private
read-write permission to A's existing share, and called
`NSPersistentCloudKitContainer.persistUpdatedShare`. A remained in its
original share/zone with all A/B values and identities preserved; B stayed
owner-only. A new case-bound invitation envelope was transferred outside Git.

The XR initially had zero A rows. Its invitation metadata was **pending**;
`acceptShareInvitations` was called once into its explicit shared store. It
recovered A-root, A-001 and A-002 with exact links, record/share identities
and A-001=`alpha-from-participant`, while B was absent. Both original XR
store identifiers were reused.

The XR then confirmed the complete three-object fixture and participant role,
and called `purgeObjectsAndRecordsInZone` for A's zone with the explicit
**shared** persistent store. The API returned that zone without an error.
A went from three rows to zero in that same store pair and remained absent
through the 60-second window. No owner-private purge or owner deletion ran.
Apple describes this API as the path by which a participant stops
participating and deletes its local shared object graph:
[Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users),
[purgeObjectsAndRecordsInZone](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/purgeobjectsandrecordsinzonewithid%3Ainpersistentstore%3Acompletion%3A).

## Owner observation and decision limit

The first fresh owner process observed for 30 seconds after the XR purge;
a second fresh owner process observed for another 120 seconds. Both retained
all five exact A/B objects, values, links, record and share identities on
the same owner stores. B's public share remained owner-only. A's public
`CKShare` snapshot retained two participants, rather than the expected owner
alone, at the end of **both** windows. The lab reported its unmet
postcondition as `V02Error:5`; it did not repeat invitation, acceptance,
purge or object deletion.

This is an observed limitation of the tested workflow. It does not show that
the XR still has access after its local purge, nor establish a deadline or
explain how the framework updates the owner's participant list. The
[Apple sharing guide](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
describes stopping participation but specifies no deadline for owner-side
share metadata visibility. A future application flow must avoid claiming
confirmed removal from the owner list solely from the participant's purge
callback or local absence.

## Provenance and retained evidence

Demo source `dec15fed83bfcc14faf29291b5009d04c1e8e088`, Swift source SHA256
`089c6b4dc3efe7da0c16e3776269800c9190f11a5fdade8e8eae4b7ca2c5116b`.
The app suite passed 83 tests. The physical build used Xcode 27.1 (27A9275),
Swift 6.4 in Swift 5 language mode, and GraphEvo pin
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. Signed Development
entitlements, test destination, source provenance and provisioning for both
devices were verified before installation.

Intervals are UTC on 2026-10-26:

| Stage | Interval | Final report SHA256 | Result |
|---|---|---|---|
| owner-reinvite | 08:10:34–08:11:41 | `fe292208471928210d48cddea286853b26ab724847ab9c6f8e5ab0ece600c0ae` | Share persisted; A/B retained |
| participant-reaccept | 08:12:41–08:12:49 | `6c2def36965f26b67d1245457d18eebd99fee2cd1f2f105a3017f1c80d88cc15` | Pending invitation accepted; A3 exact, B absent |
| participant-leave | 08:13:05–08:14:09 | `e8be392ba88c45822127d6d30aae82b5467329a9e9ff985339c35cb03e7964ed` | Shared-store purge returned; A3→A0 |
| owner-verify-leave | 08:14:17–08:14:52 | `2d4889d79cc2fea731ef26876d3d33fbe45b0b93500c2b747a2d8d3e3fb1cd24` | A/B retained; A list still two |
| owner-verify-leave retry | 08:15:48–08:17:50 | `56b1bcb72f36bcc92dc869bc44c49e7579d4a28b354792a24c62d56286e7f23e` | Same public result after longer window |

The first three stages had no errors. Both owner verification reports explicitly
retain the failed owner-only precondition. All five final reports were retained;
store detach and process termination were explicit. Event/trace drops and
trace-write failures were zero. Comparison against complete object values and
identities is in the private archive
`2026-10-26-V02-lifecycle-88DA5EBE-FBD8-4A71-8B0F-E6D959703807`.
The invitation and account data remain outside Git. No fixture rewrite, wipe,
store deletion or Production resource was used.
