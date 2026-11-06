# Controlled graph access and performance consolidation

Status: selected direction. The first ownership increment integrates through
[PR #142](https://github.com/bbruno84/GraphEvo/pull/142) into `codex/graphevo-2`.
[Descriptor-first query scopes](graphevo-2-descriptor-query-scopes.md) integrate
through #143; [durable reference-only asset queues](graphevo-2-durable-asset-spool.md)
integrate through #144. No public
opening API is added. Native S04 and ordinary
serialized application values stay unchanged.

## Selected configuration

The maintainer selected descriptor-first Core Data queries with query-local
validation, explicit global integrity audits, transaction-local mutation
inventory reuse protected by interprocess exclusion, and native Core Data
attachments. Arrays, dictionaries, Codable/opaque values and ordinary Data
remain payload values. Only explicit logical attachments use the attachment
transport. Cloud transfers use CKAsset and an owned temporary transport spool;
permanent attachment ownership is not moved to a second filesystem library.

These are separate implementation areas. #142 implements the controlled writer
boundary and mutation inventory lifetime. #143 adopts descriptor-local general
query execution after matched comparison and review. #144 adopts reference-only
durable asset transport after review and full checkpoint #41715897139; physical
acceptance of that new spool remains open.
Opening latency, metadata-list tuning, batch-size/device profiling and broader
performance envelopes belong to beta validation, not additional prerequisites
for this ownership increment.

## One graph opening gateway

The existing package-only `GraphContextManager`, supplied in production by
`GraphCoordinatorFactory.shared`, owns graph registration and returns consumer
leases. It remains the entry point for creating/opening coordinated v2 graphs.
The runtime resolves aliases, reserves ownership, loads Core Data and supplies
all admitted read/write/maintenance operations. No parallel opener is added.

A file bearing the coordinated-store purpose marker requires an exclusive
graph configuration for writable runtime admission. Generic GraphDatabase
writing cannot reopen it after the manager closes. Read-only local access
retains its existing native validation and cannot mutate the graph. Generic
unmarked local stores, v1 readers and transitional mirrored/paired stores retain
their separate contracts; this is not implicit conversion or public activation.

Coordinated graph opening distinguishes existing-store access from explicit
creation. The runtime rechecks that intent under the process writer fence
before Core Data opens the file. An existing-store request that waits through
a purge reports a missing store without creating a new SQLite file. A
request that observed an existing file refuses a different filesystem
identity before native loading. Explicit creation refuses an occupied path.
Participant purge recovery also requires an existing store. If it disappears
while recovery is waiting, the next attempt can resume from the durable
terminal membership without retaining the failed opening.

## Cooperating process protocol

Writable plain local SQLite owners and coordinated read-only replicas use
Foundation file access on a private coordination directory derived from the
canonical store key. Symlink and case aliases converge. Hard links are refused.
Independent stores in the same directory have separate coordination targets.
The workspace anchor sits beside the managed workspace directory so it
survives workspace discard. Unmarked read-only archives and stopped v1
sources can still open without creating coordination directories.

Apple grants cover native opening, transactions, close and destruction.
Reads keep their existing query-generation snapshot. A local FIFO writer gate
and the same-store reentry check remain in force. A native SQLite writer
completes its synchronous callback, save and context cleanup within one
accessor. Cancellation before the save aborts the operation. A successful
save returns its committed result.

A presenter and durable owner registration follow each native coordinator.
Close removes the registration after confirmed detachment. Destruction uses
a deletion grant and verifies the sole registration before native changes.
A failed or interrupted destruction can leave a retirement registration that
blocks new owners until verified cleanup. A pre-destruction peer refusal
detaches only the requesting owner.

An isolated workspace admits one owner from native bootstrap through final
detach. After a crash, an unresolved registration blocks workspace reopening
and cleanup. Stop every process using the workspace before offline recovery.
The package-only `recoverOfflineMigrationWorkspace(at:generation:)` validates
the descriptor, exact workspace and store identities, and the indicated
generation within a deletion grant. Partial destruction remains pending.
Use the descriptor and the UUID-named entry under the workspace anchor's
`.owners-v1` to identify the generation. Process age and file absence are
insufficient evidence for releasing a registration.

An ordinary replica purge can recover one abandoned registration at a time
through `registerSharedReplica(id:at:recoveringOfflineGeneration:)`. The
terminal membership supplies the expected store UUID. Native v1 conversion
accepts the same explicit recovery parameter on its opening request and
checks the durable intent or committed receipt. Stop all store users before
using either path. Recovery refuses an active native owner and preserves
retirement registrations. Native seed creation precedes owner registration
while the exclusive grant is held.

Ordinary SQLite outgoing attachment preparation sweeps unreferenced files,
writes the bounded batch and saves its references within the same Apple grant.
The next preparation can reclaim files after process death. Post-send cleanup
uses the same grant so it cannot change the spool during a coordinated copy.
Dedicated App Group preparation keeps its split-phase staging.

Maintenance reservations drain local work. Native snapshot creation acquires
source and destination in one Foundation request. The copy, source history
boundary and outgoing assets are captured within that request. Compression
and validation operate on the private copy. Publication checks the source
identity and allowable history inside its final write grant and commits graph
changes and the receipt in one save. The existing receipt supports retry
after commit without applying the migration again.

Upgrade cooperating app, extension and helper processes together while all
store users are stopped. Old binaries and direct writers use a different
protocol. Keep the canonical SQLite locations and existing store formats.
Leftover advisory sidecar files from an earlier version can remain in place.
Cloud session ownership follows its separate session protocol.

## Physical App Group lifecycle finding

The [2026-11-04 presence control](results/app-group-presence-control-2026-11-04.md)
reproduces iOS termination of app and widget while the lifetime shared presence
flock is held in an App Group. A matched fd-only control survives and completes
short bidirectional round trips, but explicitly refuses destructive maintenance.
It is not a replacement protocol. The native-detachment/exclusive-maintenance
guarantee above remains required; its suspension-compatible implementation and
PA02 physical acceptance are open. No runtime change follows from this report.

## Apple owner-lifetime experiment

The [M/M2 continuation](results/apple-owner-coordination-2026-11-04.md) tests the
missing owner/maintenance boundary, beyond the earlier writer-only experiment.
M2 uses an active NSFilePresenter-backed lease, finite NSFileCoordinator requests
and native detach before presenter removal. Mac controls and bounded iPad
host/widget background contention pass, including clone-restore refusal while
active and permanent old-lease refusal after pause. The operation-bound M
comparator retains its same-UUID/inode clone failure. Matched costs and resource
layout, initialization/quarantine, reader-concurrency and migration limitations
are recorded. M2 is a candidate for contract discussion, not the current runtime;
PA02 stays open. No production lock is changed by this report.

The [priority protocol](graphevo-2-apple-owner-test-protocol.md) and
[N result](results/apple-owner-priority-tests-2026-11-04.md) add macOS partial-open,
retained cancellation and real session/backup lease checks, plus thirty actual
iPad Home/widget/app cycles with exact native readback and ordering. Production
adoption is still **NO GO**: physical failure/background, XR iOS 18 interaction
and coupled synchronization/public observation lifecycle remain unverified.
These reports do not replace the shipping ownership protocol above.

## Transaction-local mutation inventory

Only protected coordinated transactions admit a reusable Session holder in
their native context. The first mutation constructs the inventory. Inserts add
nodes, native objects reflect pending property/inverse edits, and deletions
remove their supported cascade. Frozen metadata indexes are discarded after
each successful mutation. A caught refusal discards the inventory before later
operations can proceed. Other adapters retain their previous fresh-session path.

Runtime cleanup clears the holder before rollback/reset on success, throw,
cancellation and save error, breaking any context/Session retain cycle. Nothing
is reused between transactions. Consumer bodies are neither suspended nor
replayed; contexts and managed objects never escape. File validation, owner
checks, permissions and the one-save boundary remain in place.

## Research scope

Private F/G/H/I experiments used 242 attachments (109,091,048 original bytes).
The matched I baseline/reuse/locked-reuse import medians were
5,834.54/735.38/745.77 ms for three transactions of 100/100/42 records.
H alone introduced a deterministic cross-process duplicate-identity regression;
both-I participants serialized and retained a valid native result. This is
bounded local macOS evidence, not a production throughput promise or a CloudKit
checkpoint. Private stores, manifests, logs, traces and image bodies remain
outside Git and CI. Synthetic committed regressions and integration validation
must establish the final code's actual scope independently of those prototypes.

## Local implementation verification

The ownership implementation passes 974 macOS functions (331 legacy, 521 store,
92 runtime and 30 model) and 44 selected iOS 18.5 Simulator functions, 46 expanded
executions, with no failures/skips. The latter covers lock admission/cancellation,
owner maintenance exclusion, migration bootstrap, coordinated operations and
native v1 migration. Both Swift 6 consumers pass locally. The corrected workspace
ownership passes the complete macOS suite and all 13 lock regressions. All nine
iOS query functions also pass five repetitions (45 executions); the remote
timeout is not reproduced in that bounded run. The complete local iOS suite
passes 971 functions, zero failures and one known skip (1,089 expanded passing
executions). Initial full checkpoint #384 passed macOS but
iOS timed out in sqliteReopenAndExactCandidateBoundaryPreserveOrderingAndMissingPlacement
(795 passed functions, one failure and one known skip). That failure is retained
without attribution to the workspace-ownership correction or a weakened timeout.

Reviewed [full checkpoint #387](https://github.com/bbruno84/GraphEvo/actions/runs/41692421379)
passes on `2e0d2b171c46661560646482b65ac974b4a50278`: 974 macOS functions,
971 passed iOS functions with one known skip and both Swift 6 consumers. The
first iOS job acquired no runner and executed no steps; its sole retry passes
without source changes or rerunning the successful macOS job. Final integration
notes change documentation only; shipping/test/consumer/workflow inputs match
the reviewed checkpoint. This does not establish physical-device, cloud transport
or beta performance acceptance.

Review found that native schema bootstrap initially acquired shared presence.
It now requires exclusive presence before any seed/preparation/load and retains
it throughout the workspace's lifetime. A regression verifies refusal leaves the
destination absent when another live owner exists. Shared presence remains
refused until workspace close; resuming without a schema change still requires
exclusivity. Other regressions cover actual child-process lock release, namespace
replacement refusal, reserved-fence borrowing, idle-owner destruction refusal,
generic writable admission refusal and pending mutation/cascade/rollback behavior.

## Dedicated App Group stores

The package-only App Group `GraphContext` uses an entitled container and
`GraphEvo-AppGroup-v2/<graph UUID>/Store.sqlite` under
`Library/Application Support`. It uses the same graph create/open entry and
S04 schema. Both App Group namespaces are reserved against generic SQLite,
v1, native mirroring and uncoordinated maintenance, including through aliases.
The new protocol admits fresh v2 locations only. It does not adopt v1
experimental locations. All processes accessing a v2 store must participate
through the same canonical directory.

`NSFileCoordinator` provides interprocess exclusion for opening, writes,
identity validation, close and purge. These paths do not acquire advisory
writer or owner sidecars. Local admission drains in-flight operations before
close; ordinary reads remain generation-pinned. The native owner registers its
presenter and records its generation before attaching Core Data under an Apple
grant. Close detaches before clearing both. The host starts closing its graph
leases on inactivity, and the extension closes its handle before returning.
If the system interrupts close or native detachment fails, the registration
records that its detach was not confirmed.

Prepared CloudKit writes capture the file and native store identity and
Persistent History token under the first grant. They stage outgoing assets in a
unique namespace outside that grant. A fresh context validates the boundary
under the final grant before publishing. Changed or unavailable history causes
rollback and cleanup of the attempt's own files. The retry starts from current
state. An App Group staging attempt does not sweep other attempts' files.

A purge requests an Apple deletion grant so active presenters can refuse it.
After a grant, remaining foreign registrations are unresolved detach evidence.
Cold purge checks for such evidence before attaching. Native identity
verification, Core Data destruction, artifact cleanup and registration removal
share one deletion grant on the stable directory. If refusal precedes native
destruction, the purging owner detaches under a normal grant and the membership
stays `purging` until retry. After native destruction starts, only verified
cleanup can release ownership. Restart without sufficient evidence leaves the
purge pending. PID, age and file absence are not release authority.

The public local surface below uses this runtime. See
[PA02](graphevo-2-post-alpha-checklist.md) for synchronized replicas and
production recovery of abandoned App Group registrations.

## Public App Group process contract

Selected 2026-11-06 for implementation. The consumer supplies an entitled App
Group identifier and declares one of two roles when configuring its context.
GraphEvo uses that declaration for App Group admission. Bundle classification
remains a separate platform safeguard for existing CloudKit entry points.

The public roles use [`GraphContext(appGroup:)`](../api/public-api.md#local-app-group-contexts).
The primary obtains a normal graph lease and can explicitly enable CloudKit
for dedicated private or participant replicas. The secondary gets a scoped
operation and the result of its detach attempt.

| Role | Admitted operations |
|---|---|
| Primary | Create and open a graph, read and write, and own an opted-in CloudKit connection and its lifecycle. |
| Secondary | Read an unbound graph or perform an opted-in local transaction on an existing graph. Each invocation closes its lease. |

An optional readable process label may accompany either role for diagnostics.
The label contributes only to diagnostic presentation. Store location derives
from the entitled container and graph ID. Admission derives from the declared
role, access policy and existing store/account checks. Processes in the App
Group must cooperate through the coordinated entry point.

The secondary can use an available replica while the primary is active or
backgrounded. A committed local write enters the primary's normal synchronization
flow when it runs. A live invocation that reaches its execution budget before
commit can cancel and report the outcome. Once a write commits, its result
follows the existing commit boundary. A fresh invocation takes a new read scope
to observe peer commits. Live invalidations can prompt a refresh while the
consumer runs.

If the secondary starts before the primary has created a graph, opening reports
a missing store. An incompatible store, maintenance reservation, removal or
unavailable protected data produces an explicit refusal. The primary owns any
subsequent create, migration or recovery. A secondary transaction commits to
the selected replica without querying CloudKit. Its reads and writes use the
existing native scope and any persisted participant restrictions. A commit
stays associated with that replica when the primary isolates it after an
account change. The primary discovers eligible writes through persistent
history when the original replica resumes synchronization.

Foundation grants continue to provide interprocess exclusion. Durable owner
registrations record pending lifecycle work. Close removes the registration
after native detach succeeds. If an interruption leaves detach unverified,
destructive maintenance stays pending until the exact prior owner and store
generation can be verified under a separate recovery protocol.

The public acceptance checkpoint covers independent iOS processes on one
replica: missing-store startup, concurrent reads and admitted writes, peer
commit visibility, background and reopen, contention with maintenance, and
interrupted close. A synchronized replica also needs primary account isolation and exact peer
observation of the secondary commit. The existing iPad
cycles establish the package-only alternating app/widget lifecycle scope.
