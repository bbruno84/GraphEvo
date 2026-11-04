# H02 — public sharing through the coordinated context

Status: implemented through [PR #152](https://github.com/bbruno84/GraphEvo/pull/152),
2026-11-04, based on integrated H01/#151 (`a1097ff1`) and demo PR #2.
Reviewed [full checkpoint #41836169999](https://github.com/bbruno84/GraphEvo/actions/runs/41836169999)
passes on `dc0ea8932a56fe5bed46844628f2020d26f72a32` with 1,038 macOS functions,
1,035 passed iOS functions with the known skip, and both Swift 6 consumers. Final integration notes are documentation-only;
shipping, tests, consumers and workflow inputs match that checkpoint.
Native UI/two-account physical acceptance remains open.
Read with [H01](graphevo-2-public-entry.md), [T07](graphevo-2-zone-sharing.md),
[T08](graphevo-2-sharing-lifecycle.md),
[account isolation](graphevo-2-cloud-account-isolation.md) and the
[release checklist](graphevo-2-post-alpha-checklist.md).

Decision, 2026-11-04: the maintainer selects a small system record with a fixed
name, GraphID and a format version. Future metadata may extend that record under
explicit compatibility rules. The [discovery investigation](results/public-sharing-graph-discovery-2026-11-04.md)
provides the feasibility rationale. The selected onboarding direction uses Apple's
invitation/acceptance followed by descriptor discovery; no separate invitation
file or advance account-identity exchange is required. Implementation and bounded
automated evidence follow below; the original selection alone did not establish
native physical acceptance.

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

## Apple integration and graph descriptor

Apple provides [zone-wide sharing](https://developer.apple.com/videos/play/wwdc2021/10086/)
and [share metadata callbacks](https://developer.apple.com/documentation/cloudkit/ckshare/metadata).
The native metadata identifies the exact share and zone. After native acceptance,
the participant reads a small system descriptor from that zone's shared database
to learn GraphID, including when the graph contains no application nodes.

The descriptor has a fixed record name within the zone and initially contains
only GraphID and its own format version. GraphID is a stable public identifier,
not an authorization credential. This version describes the descriptor protocol,
not application payload versions, native Core Data schema or sync completion.
Do not add account credentials, device-specific state, synchronization progress
or an application-format registry. Additional metadata is future work, not a set
of speculative fields to implement now. Define unknown-optional-field tolerance
and reject unsupported required semantics before use. The implementation uses type GraphEvoGraph, fixed record name graphevo.graph,
format 1, graphID and a 16 KiB archived-record limit.

Publish and validate the descriptor before exposing a new share. Read it directly
by its fixed ID under the existing session scope gate, without fetching application
payloads/assets or advancing CKSyncEngine's import checkpoint. Preserve the MF10
activation authority record as a separate protocol. Recognize the new descriptor
as control metadata in import, budget and conflict handling; it must not enter the
GraphEvoNode decoder. This is a cloud protocol addition and requires an explicit
old-alpha-zone compatibility policy; it does not require a native model change.

The descriptor identifies the graph; CloudKit still authorizes access. Shared
writers must not be assumed unable to edit it. Pin established graph/zone bindings,
validate every imported node against them, and refuse a changed or conflicting
identity without redirecting a replica or authorizing local deletion. A missing
record is resumable unavailable metadata, never permission to invent GraphID.

Use [Apple's standard sharing UI](https://developer.apple.com/documentation/cloudkit/shared-records)
for the native presentation path, with an explicit admission, reconciliation and
durable-intent boundary around mutable CKShare access. Exact platform adapter
signatures and UI lifecycle remain implementation design work. Do not introduce
another synchronization manager or bypass T07/T08 through an independent writer.
The host handles platform callbacks and chooses an explicit local file after
identity discovery. Invitations and native account references must not be logged.

The existing package-only capability may remain for historical probes and tests;
it is not a required public transport. There is no separate capability-file demo,
custom user directory or account-identity exchange in the selected native flow.

## Proposed public call shapes

All additions target iOS 17/macOS 14 and remain in the GraphEvo product. Names
below are proposed signatures, not implemented declarations. Supporting values
have documented consumer fields and initializers where construction is meaningful;
runtime routes, membership journals and native share archives stay internal.
The historical sketch below covers lifecycle operations only; the implemented
[API reference](../api/public-api.md#h02--native-sharing-and-graph-discovery-v2-alpha)
and [guide](../guides/public-sharing.md) define the complete candidate surface. Native presentation, acceptance and
post-discovery replica opening need separate reviewed signatures; they must not
require the host to know GraphID before native acceptance. Platform invitation
bridges may accept CloudKit types where needed, as allowed by M17.

```swift
extension GraphCloudConnection {
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

Acceptance validates live native metadata, the configured container, exact
zone-wide share, current participant role/permission and account epoch. Persist
a bounded pre-GraphID joining intent keyed by the account/container/share-zone
before the native call. GraphID discovery and local file selection follow native
acceptance, not the other way around. A crash between these stages must resume
the same intent by inspecting server acceptance, without requiring a local store.

After descriptor validation, expose detached graph identity so the host can select
an absolute SQLite URL as in H01. Claim context/graph/resource ownership before
local changes. A fresh request creates only an absent target. Retry may resume
only the exact durable joining generation and native store identity; reject
nonempty, foreign, replaced or mismatched resources. Preflight errors leave an
unrelated local-only graph unchanged. Do not erase a target on acceptance error.

Return a GraphStore after native acceptance, descriptor validation and local
access metadata commit. It may contain no records yet. Acceptance, readable
access, imported content and peer convergence are separate facts; no fake
percentage/completion certificate is introduced. Missing descriptor or network
failure retains a retryable join, not a fabricated graph or silent rollback.

On restart, the host restores its saved GraphID/file selection and connection.
`registerSharedReplica` registers only an existing journal membership's exact
current URL for control recovery without granting application access or creating
a missing store. It must support interrupted purge, including already absent
native files, under T08's identity guards. Then normal `context.openGraph`
restores participant access checks; incomplete joins resume their exact native
share intent and descriptor discovery. Cold participant data stays blocked until
account and membership checks satisfy the existing contract. Account monitoring remains independent of
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

1. Define the bounded descriptor/control protocol, compatibility and pre-GraphID
   join recovery, then native presentation/acceptance bridges and public values/
   connection wrappers. Preserve context/namespace checks, shared-route pause,
   bounded observation and restart registration. Review account/close/startup
   races and offline control admission.
2. External `import GraphEvo` Swift 6 consumer compilation and deterministic tests:
   native invite/accept and empty-graph discovery, wrong container/participant,
   malformed/conflicting/unsupported descriptor without local claiming, restart
   after native acceptance but before GraphID/file selection, interrupted join/reopen,
   read-only across leases, offline leave,
   purge failure/quarantine, confirmed loss, reinvite and unrelated-graph progress.
   Reuse native regressions; do not label injected results physical evidence.
3. Companion demo: native sharing presentation and invitation callback, descriptor
   discovery and explicit participant workspace selection, status/permission
   presentation and confirmed destructive actions. Persist restart state before
   side effects; preserve existing user stores. No separate invitation file or
   advance recipient identity exchange. Test both empty and populated graphs.
4. Review/correct, then the required full persistence/sync/lifecycle checkpoint
   on the reviewed source, then authorized integration. Demo has its own tested
   dependency pin. Documentation-only contract review needs no full suite.
5. Record a bounded public two-account device path separately: invitation,
   empty import with exact IDs/content, permission downgrade/upgrade, leave or
   revocation, reopen and reinvite, retaining owners until independent observation.
   Availability of two different accounts is a physical-fixture prerequisite,
   not a reason to reinterpret same-account private recovery as sharing proof.

No beta gate is closed by this increment. Native presentation/URL-only onboarding
is implemented; its two-account physical evidence remains required. Independent
readers/protected data, broader structural conflicts, interruption/restore,
production limits and background scope remain explicit checklist work.
Physical account-switch trials retain their agreed during-beta scheduling.
