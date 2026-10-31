# GraphEvo 2 — T08 sharing lifecycle

Status: package-only implementation candidate on `codex/v2-sharing-lifecycle`,
from integrated T07 #119. Review, remote CI and integration are separate steps.
Native S03 and cloud wire formats remain unchanged. The session document is
format 5; incompatible alpha state is refused unchanged. Use new fixtures without
resetting the cloud container. Mandatory v1 conversion is separate.

## Contract

Confirmed loss of shared access and explicit leave win over every unpublished
local change. The participant replica, internal attachment bytes, PH, frozen
attempts, inbox and receipts are removed. No consumer delete mutation is generated
and no abandoned work is uploaded. Owner-private records and other graphs remain
intact. Consumer exports/backups are outside library ownership.

Read-only downgrade retains the replica and upload backlog while imports continue;
an upgrade makes the backlog eligible again. Network, quota, authentication and
write-permission errors alone never authorize local deletion. The native adapter
inspects the exact shared zone and zone-wide share under the verified account.
A joining replica does not interpret initial absence as revocation. Account
changes keep the session's sticky failure; no automatic cross-account reset.

Package-only ContextManager operations:

- `cloudParticipants(for:configuration:)`, `setCloudParticipantPermission`,
  `removeCloudParticipant` and `stopCloudSharing` manage owner CKShare metadata.
- `leaveCloudShare(for:configuration:)` is destructive even with pending writes;
  it reports local removal separately from a retained remote command.
- `cloudSharingStatus`, `observeCloudSharing` and `refreshCloudSharing` expose
  joining/active/accessUnverified/leaving/purging/removed, role, permission, removal
  reason, pending command and payload-free domain/code failures. The status does
  not retain a GraphStore lease and remains readable after graph removal.
- `registerCloudGraphLocation(_:at:configuration:)` registers a current runtime
  URL for restart recovery without opening application data.
- `acceptCloudInvitation(_:at:configuration:)` explicitly creates an empty new
  replica after prior cleanup and remote leave completion. No old handle revives.

Owner mutations update/delete only the private CKShare. Participant leave deletes
only the shared CKShare, never owner data or a private zone. See Apple's
[sharing contract](https://developer.apple.com/documentation/cloudkit/shared-records).
Commands retain a target share identity and are serialized per graph and scope.
One targeted rebase is allowed for CKShare save conflicts; callbacks never replay
consumer bodies. An ambiguous remote command remains pending, while a superseded
share identity is not modified. No distributed command ordering is promised.

## Local destruction and recovery

Persist removal intent before blocking the resource's application admission.
Drain admitted work, invalidate all resource leases, retire the graph sync session,
and use Core Data destruction before removing its exact owned SQLite/WAL/SHM
artifacts. Do not recursively delete a parent directory or derive internal external
storage paths. Runtime/gateway claims remain held through native destruction and
artifact cleanup; failed cleanup remains quarantined and retryable. The native
store UUID and exclusive graph purpose are checked before deletion. Wrong or
replaced resources are refused. A genuinely uncertain/corrupt resource is not
silently erased as another graph.

Reserved local participant metadata carries full session identity, membership
generation and a terminal block. Reopened participants do not admit application
reads/writes until the session journal has been checked against that metadata and
store UUID. Control-only metadata and purge recovery remain available. Bootstrap
supplies current file URLs; no sandbox/container path is persisted. If the native
files are already absent after an interruption, the journal can finish transport
cleanup without recreating a store. Unverifiable leftover sidecars are refused.

Late releases and callbacks are scoped to owner/membership/engine generations.
Terminal incoming bodies are dropped; removal clears retained data envelopes and
native pending record IDs for that zone. Rejoin drains and replaces only the sole
shared engine with nil serialization, preserving other graphs' durable work.
Never edit Apple's opaque serialization or create a per-graph engine. Reopening
an old removed SQLite copy is not a supported rejoin path.

## Foreground control work

One finite control worker per scope shares existing native exclusion. It runs on
explicit foreground activation, reconciliation and hints, including paused graphs;
no paused application records are fetched to inspect permissions. Background and
instantaneous detection while offline are not provided. Inactivity stops new
control admissions; stop drains admitted control work and already-started purges
for that session before teardown. Other sessions' purges do not delay its stop.
Retry delays use 5/15/30/60/120/300 seconds, capped jitter and larger retryAfter;
busy waits one second. Hints/activity never bypass a retry delay, including hints
received while a failing operation is in flight. Permanent failures require an explicit retry. No data queue
or application snapshots are introduced by this worker.

## Validation and gates

Deterministic tests cover loss/leave with pending writes, aliases, complete owned
artifact removal including an attachment, admitted native work, read-only imports
with pending uploads, offline leave/restart, failures before/after destruction,
restart before journal completion, rejoin generation/late-engine fencing,
other-graph pending work during engine replacement, owner commands and virtual
clock retry/lifecycle behavior. A Debug-only pre-destruction barrier supports
physical interruption testing and is absent in Release.

The [physical report](results/sharing-lifecycle-2026-10-31.md) retains exact source
pins, 14 completed mutation-matrix reports, the deliberate purge interruption and
the later read-only correction checks. Initial T07 evidence remains historical.
Public opening/UI, actual background/APNs delivery, broad account and
cross-process/cache policy, protected migration/backup and supported-scale costs
remain release gates. Workflow: local/device checks, review/corrections, CI, then
an authorized merge. Laboratories remain excluded from CI.
