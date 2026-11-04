# H02 — public sharing through the coordinated context

Status: proposed contract, 2026-11-04. No H02 implementation or acceptance is
claimed. Base: integrated H01/#151 (`a1097ff1`) and companion demo PR #2.
Read with [H01](graphevo-2-public-entry.md), [T07](graphevo-2-zone-sharing.md),
[T08](graphevo-2-sharing-lifecycle.md),
[account isolation](graphevo-2-cloud-account-isolation.md) and the
[release checklist](graphevo-2-post-alpha-checklist.md).

Research update: [native GraphID discovery](results/public-sharing-graph-discovery-2026-11-04.md)
shows that Apple's standard invitation can support onboarding without the
separate capability file proposed below. A fixed zone identification record is
recommended for bounded lookup including empty graphs; it is not implemented.
The capability-only transport and corresponding acceptance signatures below
are the initial proposal, not a selected requirement. Revise them around native
acceptance/discovery after protocol review. No identity secrecy requires the
separate file, and the two-step demo exchange is not the recommended final UX.

## Outcome and ownership

An external Swift 6 application can invite a selected participant, accept the
invitation into an explicit local replica, inspect permissions, remove a
participant, stop sharing or leave. Applications use their existing GraphContext,
GraphCloudConnection and GraphStore. There is no singleton, second synchronization
manager, per-graph engine or public Core Data/native transport handle.

CloudKit remains responsible for sharing authorization and acceptance. The owner
keeps its graph in a private custom zone; participants use that owner's zone in
the shared database. The manager allocates its shared engine only when required.
Public access means library API availability; CKShare.publicPermission stays none.
The native schema, logical payload and session formats are unchanged unless a
separately reviewed implementation necessity is demonstrated.

## Apple integration and invitation boundary

Apple provides [zone-wide sharing](https://developer.apple.com/videos/play/wwdc2021/10086/)
and [share metadata callbacks](https://developer.apple.com/documentation/cloudkit/ckshare/metadata).
These identify the native share. Our existing T07 protocol also needs GraphID;
that library identity is not inferred from a share title, local filename or a
zone-name convention. This is a GraphEvo protocol constraint, not an Apple limit
on application-defined discovery.

The first public increment retains the existing invitation capability: container,
environment, GraphID, owner, recipient, zone name and Apple's share URL. The host
transports the complete capability through an authenticated/protected channel
and selects the local file. It contains no local paths or application payloads.
No custom network authorization, user directory, identity lookup by email/phone,
public-link access or server-side invitation registry is introduced.

Expose an opaque Codable/Sendable recipient identity obtained from the verified
connection, rather than requiring applications to construct CloudKit record-name
strings. Invitations are opaque Codable/Sendable values with a readable GraphID;
decoding does not certify authenticity or access. Validate bounded fields before
local changes and independently check live metadata, current recipient, container,
environment, zone, owner, role and permission before acceptance. Native CloudKit
checks remain the authority. Never log recipient identities, invitations or URLs.
Publish the encoded capability's size/format limits with the implementation.

Apple's [standard sharing UI](https://developer.apple.com/documentation/cloudkit/shared-records)
remains the preferred candidate for a later presentation adapter. Passing a
mutable CKShare to UICloudSharingController/NSSharingService needs a defined
admission, reconciliation and durable-intent boundary; it must not bypass T07/T08
by adding an independent writer. This increment supplies explicit-recipient
operations and a demo transport, not a claim that a bare Apple URL can bootstrap
an unknown GraphID. A callback may resume a known invitation after exact matching;
an unknown URL/metadata callback must report that the GraphEvo capability is
required, without creating a replica. Native UI/URL-only onboarding remains an
explicit B-gate decision, not silently deferred beta work.

## Proposed public call shapes

All additions target iOS 17/macOS 14 and remain in the GraphEvo product. Names
below are proposed signatures, not implemented declarations. Supporting values
have documented consumer fields and initializers where construction is meaningful;
runtime routes, membership journals and native share archives stay internal.

```swift
extension GraphCloudConnection {
    func sharingIdentity() async throws -> GraphCloudParticipantIdentity
    func inviteParticipant(_ recipient: GraphCloudParticipantIdentity,
                           to graph: GraphStore,
                           permission: GraphCloudSharePermission = .readWrite)
        async throws -> GraphCloudInvitation
    func acceptInvitation(_ invitation: GraphCloudInvitation, at storeURL: URL)
        async throws -> GraphStore
    func participants(in graph: GraphStore) async throws -> [GraphCloudParticipant]
    func setPermission(_ permission: GraphCloudSharePermission,
                       for participant: GraphCloudParticipantIdentity,
                       in graph: GraphStore) async throws -> GraphCloudSharingStatus
    func removeParticipant(_ participant: GraphCloudParticipantIdentity,
                           from graph: GraphStore)
        async throws -> GraphCloudSharingStatus
    func stopSharing(_ graph: GraphStore) async throws -> GraphCloudSharingStatus
    func leaveSharedGraph(_ graph: GraphStore) async throws -> GraphCloudSharingStatus
    func sharingStatus(for graphID: GraphID) async throws -> GraphCloudSharingStatus
    func observeSharing(for graphID: GraphID)
        async throws -> GraphObservation<GraphCloudSharingStatus>
    func refreshSharing(for graphID: GraphID) async throws -> GraphCloudSharingStatus
    func registerSharedReplica(id: GraphID, at storeURL: URL) async throws
}
```

GraphStore parameters prove ownership by the same context before manager/native
operations. GraphID-only status/recovery operations require an exact membership
in this connection's namespace and are usable after local removal. No arbitrary
graph, foreign container or resource may be inspected or purged by ID alone.
Read-only participant identities may be absent in native participant snapshots;
do not invent identifiers to make entries editable.

Extend H01 pause/resume eligibility from private routes to exact private OR
shared routes in the same connection. Do not expose the entire internal manager.
All operations preserve per-graph/scope exclusion, independent connection leases,
context-owned foreground state and final-close drainage. Connection readiness is
necessary for native operations, not permission or graph completeness. Locally
journaled status and supported local leave/recovery must remain available when
transport is temporarily unavailable but the same account/session is verified;
do not impose a new successful network preflight on offline leave. An isolated
account is never bypassed by these controls.

## Invitation, acceptance and restart

Invitation creation requires an owned, private-bound eligible graph and verified
account. Preserve the durable T07 create marker and metadataPending after an
ambiguous create. Never create a second share as a retry. A returned invitation
does not certify export of pending graph writes.

Acceptance validates the capability, immutable route, URL and context claims
before making persistent account/participant changes. Use an explicit absolute
SQLite URL as in H01. A fresh request creates only an absent target. Retry may
resume only the exact durable joining generation, native store identity and
untouched target; reject nonempty, foreign, replaced or mismatched resources.
Preflight errors must leave an unrelated local-only graph unchanged.

Return a GraphStore after native acceptance and local access metadata commit.
It may contain no records yet. Acceptance, readable access, imported content and
peer convergence are separate facts; no fake download percentage/completion
certificate is introduced. An interrupted acceptance may have committed remotely
before throwing: keep the intent, retry the same capability and inspect native
acceptance rather than replaying it. Do not erase the target on error.

On restart, the host restores its saved GraphID/file selection and connection.
`registerSharedReplica` registers only an existing journal membership's exact
current URL for control recovery without granting application access or creating
a missing store. It must support interrupted purge, including already absent
native files, under T08's identity guards. Then normal `context.openGraph`
restores participant access checks; incomplete joins resume via the same
invitation. Cold participant data stays blocked until account and membership
checks satisfy the existing contract. Account monitoring remains independent of
transport; closing a connection never converts a shared replica to local-only.

## Permission, observation and destructive operations

| Event or operation | Required behavior |
|---|---|
| Read-only permission | Keep readable replica/imports; reject consumer writes before invoking their body; retain outgoing backlog. |
| Permission restored | Make retained work eligible subject to account, pause and migration gates. |
| Temporary/offline inspection failure | Report accessUnverified under existing cache policy; never interpret it as confirmed revocation or authorize deletion. |
| Owner removes participant | Change only the private CKShare; participant loss is acted on when confirmed, not instantaneously while offline. |
| Owner stops sharing | Delete only the owner's CKShare; retain owner graph/records and unrelated graphs. |
| Participant leaves | Persist terminal intent, block all local handles, drain and destroy the exact owned replica and unsent work; retain a pending remote leave when offline. |
| Confirmed access loss | Apply T08 terminal purge; no application delete mutations or uploads of abandoned changes. |
| Reinvitation | Require completed old cleanup/remote leave and a new joining generation; old handles never revive. |

The host obtains user confirmation before invoking leave or stop-sharing actions.
The library performs the explicit requested operation without another UI prompt.
Leave destroys owned attachment content, PH, queued/frozen work, inbox and receipts.
Consumer-created exports/backups remain outside library ownership. Network errors,
quota errors, account loss and read-only downgrade alone never trigger this purge.
Account loss retains the separate isolation policy and does not impersonate leave.

Status exposes graph/membership generation, role, phase, permission, removal reason,
remote-command-pending and bounded diagnostics. Preserve joining/active/
accessUnverified/leaving/purging/removed semantics. `removed` with a remote command
pending means local deletion completed, not that the server command completed.
Statuses do not retain a GraphStore lease or certify current server authorization.
`active` describes membership, not synchronization completeness.

Observations deliver initial/newest state, are cancellable, and finish when their
connection lease closes. They are live state, not durable event replay. Purge
invalidates all resource handles and snapshots/queries must surface access loss;
hosts clear previously cached values, which the library cannot recall. Account
epochs, membership generations and existing permission checks govern any race
between a UI action and a delayed callback.

Typed errors distinguish invalid capability/recipient, foreign ownership,
nonempty target, metadata pending, busy/paused, isolated account, permission,
superseded command and recovery/cleanup failure. Pending durable remote commands
are reported in status even when an operation returns successfully. Cancellation
cannot conceal committed leave/acceptance intent, abandon cleanup or release a
failed native claim; retries recover that intent rather than replaying application
bodies. Preserve the original error plus queryable durable status where applicable.

## Implementation and acceptance sequence

One functional implementation PR follows contract selection. Reuse T07/T08 and
existing ownership/account boundaries; do not introduce a native model revision
or redesign attachment persistence to expose this API.

1. Public values/aliases and connection wrappers; exact context/namespace checks,
   early validation, shared-route pause/resume, bounded observation and restart
   registration. Review account/close/startup races and offline control admission.
2. External `import GraphEvo` Swift 6 consumer compilation and deterministic tests:
   invite/accept, wrong recipient/container/environment, malformed input without
   local claiming, interrupted join/reopen, read-only across leases, offline leave,
   purge failure/quarantine, confirmed loss, reinvite and unrelated-graph progress.
   Reuse native regressions; do not label injected results physical evidence.
3. Companion demo: owner invite/export capability and participant import into a
   separate explicit workspace, status/permission presentation and confirmed
   destructive actions. Persist descriptors before work; preserve existing user
   stores. Use a bounded capability file/share action for this first transport.
   The recipient first exports its opaque identity for the owner to import;
   the owner returns the resulting invitation capability. No email/SMS delivery
   service or raw identity text entry is required. This two-step demo is not
   presented as acceptance of the final consumer invitation UX.
4. Review/correct, then the required full persistence/sync/lifecycle checkpoint
   on the reviewed source, then authorized integration. Demo has its own tested
   dependency pin. Documentation-only contract review needs no full suite.
5. Record a bounded public two-account device path separately: invitation,
   empty import with exact IDs/content, permission downgrade/upgrade, leave or
   revocation, reopen and reinvite, retaining owners until independent observation.
   Availability of two different accounts is a physical-fixture prerequisite,
   not a reason to reinterpret same-account private recovery as sharing proof.

No beta gate is closed by this proposal. Native presentation/URL-only onboarding,
independent readers/protected data, broader structural conflicts, interruption/
restore, production limits and background scope remain explicit checklist work.
Physical account-switch trials retain their agreed during-beta scheduling.
