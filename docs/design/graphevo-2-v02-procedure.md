# V02 — initial cross-account sharing control

Status: initial control observed on 2026-10-26; see the
[cross-account result](results/v02-cross-account-smoke-2026-10-26.md).
This is the first bounded control within [V02](graphevo-2-verification-roadmap.md),
not acceptance of its full permission, lifecycle or conflict matrix.

## Question and prerequisites

Can an owner share only graph A with a different iCloud account, recover its
complete fixture in the participant's shared store, and receive a subsequent
participant edit while graph B remains private to the owner?

The maintainer authorized the physical iPad with the owner account and an iPhone
XR with a different account. The XR reports iOS 18.7.10; the iPad reports iPadOS
27.0. Device identifiers, account identities, invitation URLs and provisioning
remain outside Git. Verify Developer Mode, unlocked state, provisioning, runtime
container and signed Development entitlements before installing or launching.
Use only the already authorized dedicated test cloud container. No wipe is
required or planned. Do not use the other iPhone for this experiment.

The [V01 T6 result](results/v01-t6-independent-reader-2026-10-24.md) established
same-owner recovery of separate owner-only zones. It did not establish sharing
between accounts. The proposed V01 follow-up for incremental graph membership
also remains pending; a participant edit here does not replace that full check.

## Framework boundary and fixture

Use a separate direct-framework laboratory path, not GraphProvider or changed
GraphEvo library APIs. Each device opens one NSPersistentCloudKitContainer with
separate private and shared SQLite stores, the same model and cloud identifier,
and different database scopes. Explicitly assign new owner objects to the private
store and restrict diagnostic reads to each affected store as well as the run.
Native event notification posting must return without waiting for MainActor.

Use a new run identifier and isolated local paths. Create disconnected graphs A
and B with deterministic roots, children, values and inverse links; no global
catalog or cross-graph relationship. Retain their exact fixture and identities.
Share A with the authorized participant using read-write permission; keep B
owner-only. Public permission must stay `.none`. Use Core Data's supported share
creation, participant lookup, share persistence and invitation acceptance APIs.
Do not create or modify application CKRecords directly or inject custom zones.

The invitation path must identify only the authorized XR account. Use supported
system sharing UI or a documented custom flow; any account lookup material and
share URL exchanged locally must remain outside reports, console logs and Git.
Acceptance completion is distinct from imported data completeness. Missing rows
or mappings at the end of a bounded window are inconclusive, not proof of privacy.

## Stages and expected observations

1. **Participant preflight:** verify the XR's active account and signed cloud
   configuration. Retain a baseline from both stores before acceptance. Do not
   seed any owner fixture on the participant.
2. **Owner preparation:** persist a new A/B fixture on the iPad, create distinct
   owner-only shares, then privately invite only the XR account to A. Retain
   native outcomes, exact membership and permission state. B must have no
   non-owner participant.
3. **Participant acceptance and recovery:** accept A into the shared persistent
   store. Fetch the entire run from both stores. Require exact A values and
   relationships in shared scope, no A owner copy in participant private scope,
   and no B in either participant store. Compare cloud record/share/zone
   identities across accounts; owner-relative zone owner identifiers may differ
   in representation and must be interpreted explicitly.
4. **Participant edit:** modify one existing A child with a deterministic new
   value using its owning context/store. Save once; do not replay an edit on
   timeout. Keep the remaining A members as controls.
5. **Owner observation:** read from a fresh context until the participant's
   exact edit is retained, while B's fixture and zone/share boundary remain
   unchanged. Native export/import events support diagnostics but do not replace
   exact comparisons.
6. **Relaunch:** terminate only after retaining reports, reopen the existing
   laboratory stores, and verify the accepted share and edited fixture. Reopen
   must not insert fixtures, create shares or reissue invitations. Distinguish
   durable local reopening from a separately tested new cloud replica.

Each stage records source hash/revision, OS/toolchain, scope/store inventory,
timestamps, native errors, exact synthetic fixture, identity mappings and
permissions without participant personal details. Use bounded observation
windows, immutable report snapshots, and explicit process termination. Retain
partial reports separately from completed evidence. Preserve all prior V01 data.

## Limits and subsequent checks

This minimal root/child control does not certify GraphEvo entities, relationships
or actions. Full dependency traversal and those facades require later fixtures.
Read-only enforcement, offline and concurrent edits, revocation, participant
leaving, account changes, selective download, zone scale and deletion/recreation
remain separate tests. Do not report V02 or R01 complete from this control.

## Apple references

- [Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users): private/shared stores, custom sharing flow and lifecycle.
- [Accepting share invitations](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/acceptshareinvitations(from:into:completion:)): acceptance into the shared persistent store.
- [Fetching participants](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/fetchparticipants(matching:into:completion:)): participant lookup through the owning persistent container.
- [Persisting updated shares](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/persistupdatedshare(_:in:completion:)): keep share changes and local metadata aligned.
