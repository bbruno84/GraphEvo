# GraphEvo 2 — exclusive local graph coordinators

Status: first M17 implementation increment, package-only. No new public opening
API or production custom sync is activated. The
[transition contract](graphevo-2-custom-sync-transition.md) defines the complete
ContextManager/CloudKit direction; the native mirror isolation merged in #105
as `32ae83f` after exact-head iOS/macOS CI `41119977677` passed.

## Ownership and entry points

`GraphCoordinatorFactory.shared` is the single internal production
`GraphContextManager`. The store target compiles its manager/coordinator and
consumer lease lifecycle in Swift 6; the legacy target supplies only the
Node-facade adapter and selected native model factory (now S03). Tests inject independent registries
and lifecycle gates. This is process-local ownership, not a cross-process lock.

The package manager has two operations:

- `createGraph(id:at:)` allocates a new local SQLite store and one graph with the
  requested identity. An existing file is refused, including an empty existing
  store. Concurrent matching requests admitted during the same creation share
  that job; a subsequent creation request is a duplicate.
- `openGraph(id:at:)` opens an existing selected-native store whose only graph has that ID.
  It creates neither a missing directory nor a missing graph. It may join an
  already admitted matching creation. Empty, multi-graph, foreign-ID and
  incompatible stores are refused without identity edits or automatic conversion.

The runtime resolves URLs and aliases once through its existing resolver.
The manager reserves graph ID and canonical resource key before any suspension;
compatible requests await one detached opening job. A graph cannot bind to two
files in the same manager, and one file cannot bind to two graph IDs. The
runtime configuration carries a package-only exclusiveGraphID ownership mode,
which survives canonicalization and participates in compatibility checks.
Generic runtime leases cannot coalesce with an exclusive owner. Independent
registries and legacy stacks retain the existing gateway exclusion.

This increment supports one writable local SQLite resource per coordinator.
Mirrored/private-shared pairs, read-only coordinator opens and memory stores are
refused. Existing public read-only/widget and multi-graph APIs are unchanged.
The [PH increment](graphevo-2-history-processing.md) adds a persistent coordinated
role on fresh creation. Reopening requires it; older unmarked S03 files are not
silently activated. Compatible local/read-only reading remains possible after
close, while native mirroring and creation of another graph are refused. Active
ownership still uses the runtime gateway; the role marker is not a process lock.

## Validation and persistence

The initial checkpoint used S02. [S03](graphevo-2-history-schema.md) now supplies
the selected model, `GraphEvo.v2.schema.3`, with deletion-history identity
preservation. No native column, logical layout or cloud payload is added. Creation uses existing catalog/membership and
identity activation through one runtime-owned transaction/save. Existing-store
opening performs its validation in a pinned read scope.

The adapter requires one plain local persistent container/store, checks the
catalog, audits the native graph projection on **every node including hidden
controls**, then validates the requested graph's identities/values/topology.
This prevents orphan foreign rows from disappearing behind per-graph filtering.
It neither repairs IDs nor derives them from URLs/Core Data URIs. Core Data
contexts and managed objects remain inside trusted facade adapters. Queries,
attachments, observation and typed operations use their existing scoped APIs.

The initial ownership increment required no migration. The PH continuation
requires newly created coordinated alpha resources; it adds no native column. Populated multi-graph or v1 source
conversion remains explicit future migration work. Refusal does not certify
byte-identical volatile SQLite sidecars after a native open/close; it does not
rewrite application records or source identities.

## Handles, cancellation and shutdown

The coordinator owns one root runtime lease. Each returned GraphStore has its
own runtime lease and an internal GraphCoordinatorLease release callback. Manager
tokens cover pending requests as well as returned handles, preventing the last
consumer from retiring the owner while another request is still acquiring a
handle. The release callback keeps the manager alive while consumers need it.

Closing a GraphStore releases only that consumer. The final release starts one
shared shutdown job, drains native admitted work through the existing runtime,
and removes the registration only after successful detachment. New opens await
that shutdown before registering a replacement. A close is idempotent; concurrent
callers observe the same outcome. Dropped handles schedule the same cleanup path.
Shutdown failures retain manager registration and native claims, including both
failed-initialization cleanup and partially loaded-store quarantine. There is no
automatic retry, erasure or substitute owner after such a failure.

Cancellation before manager admission prevents the request. A cancelled existing
opening waiter is observed after shared opening completes and releases only its
own reservation; it does not cancel other waiters. Once shared creation is
admitted, its job proceeds independently of caller cancellation and returns a
successful commit with a usable handle. This is shared bootstrap behavior, not
replay or a change to typed transaction cancellation/commit semantics. Creation
failure can leave an allocated empty native file; it is not silently erased or
reseeded. Crash recovery for bootstrap and durable queues remains separate work.
Closing caller cancellation does not cancel cleanup or abandon registration.

## Validation and remaining work

Twelve coordinator tests cover creation/reopen, coalesced creation, cancelled
waiters and creation requests, independently closeable handles, concurrent close,
reopen during shutdown and unrelated graph progress, abandoned handles, alias
routing, generic/legacy exclusion, refused inputs and both quarantine paths.
The feature fixture exercises values, tags/groups, Relationships/Actions,
attachments, query observation and persistence after reopen. Three runtime tests
cover exclusive-mode compatibility, alias preservation and invalid topologies.

The full local suite passes 574 tests (331 legacy, 149 store, 71 runtime,
23 model); package manifest and diff checks pass. No device/cloud stage is
needed to establish this local increment. Automated
macOS/iOS checks remain required before integration. Public activation, engine
ownership, durable changes/outbox/inbox, graph pause/migration and account-aware
routing are later increments. Existing physical native-sharing results do not
certify those contracts. The beta/stable checklist retains their gates.


## Package-only engine continuation

The [engine foundation](graphevo-2-sync-engine-foundation.md) adds explicit
ContextManager-owned sessions separate from consumer/store leases. Zone binding
validates the live coordinator; the durable route outlives an individual lease.
Native stores remain plain local S03 stores. There is no engine per coordinator,
public opener, graph import or implicit cloud activation.
