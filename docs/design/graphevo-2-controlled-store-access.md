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

Writable plain local SQLite runtime owners and coordinated read-only replicas
use stable sidecars derived from the existing
canonical resource key. Symbolic/case aliases resolve to the same key; hard
links remain refused. Sidecars are regular, single-link, current-user-owned
files with private permissions and matching descriptor/path identities. They
are never unlinked on release or ordinary store destruction. Retiring an isolated
workspace may remove its entire directory only after exclusive-owner admission
and native detachment. A waiter holding an old descriptor must fail path/inode
verification if that directory disappears or is recreated; it cannot adopt the
new lock identity. A terminated process releases its descriptors
through the operating system. This does not establish application crash recovery.

The writer sidecar uses advisory exclusive flock. Order is runtime admission,
local FIFO writer gate, process lock, fresh native context, body/save, context
cleanup, process unlock and FIFO release. Bootstrap takes the same lock before
native metadata/load/preparation. The reserved publication/workspace writer and
privileged native-operation paths use that boundary too. A native callback must
settle all its native work before its awaited completion. Inherited-task
same-store native reentry is rejected; detached tasks/callbacks are not made
generically reentrant.

Nonblocking probes run on a dedicated I/O queue; contention suspends with a
cancellable 25-ms polling interval. No thread mutex is held across await and
no blocking flock runs on the cooperative executor. This policy is not an
intrinsic OS-lock latency or an interprocess fairness guarantee. Successful
save remains the cancellation boundary; cleanup is not abandoned on cancellation.

An all-operation maintenance reservation retains the process writer fence after
draining local operations. Its admitted operations borrow that fence, so release
of the reservation cannot unlock an operation still using it. Write-only holds
remain local admission policy; they are not a distributed migration fence.

## Live owners and destructive maintenance

Each participating plain local owner also retains a shared presence lease until
native detachment succeeds. Readers keep their pinned snapshots without taking
the writer lock. Independent stores retain independent progress.
Unmarked read-only archives and stopped-writer legacy conversion sources do not
require sidecar creation or a writable source directory; their existing source
quiescence prerequisites are unchanged.

Destroy and detached workspace cleanup acquire the writer fence and require an
exclusive presence lease. Another process's idle open coordinator makes that
operation fail with resourceReserved; it is not silently invalidated. Our shared
claim is restored on refusal. Failed detachment retains native/gateway/presence
ownership. Close only detaches its own coordinator. Backups lock a coordinated
source and the new destination; an owned destination is not replaced. Native
workspace bootstrap remains supported under its destination writer fence and
requires exclusive presence before seeding, preparation and native schema load.
Every workspace retains exclusive presence until final detachment, including a
resumed, sealed or already converted workspace. It does not downgrade while its
working graph is live. Failed detachment retains that claim in quarantine. A
later ordinary coordinator opening the published graph uses shared presence. Existing
stopped-writer source and migration publication prerequisites remain mandatory.

This protocol requires all writers to participate. Old binaries, direct external
Core Data writers and native mirroring that continues outside our awaited
callbacks are not covered. The role marker is not a distributed old-client
fence. Hosts must stop such writers before adoption. Sidecar checks do not
provide a malicious-writer or arbitrary filesystem replacement guarantee.

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

The package does not expose App Group role selection or a production orphan
recovery operation. See [PA02](graphevo-2-post-alpha-checklist.md) for remaining
physical-device, public-role and CloudKit validation.
