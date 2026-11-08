# Definitive graph deletion

Notes prerequisite after ordinary private discovery (#194). This is distinct
from closing a lease, leaving a participant replica or stopping owner sharing.
The new entry points require an ordinary context; dedicated App Group graph
deletion is not added by this increment. Existing participant leave is unchanged.

## Public operations

- `GraphContext.deleteGraph(_:)` deletes a local-only graph from the same context.
  Cloud-bound and participant stores are refused before publishing deletion intent.
- `GraphCloudConnection.deleteGraph(_:)` deletes an owner-private graph's zone,
  including its shares, then destroys that exact local native store and owned content.
  Participant stores must use the existing explicit leave protocol instead.
- Context/connection `resumeGraphDeletion(id:at:)` resume an existing intent at its
  current sandbox URL. They never infer deletion intent from file absence.
- `GraphContext.graphDeletionStatus(id:at:)` reads bounded durable progress without
  exposing account values. A status is not permission to write or synchronization proof.

Status has an operation UUID, graph ID and phase: `prepared`, `remoteDeleted`,
`completed`. Local deletion moves directly from prepared to completed. After intent admission, errors
retain progress; offline failure is not successful deletion. Applications retain
routing and offer retry, removing their catalogue entry only after completed.
Completion proves this operation's remote zone removal and local cleanup, not
that every other device has observed the deletion or erased its own cached data.

## Durable intent and exact recovery

Terminal native admission drains before reserved root metadata records the exact
operation, graph, native store UUID, source file device/inode and optional account/
container/environment/zone binding. An operation journal beside the SQLite survives native destruction; its
location is relative to the current store. It stores no absolute URL or
application payload. Updates use the existing Foundation grant, not another lock.

Ordinary runtime opening checks this evidence inside its existing Apple opening
grant, before Core Data load. Pending stores cannot be silently reopened or
recreated. An interrupted gap before external journal publication can resume only
from the matching native intent. A normal unrelated store is never made terminal
by a resume request. Source file identity is checked before any destructive remote
request or native load; a same-GraphID replacement is still a different target.

The native destruction grant records its exact owner generation and bounded
artifact identities before destruction, and surviving artifacts after native
success. The portable receipt records the former coordination root as a validated
relative component. Recovery acquires current and recorded Apple grants together
after a quiescent container move; file identity checks remain required. After process death an exclusive Apple grant excludes live presenters;
only the recorded generation can be recovered. Surviving captured artifacts can
then be cleaned even when SQLite has already disappeared or become a native
cleanup artifact.

A process killed during ordinary use can leave a nonretiring registration before
any deletion receipt exists. Under the exclusive Apple `.forDeleting` grant only,
the terminal protocol validates its exact operation journal, source inode and
native store UUID, then validates the complete registration set before removing
abandoned nonretiring peers for that same graph. Live presenters still deny the
grant. Foreign, generic, workspace, retiring or malformed registrations remain
unresolved and defer destruction while leaving normal detachment possible.
Ordinary opening never performs this recovery. A recovery-mode opening without
its matching durable deletion intent is refused. Unverifiable/replaced evidence
fails closed and remains for diagnosis.

Cloud requests require a ready connection before admission; a readiness refusal
creates no native intent. Cloud intents also persist in session format 12, scoped to the original identity.
Previous alpha session formats are refused unchanged. A wrong account never
executes the retained command. Synchronization admission stops and admitted work
drains before the account-verified private control request. The remote descriptor
must match the graph before zone deletion; an already absent zone is idempotent
success. Only an explicitly retained initial-publication attempt may remove an
unpublished empty zone after verifying it has no zone changes. Other missing or
conflicting metadata is refused. Remote confirmation precedes native destruction;
control receipts, assets, routes and engine pending work are removed afterward.

## Preventing zone resurrection

Ordinary initial publication records its exact account-bound attempt before its
first zone-creation request. Later binds require the zone to exist. An ambiguous
initial failure is fail-closed: retry can inspect an existing zone, but does not
issue zone creation again. The caller can explicitly delete the pending graph and
create a fresh one if initial creation never reached the server.

Record sends never enqueue `saveZone`, and restored pending zone saves are removed
before the manually driven engine is used. Native sharing preparation also requires
an existing zone. Converted v1 graphs retain their explicit initial activation
claim; published activations already require matching remote authority. There is
no automatic missing-zone repair for an existing published route. These rules
require cooperating updated clients; old alpha binaries must be stopped.

Native S06/S07 schemas, node/descriptor wire formats and public local operations
remain unchanged. This adds operation evidence and session format 12, not a new
application command queue or independent CloudKit engine.
