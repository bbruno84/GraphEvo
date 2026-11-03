# Controlled graph access and performance consolidation

Status: selected direction, implementation in progress on
`codex/v2-controlled-graph-entry`. This is not an integrated checkpoint or a
public opening API. Native S04 and ordinary serialized application values stay
unchanged.

## Selected configuration

The maintainer selected descriptor-first Core Data queries with query-local
validation, explicit global integrity audits, transaction-local mutation
inventory reuse protected by interprocess exclusion, and native Core Data
attachments. Arrays, dictionaries, Codable/opaque values and ordinary Data
remain payload values. Only explicit logical attachments use the attachment
transport. Cloud transfers use CKAsset and an owned temporary transport spool;
permanent attachment ownership is not moved to a second filesystem library.

These are separate implementation areas. The current ownership increment
implements the controlled writer boundary and mutation inventory lifetime.
Descriptor-first general execution and descriptor-only durable asset transport
must retain their own format, budget and recovery reviews before adoption.
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
timeout is not reproduced in that bounded run. This is local evidence; reviewed
remote CI and integration remain pending. Initial full checkpoint #384 passed macOS but
iOS timed out in sqliteReopenAndExactCandidateBoundaryPreserveOrderingAndMissingPlacement
(795 passed functions, one failure and one known skip). That failure is retained
without attribution to the workspace-ownership correction or a weakened timeout.

Review found that native schema bootstrap initially acquired shared presence.
It now requires exclusive presence before any seed/preparation/load and retains
it throughout the workspace's lifetime. A regression verifies refusal leaves the
destination absent when another live owner exists. Shared presence remains
refused until workspace close; resuming without a schema change still requires
exclusivity. Other regressions cover actual child-process lock release, namespace
replacement refusal, reserved-fence borrowing, idle-owner destruction refusal,
generic writable admission refusal and pending mutation/cascade/rollback behavior.
