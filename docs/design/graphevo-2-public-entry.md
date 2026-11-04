# H01 — public coordinated graph entry

Status: proposal for discussion, 2026-11-04. Documentation only. The proposed
signatures below are not available APIs and this draft does not authorize their
implementation. Approval of the contract precedes the implementation increment.
Read with [ownership](graphevo-2-graph-coordinator.md),
[controlled access](graphevo-2-controlled-store-access.md),
[custom sync](graphevo-2-custom-sync-transition.md),
[account isolation](graphevo-2-cloud-account-isolation.md),
[MF09](graphevo-2-local-v1-bootstrap.md),
[MF10](graphevo-2-authoritative-cloud-bootstrap.md) and
[MF11](graphevo-2-native-v1-migration.md).

## Outcome and first implementation boundary

An ordinary external Swift 6 application can create/reopen an exclusive S04
graph, use existing GraphStore operations, connect owner-private custom sync,
forward foreground activity and observe account/cloud availability. It can
explicitly convert a supported v1 source, publish that selected conversion as
MF10 authority and recover it on another device without converting that peer's
v1 copy. No test bridge, injected native adapter or package-only import is needed.

The first functional increment includes these connected paths and their public
consumer/demo verification. Public invitations and participant onboarding follow
separately; this contract does not expose the entire internal manager, migrate
old mirrored cloud zones or certify background delivery. Existing shared-engine
and permission safeguards remain in place internally.

## Explicit context and existing owners

The application creates `GraphContext()` and passes that instance to its features.
There is no public `.shared`, implicit default context or global service lookup.
Each context owns its ContextManager and its graph/connection lifetimes; production
construction uses the native adapter factory without routing all instances through
`GraphCoordinatorFactory.shared`. Low-level schema/registry/adapter injection
remains package-only. Existing singleton-based entry points are not an architectural
requirement for the new public path.

Within one context, matching requests share one coordinator and independent
GraphStore leases. Across contexts, overlapping graph/resource ownership is
refused while another context owns it; contexts do not silently join one another's
manager or allocate competing coordinators. Disjoint local graphs can progress
independently. Extend the existing admission boundary with context ownership as
needed, rather than adding an uncoordinated parallel ownership registry. Canonical
aliases, pending opens and failed native detach retain the same exclusion.

Process-wide ownership guards remain necessary. They reserve resources, not a
global application context: at most one context may own engines for a configured
CloudKit database at a time, even with different session directories. A conflicting
cloud connection is refused before native engine construction. Ordinary account
monitoring does not create an engine and may serve independently owned graphs.
Matching connection leases within the owning context reuse its manager-owned
private/shared engine pair.

The app controls its context's lifetime. Live graph/connection leases retain the
owner and required account monitoring even if the app drops its original context
reference. Final release drains cleanup; failed native cleanup retains exclusion.
Creating a new context cannot bypass quarantine or invalidate another context's
live handles. Tests can own independent contexts and resources without resetting
global application state.

New entry declarations target iOS 17/macOS 14, matching the selected CKSyncEngine
and native staged-conversion path. This does not raise the package-wide floor for
retained legacy APIs. The public product remains GraphEvo; native model factories,
Core Data contexts and runtime handles stay internal.

## Proposed local surface

The sketch defines call shapes and semantics, not a compilable interface file.
Supporting public values must be Sendable, have documented initializers and expose
only consumer-relevant fields.

```swift
// Proposed declarations, not available APIs.
public actor GraphContext {
    public init()
    public func createGraph(id: GraphID, at storeURL: URL,
                            conflictPolicy: GraphConflictPolicy = .lastEditWins)
        async throws -> GraphStore
    public func openGraph(id: GraphID, at storeURL: URL) async throws -> GraphStore
    public func connectCloud(using configuration: GraphCloudConnectionConfiguration)
        async throws -> GraphCloudConnection
    public func openGraph(convertingLocalV1 request: GraphV1BootstrapRequest)
        async throws -> GraphV1BootstrapResult
}
```

| Operation | Required behavior |
|---|---|
| Create | Explicit new GraphID and exact new SQLite URL; refuse an existing file. Matching admitted creations share one job. |
| Open | Require the selected existing graph, purpose marker and supported S04 store; never create, convert, reset or activate cloud implicitly. |
| Reopen | Resolve aliases into the existing ownership domain; preserve pending-request tokens, independent leases and retained claims on failed detach. |
| Close GraphStore | Close only that lease, drain admitted work on final release and retain ownership on failed native cleanup. It is not an export barrier. |

URLs are absolute file URLs to explicit `.sqlite` files. Validate configuration
before side effects; do not add name/directory resolution to this entry. Host
bootstrap persists its GraphID and request identifiers before first creation.
A missing file on a later launch is an opening error, not permission to replace
lost data with a new graph. No automatic incompatible-schema migration or
relabeling of historical alpha/mirrored files is introduced.

Cancellation before admission prevents an opening request. An existing-opening
waiter cancels only its own reservation; it cannot cancel other waiters. Once a
shared creation commits, return its usable handle even if that caller cancelled.
Closing cancellation never abandons native drainage or releases a failed claim.

Existing GraphStore read/mutation/query/attachment/observation APIs continue to
operate on the returned handle. The entry does not wrap them in a second data API.
Existing generic GraphStore/GraphDatabase openers remain explicitly documented
as their historical local paths; they neither become a custom-sync shortcut nor
silently reinterpret their files. The coordinated purpose marker still prevents
uncoordinated writable admission. Transitional mirroring is retired only when its
replacement callers have coverage; no replacement feature is added to it.

## Cloud connection, configuration and local availability

`GraphCloudConnection` is a consumer lease over manager-owned orchestration,
not a public CKSyncEngine or the internal GraphCloudSession actor.
`GraphCloudConnectionConfiguration` requires an explicit container identifier,
expected environment and exact account-bound session directory. Validated event
and byte limits retain the existing engine-document bounds. There is no implicit
Info.plist lookup, environment selection, CloudKit fallback store or migration.
The environment field namespaces expected state; it cannot change the host's
CloudKit entitlements.

`connectCloud` validates and reserves the configuration, installs observation
and returns a connection without waiting for network/account verification.
Its initial state is published before asynchronous verification starts. Invalid
configuration, conflicting ownership and an extension process throw without
creating native engines. Account/network unavailability is observable state,
not loss of the connection handle. Concurrent matching requests share startup;
cancelling a waiter cannot cancel another consumer's startup or abandon claims.

Proposed connection operations:

```swift
// Proposed declarations; result/support types are specified in the text below.
public actor GraphCloudConnection {
    public var state: GraphCloudConnectionState { get async throws }
    public func observeState() async throws -> GraphObservation<GraphCloudConnectionState>
    public func retry() async throws
    public func bindPrivateGraph(_ graph: GraphStore, zoneName: String) async throws
    public func setForegroundActive(_ active: Bool) async throws
    public func requestSynchronization() async throws
    public func notifyRemoteChanges(in scope: GraphCloudScope) async throws
    public func pauseSynchronization(for graphID: GraphID) async throws
    public func resumeSynchronization(for graphID: GraphID) async throws
    public func close() async throws
}
```

`GraphCloudConnectionState` distinguishes `verifyingAccount`, `ready`,
`temporarilyUnavailable`, `isolated(GraphCloudAccountState.IsolationReason)` and
`failed(GraphCloudConnectionFailure)`. Failure is a detached Sendable value with
bounded configuration/ownership/persistence/transport/recovery categories; it
contains no raw identity, native object, payload, URL or localized SDK dump.
Operation errors retain typed causes needed for recovery; cancellation remains
CancellationError. Public error mapping must not turn native cleanup quarantine
or durable commit into a generic retryable network error.

`ready` means account verification and session startup succeeded; it does not
mean a graph is bound, MF10 is published, a replica is imported or writes reached
a peer. State streams deliver initial/newest values, support cancellation and
finish when their lease closes. Observation refresh republishes current state;
`retry()` returns after scheduling a new account/startup check; subsequent
state carries its outcome. It never replays a consumer write
or migration body. A closed connection cannot restart through retry.

## Local opening of synchronized stores

Separating local opening from transport does not turn a synchronized store into
an unrestricted local store. On `openGraph`, the stored immutable cloud identity
determines whether account checks are required; the caller cannot disable them
by omitting `connectCloud`, pausing sync or stopping transport.

For an account-bound store the context installs account observation and schedules
identity verification as part of opening, without constructing CKSyncEngine,
starting a sync session, scanning for session directories or binding a new route.
The returned handle remains observable and isolated until verification succeeds.
The monitor uses the stored container/environment/account ownership and remains
owned for the lifetime of the live graph, pending work and required cleanup.
Connecting transport later reuses this account authority, rather than creating a
second authority that can independently unlock the graph. If observation stops,
invalidate cached verification before a later reopening; an unobserved gap must
not count as continuous verification.

A successful same-account verification can restore local access while transport
remains stopped or was never started in this process. Temporary unavailability
preserves access only for an identity already verified in this context's current
lifecycle. At cold start, failure to verify leaves the handle isolated; a previous
launch's verification is not reused as current proof. A later successful check
restores access subject to existing permission and migration restrictions.
If the monitor observes an identity boundary while transport is stopped, its
next startup must discard invalid SDK engine serialization while preserving PH,
frozen attempts, receipts, inbox entries and asset files. Reconnecting transport
cannot bypass that boundary by loading an older session document.
Unbound local-only stores need no CloudKit verification and remain usable
regardless of iCloud status.

Local and cloud availability are independent:

| Scenario | Local graph | Cloud connection |
|---|---|---|
| Unbound local store | Usable | Optional; no implicit binding |
| Bound store, cold startup | Opens an observable isolated handle; its account monitor verifies identity | Optional; no transport is needed for account verification |
| Verified account, transient outage | Local access retained | Suspended; retryable |
| Logout, switch or restriction | Data retained and ordinary access blocked | If connected, reports isolation |
| Verified original account returns | Access restored subject to other reservations/permissions, even with transport stopped | If connected, reconciles durable queues and invalid SDK state |

Use the existing `GraphStore.cloudAccountState` and its observation for per-graph
access decisions. Connection state never overrides account epochs, permissions,
manual pause, migration holds or authoritative activation. UI must invalidate
cached values on isolation; detached values already delivered cannot be recalled.

Account binding is immutable. This first surface takes an explicit account-bound
session directory and graph selection; it does not invent account discovery or
an automatic filesystem partition registry. A different account cannot reuse
that directory, GraphID or store under another identity. The host must explicitly
select a separate account configuration and graph/store, close the previous
connection before another identity starts engines for the same database, and
persist/distribute its selected cloud GraphID/zone. An existing connection remains
isolated when its account changes. Silent merge, deletion or moving data between
accounts is unsupported. Optional merge/delete policies remain backlog work.

## Binding, scheduling and lifetimes

`bindPrivateGraph` explicitly associates a graph owned by this context with one
stable private zone for the verified account. It preserves immutable bindings
and validates ownership and activation requirements before changing durable
state. It creates no share. A converted source requiring MF10 cannot bypass that
protocol through bind; an existing populated foreign cloud zone is not a valid
fresh destination merely because its name matches the request.

A GraphID/zone binding survives closing handles. Graphs eligible for foreground
scheduling retain T06's open/ready/bound requirements; a connection is not an
implicit permanent lease over every graph in the session document.

The app forwards aggregate scene activity. If multiple connection leases share a
session, foreground interest is the OR of their live requests; one inactive or
closing consumer cannot suspend another. `requestSynchronization()` and matching
container/scope notification hints schedule work; neither is a completion barrier.
The host filters push notifications for the configured container before forwarding
a scope. Foreground T06 timing, fair scheduling and durable queues remain the
implementation; this adds no background/APNs guarantee or progress percentage.
Per-graph pause drains its admitted sync work without cancelling unrelated graphs.

Closing one connection releases only its interest. Closing the final connection
explicitly stops/drains transport and releases engine ownership after successful
cleanup; it does not erase session state, unbind graphs or remove local data.
Live account-bound graphs retain manager-owned account monitoring even when
transport was explicitly stopped. They require a new connection for cloud restart.
A failed stop retains ownership/quarantine and is observable, rather than allowing
a competing engine. Caller cancellation cannot abandon cleanup. Dropped leases
must schedule the same cleanup path, with explicit close recommended for errors.

## Explicit migration and authoritative recovery

`GraphV1BootstrapRequest` exposes the existing MF09/MF11 consumer inputs: stopped
supported source URL, distinct destination URL, stable GraphID, operation UUID,
backup root and reason. Native staged conversion is the default; there is no
public automatic lightweight/staged selector or total-store byte cutoff. Known
legacy source validation, read-only protection, verified backup, bounded native
handlers, semantic sealing and native receipt/map stay library responsibilities.

`GraphV1BootstrapResult` preserves the committed conversion receipt/map, current
backup location, cleanup warnings and a separate `Result<GraphStore, Error>` for
opening. Before commit, failure throws. After commit, cancellation/opening/cleanup
failure must not hide the receipt or imply rollback. Retrying the same request
recovers durable progress without replaying converted data; ordinary later
launches open the destination directly. Unsupported native sources remain errors,
not a reason to choose an unbounded custom fallback.

Cloud activation is explicit and remains separate from conversion:

| Proposed operation on GraphCloudConnection | Existing owner/protocol |
|---|---|
| `prepareActivation(for:activationID:zoneName:declaration:)` | Manager MF10 local immutable seed and cutover-declaration validation |
| `advanceActivation(for:)` | MF10 native server claim/CAS, bounded seed upload and publication recovery |
| `activationStatus(for:)` | Durable phase, warnings and distinct availability; no inferred completion |
| `openReplica(id:at:zoneName:)` | MF10 exact published authority, empty or already-marked target, preserved logical identities |

Expose consumer request/status/result values with the existing protocol's
information and error distinctions. Do not publicly expose the generic internal
migration executor, adapters, native manifests, server field archives, PH tokens
or arbitrary transaction closures. Exact supporting value signatures must be
reviewed with the implementation against these existing results.

The host records which v1 source is authoritative, reconciles pending v1 writes,
stops old writers and prevents their return. A declaration records that host
decision; it does not prove global v1-cloud completeness. Peers use the same
GraphID/private zone and the replica path; they never independently convert and
upload their v1 copies into the authoritative graph. Published authority, local
opening, sync admission and independent peer recovery remain separate evidence.
No route discovery, authority transfer or old mirrored-zone adoption is implied.

## Verification required for implementation acceptance

1. An external Swift 6 consumer uses only `import GraphEvo` to create, reopen,
   mutate, query, observe, attach and close a coordinated graph. Concurrent
   features and alias URLs within one context share the owner. Cross-context
   overlap is refused, disjoint contexts progress independently and final-close
   failure retains exclusion even if another context attempts admission.
2. Matching connection leases share exactly one engine pair. Verify independent
   cancellation, foreground-interest aggregation, initial state ordering, final
   close during pending account startup, repeated notifications and failed cleanup.
3. Injected account scenarios cover cold bound opening without any cloud
   connection, transient access, logout, switch, restriction, same-account recovery
   with transport still stopped, and refused account-directory reuse. Local-only
   graphs remain usable with no account provider calls. Pausing/stopping transport
   cannot disable identity observation. Check that a boundary observed while
   transport is stopped invalidates older SDK serialization on later connection
   without losing durable queues. No graph is reported usable merely because the
   connection is ready.
4. A public consumer converts a supported v1 source and retains a committed
   receipt despite opening/cleanup failure. Repeating the request does not erase
   later v2 edits. Bootstrap excludes aliases and unresolved cloud startup.
5. GraphEvoDemo gets an explicit v2 flow built from the public surface. Demonstrate
   a local open, owner-private sync, converted authoritative seed and empty peer
   recovery without a package bridge. Preserve its existing user stores and use
   explicit test resources. No destructive v1/cloud cutover is automatic.
6. Review public error/value mappings and the migration/cloud API surface, then
   run the affected local checks and one full reviewed remote checkpoint on both
   platforms and both Swift 6 consumers before integration. Verify availability
   declarations for iOS 17/macOS 14; newer CI runtimes do not certify execution
   on the minimum supported OS. Document bounded device evidence separately; do not equate it with production acceptance.

The contract changes no schema, persisted format, source file or beta gate.
Physical account-change trials stay scheduled during beta before stable release.
Protected-data, independent-reader, production cutover and restoration gates keep
their current scope. Public invitation/UI integration, distribution audit,
background scheduling, format/schema reconciliation and broader device/cost
acceptance remain roadmap work.

## Decisions to confirm before implementation

- Use an explicitly constructed, application-owned GraphContext with its own
  manager and leased cloud connections. No singleton public context or implicit
  redirection to the legacy shared manager is proposed. Process/resource ownership
  remains enforced across instances.
- Keep local create/open, cloud connection/binding and v1 conversion/activation
  explicit. Return a cloud connection while account verification is pending;
  bound graph data stays isolated until verification. Account observation for a
  synchronized store starts on local opening, independently of transport.
- Deliver the first supported owner-private local/v1/cloud/peer flow together;
  public invitation onboarding follows separately.
- Keep account-specific resource selection explicit for this increment. Automatic
  account discovery, directory partitioning and graph-route distribution are not
  silently added to an opening method.
