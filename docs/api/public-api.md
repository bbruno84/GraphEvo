# GraphEvo — public API reference

GraphEvo is a Swift library for organizing connected data. It is built on Core
Data and supports both local stores and CloudKit-backed stores.

This document summarizes the public API, common usage patterns, and important
behavioral contracts. The source in `Sources/GraphEvo` and the test suite remain
the authoritative implementation references.

## 1. Module identity

```swift
import GraphEvo
```

- Public module: `GraphEvo`
- Supported platforms: iOS 16+, macOS 13+
- V2 development: the internal Swift 6 store runtime now supports awaited reads
  and transactions; these are package implementation boundaries, not new public
  Graph signatures. See the [A2 contract](../design/graphevo-2-async-transactions.md).
- Runtime dependencies: none beyond the Apple platform frameworks required by GraphEvo
- CloudKit backend: `NSPersistentCloudKitContainer` when configured

The public domain model consists of `Graph`, `Node`, `Entity`, `Relationship`,
`Action`, `Search`, and `Watch`.

## 2. Store configuration

```swift
public struct GraphStoreConfiguration {
    public var name: String
    public var location: URL
    public var backend: GraphStoreBackend
    public var appGroupIdentifier: String?
    public var cloudKitContainerIdentifier: String?
    public var requiredGraphModelVersion: Int
    public var requiredAppDataVersion: Int
    public var waitsForApplicationMigrations: Bool
    public private(set) var environment: GraphStoreEnvironment?
    public init()
    public func resolvingEnvironment() throws -> GraphStoreConfiguration
}
```

`location` is treated as an explicit SQLite file when its extension is
`.sqlite`; otherwise it is treated as a directory. For a directory, GraphEvo
builds `GraphEvo_<name>.sqlite`. An explicit file path is authoritative and is
never rewritten.

Important calculated properties include:

- `resolvedLocation`: the effective directory after App Group resolution;
- `storeURL`: the canonical URL calculated from the configuration;
- `legacyStoreURLs`: candidate legacy paths;
- `resolvedStoreURL`: the URL actually selected for opening.

GraphEvo internally identifies whether the resolved store is for CloudKit
Development, CloudKit Production, or local persistence. Directory-based
CloudKit stores select the environment automatically; Development stores use a
`-dev` filename suffix. `Graph(storeURL:)` always uses local persistence. The
environment is exposed as read-only `environment: GraphStoreEnvironment?`
(`development`, `production`, `local`). Before opening, call
`try configuration.resolvingEnvironment()` to obtain a normalized copy using
the same container precedence and environment resolver as Graph and
the migration ledger. It does not open or mutate a store; unavailable CloudKit
environment information throws. Use the returned copy for URL/scope decisions.
On iOS, Simulator or `DEBUG` builds use Development; other device builds use
Production. On macOS the CloudKit environment entitlement must be available.
See [CloudKit configuration](../concepts/cloudkit.md#configuration).
Applications cannot set the environment. XCTest retains its existing simulated
Development resolution and does not establish actual CloudKit availability.

For `.inMemory`, URLs are still calculated for consistency but do not identify a
persistent file. `appGroupIdentifier` affects directory-based configurations;
it does not move an explicit SQLite file.

## 3. `Graph`

```swift
public init(configuration: GraphStoreConfiguration,
            migrationEnabled: Bool = true,
            preflight: (() throws -> Void)? = nil)
public init(storeURL: URL,
            backend: GraphStoreBackend = .sqlite,
            migrationEnabled: Bool = true)
```

`Graph(storeURL:)` always opens the supplied store as local persistence. It
does not inherit a CloudKit container identifier from `Graph`, configuration,
or `Info.plist`.

`Graph` opens a store and owns the Core Data context used by the public facades.
An optional synchronous `preflight` validates application opening policy before
any ledger or store activity. Its failure reports failed readiness using
`applicationMigrationFailed`, including when migrations are disabled or their
ledger is already complete. The default preserves existing behavior. Keep this
callback read-only; do not open another Graph or do asynchronous work inside it.
Use `whenReady` when opening must be coordinated explicitly:

```swift
let graph = Graph(configuration: configuration)
graph.whenReady { result in
    switch result {
    case .success(let graph): graph.sync()
    case .failure(let error): print(error.localizedDescription)
    }
}
```

Common properties and operations include `name`, `configuration`, `readiness`,
`isReady`, `batchSize`, `batchOffset`, and `eventDelegate`,
`sync()`, `async()`, `clear()`, `reset()`, `newBackgroundContext()`, and
`whenReady(_:)`.

`GraphReadiness` describes technical store availability:

```swift
public enum GraphReadiness {
    case initializing
    case ready
    case failed(GraphStoreOpeningError)
}
```

`GraphStoreOpeningError` includes incompatible, unreadable, failed-to-load,
environment, registry-conflict, incompatible-registered-store, and required
application-migration failure cases. An incompatible store is not changed
automatically.

## 4. Nodes and domain objects

`Node.setCreatedDate(_:)` preserves an imported creation timestamp on an existing
node without changing its persistent ID. Save through `sync` or an enclosing
`Graph.transaction`.

### Committed read snapshots

`Graph.readSnapshot<T>(_ body: (Graph) throws -> T) throws -> T` creates a
private read context on the current store coordinator. Call it from a worker
queue, use synchronous searches, and return detached values, never Node or
managed-object instances. SQLite snapshots are pinned to a query generation;
in-memory stores provide context isolation but not generation pinning. The
snapshot excludes unsaved view-context edits and does not save, merge or reset
the view context. Search errors propagate out of the snapshot. Mutations cause
`GraphTransactionError.readOnlySnapshotModified`; nested transactions/saves are
unsupported. The scoped facade must not escape the closure. This is a committed
local-store view, not a CloudKit completion guarantee.

### Required application migrations and scoped transactions

`GraphStoreConfiguration.waitsForApplicationMigrations` defaults to `false`.
When enabled, no persistent context is opened until asynchronous `.preInit`
work finishes successfully. All subsequent migration phases must also succeed
before readiness becomes `.ready`. A migration or ledger failure reports
`GraphStoreOpeningError.applicationMigrationFailed(underlying:)`.

`GraphMigrationManager.handlePhaseResult(_:configuration:graph:completion:)`
returns `Result<Void, Error>`. The existing completion-only overload preserves
its diagnostic-only failure contract.

`Graph.transaction<T>(_ body: (Graph) throws -> T) throws -> T` supplies an
isolated, pinned private-context facade and saves once after the body succeeds.
Only return value snapshots; do not retain its Graph/Nodes or call `sync` inside
the body. Errors roll back the private context. Existing object IDs and store
metadata remain unchanged. Pending view-context edits cause a retryable error.
This check runs both before computation and immediately before commit. The view
queue is held only for the final check/save/merge, protecting edits made while
the private body was running without holding the UI queue during computation.
SQLite generation changes detected before save and optimistic locking conflicts
fail the transaction. This does not stop external CloudKit imports: concurrent
insertions after the last generation check must be handled by a subsequent
idempotent reconciliation pass. No filesystem replacement is performed.

Before a commit containing deletions, registered view objects updated or deleted
by that transaction are refaulted while the view is verified clean. This prevents
stale materialized property relationships from leaving already-saved deletions
pending in the view context. The commit is merged using object IDs, not private
context objects. Read-only transactions do not refresh objects; unrelated view
objects and genuine unsaved edits are preserved.

Retained whole-node deletions can still remain pending after Core Data's merge.
The transaction finalizes the view context only when its entire pending set is
made of deletions whose IDs were reported deleted by this successful private
save, with no changed fields, inserts, updates or unrelated deletions. This is
not a general-purpose automatic save or rollback of user changes. SQLite tests
verify that this finalization creates no additional persistent-history
transaction and that the deferred automatic merge leaves the view clean.
Automatic merging stays enabled; CloudKit imports are not suspended. A failure
during finalization is propagated even though the private commit has succeeded;
callers must retain their idempotent retry semantics.

Pending view changes also emit `GraphFailure.transaction(underlying:diagnostics:)`
through `GraphEventDelegate`, while still throwing the original
`GraphTransactionError.pendingUserChanges` (NSError code 1). The error now has a
readable `LocalizedError` description. `GraphTransactionDiagnostics` distinguishes
`beforeBody` from `beforeCommit` and reports actual container kind, object counts,
and up to 20 groups of Core Data entity/schema keys and current-event keys.
Its `summary` contains no property values, dynamic domain names/keys, object IDs,
paths or account identifiers. Diagnostics neither save nor discard pending changes.
The host application owns logging; GraphEvo does not write these events to a log.

In DEBUG builds, rejected transactions also populate `debugDetails` with dynamic
property names, changed fields' committed/current values, object URI IDs and
materialized owner type/properties, and whole nodes' type/properties (including
deleted nodes when still materialized). These details can contain sensitive data;
applications must explicitly choose whether to log them. Release builds always
return an empty detail list. The DEBUG-only
`graph.pendingChangeDiagnostics(checkpoint:)` captures the same details without
attempting a transaction or emitting a failure. It can also report a clean
context at an application lifecycle checkpoint.

Details are bounded to 100 changed objects, 40 materialized owner properties,
and 2,048 characters per textual value. Binary data reports byte count and its
first 64 bytes in base64. Faults are identified without forcing their values;
no permanent IDs are allocated. Committed values are the context's committed
snapshot, not an independent disk read. No stack trace or write-origin tracking
is implied by this diagnostic.


`Node` is the common base for all public graph objects. It exposes `graph`,
`type`, `id`, `createdDate`, dynamic property access through
`node[dynamicMember: "key"]`, tags, groups, and `delete()`.

### `Entity`

```swift
public init(_ type: String, graph: Graph)
```

An `Entity` is a domain object with dynamic properties, tags, groups,
relationships, and actions. Use `Entity` rather than Core Data `Managed*`
classes.

```swift
let user = Entity("User", graph: graph)
user[dynamicMember: "email"] = "ada@example.com"
user.add(tags: "active")
```

Relationship and action shortcuts include `is(relationship:)`, `will(action:)`,
and `did(action:)`.

### `Relationship`

A relationship is a directed, typed edge with `subject` and `object` entities.
It can be created fluently:

```swift
user.is(relationship: "writes").of(note)
```

The related accessors distinguish `relationshipsWhenSubject` and
`relationshipsWhenObject`.

### `Action`

An action represents an event with one or more `subjects` and `objects`:

```swift
let review = user.will(action: "reviews")
review.add(objects: note)
```

`subjects`, `objects`, `actionsWhenSubject`, and `actionsWhenObject` expose the
associated domain entities.

### Tags and groups

Node mutations are fluent and set-based:

```swift
user.add(tags: "active", "verified")
user.remove(tags: "verified")
user.toggle(tags: "featured")
user.add(to: "authors")
```

`has(tags:using:)` supports `.and` and `.or`. Tags and groups do not contain
duplicates.

## 5. Predicates and search

`Predicate` provides typed constructors such as `.type`, `.exists`, `.has`, and
`.member`, together with property comparisons and the operators `&&`, `||`, and
`!`. String comparisons are case- and diacritic-insensitive.

```swift
let filter = (.type("User") && .has(tags: "active")) || .type("Admin")
let users = Search<Entity>(graph: graph).where(filter).sync()
```

`Search<T>` supports `Entity`, `Relationship`, and `Action`:

```swift
public init(graph: Graph = Graph(configuration: GraphStoreConfiguration()))
public func `where`(_ predicate: Predicate) -> Search<T>
public func clear() -> Search<T>
public func sync(completion: (([T]) -> Void)? = nil) -> [T]
public func async(completion: @escaping ([T]) -> Void)
```

Successive `where` calls are combined with OR. Searches combined with `+` must
belong to the same graph. A search without a predicate returns an empty array.
Use `.where(.type("*"))` to fetch all types in the selected node family.
`batchSize` sets Core Data's fetch batch size, not a result limit; `batchOffset`
sets the fetch offset. Searches do not impose sorting or stable pagination.

## 6. Watchers

`Watch<T>` observes changes to typed nodes:

```swift
public init(graph: Graph)
public weak var delegate: GraphNodeDelegate?
public var isRunning: Bool { get }
public func clear() -> Watch<T>
public func `where`(_ predicate: Predicate) -> Watch<T>
public func resume() -> Watch<T>
public func pause() -> Watch<T>
```

Watchers start stopped. `resume()` begins observation, `pause()` suspends it,
and `clear()` removes its filter. Use `GraphEntityDelegate`,
`GraphRelationshipDelegate`, or `GraphActionDelegate` according to `T`.
Callbacks cover insertion, update, deletion, property changes, tag changes, and
group membership changes. `GraphSource.local` and `.cloud` identify the change
source.

### Aggregated Watch reports

`Graph` also exposes an optional Graph-level batch path. It does not inherit or
apply predicates from individual `Watch` instances:

```swift
public enum GraphWatchEvent { /* typed Entity, Relationship, and Action cases */ }

public final class GraphWatchReport {
    public let graph: Graph
    public let source: GraphSource
    public let events: [GraphWatchEvent]
    public let structuralValidationResults: [GraphStructuralValidationResult]
    public let unmaterializedDeletions: [GraphWatchUnmaterializedDeletion]
}

public struct GraphWatchUnmaterializedDeletion {
    public let objectID: NSManagedObjectID
    public let error: Error
}

public typealias GraphWatchReportCompletion = (_ report: GraphWatchReport?, _ error: Error?) -> Void

public var Graph.watchReportCompletion: GraphWatchReportCompletion?
public var Graph.watchReportSources: Set<GraphSource>
```

`GraphWatchEvent` has one case for every atomic Watch callback: node insertion
and deletion, relationship update, and property, tag, and group addition,
update, or removal for the supported node family. Deleted events retain the
same `Entity`, `Relationship`, or `Action` wrappers used by legacy Watch.

Reports contain at least one typed event or unmaterialized deletion reference,
are immutable, and are delivered on the main thread. They are
not `Sendable`; their objects remain tied to the Graph managed object context.
The completion receives `(report, nil)` after a successful delivery. History
fetch, token, and processing failures can produce `(nil, error)`. A Persistent
History retention gap may produce `(report, error)` for best-effort delivery,
or `(nil, error)` if no retained events remain. Materialization and structural
validation failures on surviving events are retryable: no completion is called,
a warning is emitted, and the batch delivery token remains unchanged. Local
reports omit invalid owners and emit errors without a persistent retry cursor.
The default source set is `[.local, .cloud]`. Restrict it before
assigning the completion when only one source is wanted.

Batch reporting and legacy watchers are parallel. Enabling reports does not
disable atomic callbacks, so applications must not process both paths as the
same logical consumer unless duplicate handling is intentional.

## 7. Events and CloudKit

```swift
public enum GraphPersistenceMode { case local; case cloud; case localFallback }
public enum GraphState {
    case readiness(GraphReadiness)
    case cloudStatus(GraphCloudStatus)
    case persistenceMode(GraphPersistenceMode)
    case cloudSetup(GraphCloudSetupState)
    case cloudImport(GraphCloudImportState)
    case cloudUpload(GraphCloudUploadState)
}
public enum GraphCloudSetupState {
    case started(GraphCloudSetupEvent)
    case finished(GraphCloudSetupEvent)
}
public struct GraphCloudSetupEvent {
    public let identifier: UUID
    public let storeIdentifier: String
    public let startDate: Date?
    public let endDate: Date?
    public let succeeded: Bool
    public let error: Error?
}
public enum GraphEvent {
    case transactionDiagnostic(GraphTransactionTrace)
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}
// GraphFailure additionally reports watchEventMaterialization when one
// change cannot be represented while the remaining batch continues.
public enum GraphCloudImportState {
    case started(GraphCloudImportEvent)
    case finished(GraphCloudImportEvent)
}
public struct GraphCloudImportEvent {
    public let identifier: UUID?
    public let storeIdentifier: String
    public let isInitialImport: Bool
    public let succeeded: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let error: Error?
}
public enum GraphCloudUploadState {
    case started(GraphCloudUploadEvent)
    case finished(GraphCloudUploadEvent)
}
public struct GraphCloudUploadEvent {
    public let identifier: UUID
    public let storeIdentifier: String
    public let startDate: Date?
    public let endDate: Date?
    public let succeeded: Bool
    public let error: Error?
}
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}
```

Events are delivered on the main thread. States and warnings are not printed
automatically; the application decides how to log them. Unrecoverable errors
remain available as minimal diagnostics.

CloudKit container precedence is explicit configuration, runtime
`Graph.cloudKitContainerIdentifier`, then the
`GraphCloudKitContainerIdentifier` Info.plist key. Without an identifier the
graph remains local. If CloudKit is unavailable, GraphEvo may emit
`GraphWarning.cloudStoreFallback` and use a local fallback after a container
load failure. Earlier environment, compatibility, and registry failures still
fail opening; later synchronization errors do not switch persistence mode.

`purgeCloudStore(completion:)` is restricted to a loaded CloudKit container and
uses Apple's purge of records and corresponding managed objects. It does not
delete or recreate local SQLite files. During purge, saves and transactions
fail with `GraphCloudPurgeError.writesBlockedDuringPurge`. After successful Apple
completion, the view context is reset and writes are enabled before the app's
callback. Clients reload cached nodes in that callback, without reopening the
Graph. Clients must stop their own raw-context writers during purge.
Errors also release the gate. No thread-owned lock is held
across Apple's asynchronous callback. Import and export lifecycle
updates are delivered through `GraphEventDelegate`.

## 8. Persistent History

`Graph.resetLocalStore(configuration:beforeReset:)` is a pre-open local-replica
reset. It normalizes configuration and refuses an in-process registered Graph
under the store-opening lock. The required throwing callback receives the exact
URL so the caller can back up and persist its scoped intent first. Callback
failure leaves the store untouched. Do not open a Graph from that callback.
Destruction uses Core Data's SQLite API with force-destruction disabled, preserving
its lock/journal handling; errors propagate. No CloudKit container is created and
no remote deletion is sent. Applications own restart, durable reset recovery,
backup verification and preventing replay of historical migration sources.

```swift
@objc func ph_prepareOnLaunchAfterContainerReady()
```

Graph calls the preparation method after a successful CloudKit store open;
applications may call it again after readiness. Processing and batch methods
are internal. GraphEvo filters local-authored transactions, merges object
changes, and persists the processing token before legacy watcher delivery.
Aggregated reports use a separate delivery token that can remain behind while
surviving events fail materialization or structural validation.
Corrupt, expired (`134301`), or
missing-store (`134501`) tokens are recovered at the current history head and
reported through `GraphWarning.persistentHistoryRecovery`.

`ph_debug_*` helpers are public test/diagnostic seams and are not an application
contract.

## 9. Migrations

```swift
public protocol GraphMigration {
    var id: String { get }
    var version: Int { get }
    func handlePhase(... completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(...) -> Bool
}

GraphMigrationManager.registerMigration(migration)
```

Lifecycle phases are `.preInit`, `.postInit`, `.postMigration`, and `.ready`.
Graph executes all four phases automatically in that order. Registration is
once per migration ID and follows registration order.

`GraphMigrationResult` includes `.done`, `.error(Error)`, `.fallback`, and
`.skipped`. `GraphMigrationContext` passes values between phases and exposes
`previousMigrationRecord` and `migrationStateSnapshot`. The snapshot supports
idempotent recovery decisions after an interrupted attempt. The versioned ledger records `started`, `done`,
`notRequired`, `notExecuted`, and `failed` states. Runtime queues and contexts
are isolated per normalized store scope; applications continue to provide only
a `GraphStoreConfiguration`.

`GraphMigrationManager` also supports `record(for:configuration:)` and the
throwing `recordThrowing(for:configuration:)`. Diagnostic clients can read
immutable history and state snapshots through `history(for:configuration:)`
and `stateSnapshot(for:configuration:)`. It also supports
`resetRecord(for:configuration:)`, the additive reset overload accepting
multiple targets, requester and reason, and
`forceMigration(_:configuration:requestedBy:reason:)` for a one-shot local
force request. `GraphMigrationRequestedBy` includes `.system`,
`.migrationManager`, `.supportCenter`, `.user`, and `.recovery`.
Reset and force requests preserve ledger history. Application migration errors
are delivered as `GraphFailure.migration`; environment routing, scope keys, and
KVS projection details remain internal to GraphEvo.

A rejected KVS completion publication remains pending without changing a
successfully completed local migration to `failed`. Local ledger errors still
propagate. Publication retries preserve a newer validated remote projection
already visible or observed, retiring superseded pending work without claiming
it was published. This does not provide distributed locking or remote delivery
acknowledgement.

New remote reset requests observe visible KVS state before allocating a generation
above the highest known generation. Local-only resets do not consult KVS, and
publication retries do not allocate a new operation or generation.

`GraphMigrationLedgerEntry` is a public, immutable, `Codable` diagnostic value.
It includes the migration state, phase, operation and generation identifiers,
request origin, pseudonymous device identifier, application and model versions,
backup reference, decision metadata, source, timestamps, store scope, and any
error or reset reason. `GraphMigrationDecisionReason` and
`GraphMigrationDecisionSource` are public supporting enums.

The internal schema-1 ledger keeps its current projection separate from its
append-only history and transaction journal. Recovery is driven by the
`migrationStateSnapshot` passed to `needsRun`; an interrupted attempt is
evaluated in its originally recorded lifecycle phase.

`MigrationBackupManager` backs up SQLite files and their optional WAL/SHM
sidecars. `ConflictPolicy` supports `.duplicate`, `.skip`, and `.overwrite`.
File logging is disabled by default and can be enabled with
`GraphMigrationLogger.fileLoggingEnabled = true`.

## Application-owned metadata

A migration can store small additional Codable values in its local ledger:
`GraphMigrationManager.setMetadata(_:forKey:for:configuration:)`,
`metadata(_:forKey:for:configuration:)`, and
`removeMetadata(forKey:for:configuration:)`. The read method takes the expected
Decodable type and returns nil only for a missing key; decoding and ledger
errors propagate. The application owns schema versions, payload validation,
meaning and operation-level idempotency. GraphEvo does not interpret payloads.

Values are JSON-encoded with sorted keys and dates in milliseconds since 1970.
Keys must be nonempty and at most 256 UTF-8 bytes; total encoded metadata is
limited to 64 KiB per migration/store/version. Use backups for large artifacts.
Identical encoded writes and missing-key removals are no-ops. Writes/removals
are journaled and serialized; they do not change migration execution state,
query domain objects or synchronize through KVS. Evaluation resets and failed
attempts preserve metadata.

A changed save/removal posts `.graphMigrationMetadataDidChange` on the main
queue. Its `GraphMigrationMetadataChange` object exposes `storeScope`,
`migrationID`, `version` and `key`, not application payloads. Filter these
fields and reread the value; another write may already have followed it.
Read on launch/store changes as well: notifications are transient and journal
replay does not emit a new event.

The superseded rc.11 domain-specific API has been removed before stable release.
Its optional JSON extension remains readable under its original metadata key
and survives unrelated writes without interpretation. Writing/removing that
key replaces/removes the old extension too.

## 10. Utilities

Public utility types include `Model`, `GraphJSON`, `AnyCodable`,
`AnyCodableObject`, `NSArrayOfAnyCodableObject`,
`DictionaryOfAnyCodableObject`, `GraphArchiver`, `GraphValueTransformer`,
`File`, and `GraphStoreMetadata`.

Use `GraphValueTransformer.register()` when configuring a model manually.
`GraphStoreMetadata` handles compatibility/version metadata but does not
replace semantic data migrations.

## 11. Merge and deduplication

`GraphMergeEngine` imports entities from a secondary graph, recreates
relationships and actions, and returns `GraphMergeReport`. Imported entities
receive a `source` property.

`GraphDedupEngine.deduplicate(in:configuration:)` is the general-purpose
deduplication entry point. Configure a `DedupKeyProvider`, a
`DedupSurvivorSelector`, and, when needed, a custom `DedupMetadataMerger`.
`UUIDFieldKeyProvider` supplies the standard UUID-field strategy.

The default link policy rewires and deduplicates both relationships and
actions. Metadata copies only missing properties and merges tags and groups
without duplicates. The engine may delete objects and rewrite links; create a
backup before running it on production data.

## 12. Unsupported implementation details

Core Data `Managed*` classes, `Container`, `Context`, registries, coordinators,
and `internal`/`fileprivate` helpers are not public API contracts. Use the
`Entity`, `Relationship`, and `Action` facades.

## 13. Integration checklist

1. Configure `GraphStoreConfiguration` and, when needed, CloudKit.
2. Create `Graph` and handle `whenReady` or `eventDelegate`.
3. Create nodes through `Entity(type, graph:)`, mutate properties, and call
   `sync`.
4. Use `Search` for queries and `Watch` for local/CloudKit callbacks.
5. Let Graph prepare Persistent History on CloudKit opening; observe changes
   through Watch or aggregated reports.
6. Register migrations before creating the graph and back up before modifying a
   SQLite store.
7. Handle `GraphStoreOpeningError.incompatibleStore` explicitly; GraphEvo
   leaves incompatible stores unchanged.


## Structural validation

Available on `Entity`, `Relationship`, and `Action` through `Node`:

```swift
public func validateStructure() -> GraphStructuralValidationResult

public enum GraphStructuralReferenceState: String {
    case absent, unresolved, materialized
}

public struct GraphStructuralReference {
    public let sourceObjectID: NSManagedObjectID?
    public let relationshipName: String?
    public let destinationObjectID: NSManagedObjectID?
    public let state: GraphStructuralReferenceState
    public let error: Error?
}

public struct GraphStructuralValidationResult {
    public let objectID: NSManagedObjectID
    public let references: [GraphStructuralReference]
    public var issues: [GraphStructuralReference] { get }
    public var isValid: Bool { get }
}

public enum GraphStructuralValidationError: LocalizedError {
    case missingContext, missingStore, notPersisted, objectNotFound, unexpectedEntity
    public var errorDescription: String? { get }
}

public struct GraphStructuralValidationFailure: LocalizedError {
    public let result: GraphStructuralValidationResult
    public var errorDescription: String? { get }
}
```

This synchronous API checks saved local state, ignoring pending edits. Call it
on the owning context queue. Optional absent references are informational;
unresolved references fail validation. Results contain local object IDs rather
than context-bound facades. They do not refresh the caller's objects.

Entity validation includes direct relationship/action details and endpoint
materialization. Endpoint entities' own relationships are not traversed.
Relationship and Action validation materializes their endpoints/participants
without recursing. All root and edge properties, tags and groups are checked.

Watch reports expose validation results for surviving event owners. Cloud
Persistent History batches retain their delivery token on structural failure;
local batches preserve best-effort delivery. Deleted owners are excluded.
Warnings/errors expose `GraphStructuralValidationFailure.result` with details.
The validator itself does not retry or enforce delivery policy.

See [Structural validation](../guides/structural-validation.md) for the complete
scope, result semantics, deletion handling, and saved-state limitations.


Structural validation preserves property decoder errors as unresolved reference
causes, while optional nil values remain valid. For Watch delivery, retained
local deletion records can supersede pending remote events without producing
cloud callbacks. An entirely superseded interval is consumed silently; absence
alone is not evidence of deletion.


### Optional creation dates

```swift
public var Node.createdDate: Date { get }
public var Node.createdDateIfPresent: Date? { get }
```

`createdDateIfPresent` reads the value in the facade's context, including pending
edits. `createdDate` preserves its nonoptional signature and returns
`Date.distantPast` if the value is absent. This fallback is not written to the
context/store. Node encoding omits an absent `createdDate` rather than encoding
the fallback. Existing date values and `setCreatedDate(_:)` are unchanged.

### Confirmed deletions without reconstructable event details

Cloud history discards inserts/updates superseded by retained deletions.
Remote deletion events are still reconstructed when possible. When the former
owner or payload cannot be recovered, `unmaterializedDeletions` carries the
deleted local object ID and the reconstruction error. Its ID is intended for
invalidation, not for fetching the deleted object. Such a report can have an
empty `events` array and a nonempty `unmaterializedDeletions` array.

Confirmed deletion evidence is deliverable and advances the delivery token;
failed materialization or validation of surviving objects still retains the
whole batch. Missing rows alone remain insufficient evidence of deletion.

## CloudKit node identity

```swift
public func Graph.cloudRecordID(for node: Node) throws -> CKRecord.ID?
public func Graph.cloudRecordIDs(for nodes: [Node]) throws -> [CKRecord.ID?]

public enum GraphCloudRecordIdentityError: Error, Equatable, LocalizedError {
    case unavailableContext
    case foreignContext
    case unavailableContainer
    case inconsistentContainer
}
```

Both methods address the main Core Data node underlying an `Entity`,
`Relationship`, or `Action`, never its separate property records. They use
Apple's public `NSPersistentCloudKitContainer.recordIDs(for:)` mapping API.
The single method delegates to the batch path.

Call on the receiving Graph's context queue, using nodes from that same context.
Inside `transaction` or `readSnapshot`, use the supplied Graph facade and fetch
nodes there. A node from another context is rejected even if its store is the
same. Results contain complete `CKRecord.ID` values, including zone identities.

The batch preserves input order, count and duplicates; an empty batch returns
`[]`. Invalid input throws before any mapping lookup, including on local stores.
`unavailableContext` covers a missing graph/node context or unloaded context
store; `foreignContext` indicates a node from another context;
`unavailableContainer` means no lookup container is available;
`inconsistentContainer` indicates incompatible coordinator/store ownership.

Normal identity absence is `nil`: local/fallback mode, an unsaved node (including
one already assigned a permanent ID), pending deletion, or no mapping returned
by Apple. These causes are not distinguished. An invalidated/detached facade is
an API error, not a missing mapping. There is no cache, implicit save, permanent
ID allocation, export request or network request added by this wrapper.

The result reflects metadata available at lookup time. Even inside
`readSnapshot`, identity metadata is not guaranteed to share the pinned data
generation. An identity is not proof of export, sync or structural completeness.
Container, environment, database and account are comparison context external
to `CKRecord.ID`. See [CloudKit identity](../concepts/cloudkit.md#node-record-identity).


## Opt-in transaction diagnostics

```swift
public func Graph.transaction<T>(diagnosticID: UUID, _ body: (Graph) throws -> T) throws -> T
```

The original `transaction(_:)` API remains unchanged and does not collect these
traces or query history. The overload preserves the same result, thrown error,
save/rollback behavior and generation guard. Reuse the application's attempt
UUID; GraphEvo does not allocate a competing correlation identity.

Two `GraphEvent.transactionDiagnostic(GraphTransactionTrace)` events are queued
on the main queue, never delivered synchronously by the overload. The first has
`phase == .outcome`, after transaction context scopes have unwound and rollback
has finished when required. History is read afterward on a separate utility
context, producing a `.history` supplement. The transaction return does not
wait for either callback or history collection. Delivery requires the Graph and
process to remain alive; persist the outcome even if no supplement arrives.
Early failures and successful no-op bodies also produce both phases when the
Graph remains available. Existing error events are not suppressed or changed.

`GraphTransactionTrace` and all nested types are `Codable`:

| Field | Type and meaning |
|---|---|
| `diagnosticID` | Caller-supplied `UUID` |
| `phase` | `.outcome` or `.history` |
| `startedAt`, `finishedAt` | Wall-clock `Date` boundaries |
| `outcome` | `.succeeded` or `.failed`, matching method result |
| `didSave` | Whether the private context save succeeded; can be true if later merge failed |
| `checkpoints` | Bounded checkpoint array; empty on the history supplement |
| `errorDomain`, `errorCode` | Optional original NSError identity, without description/userInfo |
| `history` | Optional history summary, present on the supplement |

Checkpoint fields are `stage`, monotonic `elapsed` seconds from entry,
optional `inserted`/`updated`/`deleted` staged counts, and optional
`generationsEqual`. Stages are `.begin`, `.pinned`, `.bodyEnd`,
`.precommitCompare`, `.saveResult`, `.rollbackResult`, `.finished`.
Absent stages do not imply success: early failures never enter the body,
no-op bodies do not save/compare generations, and non-SQLite stores do not run
the SQLite comparison. `.pinned` indicates completion of context preparation;
only SQLite contexts actually pin a query generation. `.saveResult` marks a
successful private save, while `.rollbackResult` records the completed rollback.

History fields are `status` (`.available`/`.unavailable`), `from`, `through`,
`observedChanges`, `groups`, `truncated`, `isExhaustive`, and optional
`errorDomain`/`errorCode`. Each group contains optional `author`, `entityName`
(Core Data schema, not the node's domain type), `operation` and `count`.
No node payloads, changed values, tombstones, object IDs, or generation-token
bytes are included.

The history read first counts changes since entry. Above 512 it skips detail
materialization and returns `available`, `truncated: true`, zero observed changes
and no groups. This count conservatively includes changes after the outcome.
Otherwise, detail reads use the wall-clock interval; output is capped at 512
observed changes, 64 groups and 128 characters per author/schema name. Count
and detail reads are not atomic; concurrent history can grow between them, so
these caps are not a hard bound on all internal Core Data work. Truncation is
flagged. `isExhaustive` is always false: retention, bookkeeping, wall-clock
adjustments and the non-atomic interval prevent completeness or causal claims.

A zero count with `truncated == true` means details were omitted, not that no
writes happened. History failures produce an unavailable supplement and never
change the original transaction result. No retries or alternative conflict
checks are introduced. Consumers with exhaustive `GraphEvent` switches must
handle the new diagnostic case. A consumer may correlate terminal application
state, outcome, and history in any arrival order using the UUID.


## GraphEvo 2 alpha model contracts

The following additive types are available through `import GraphEvo`. They are
implemented in the Swift 6 GraphEvoModel target and do not open a store. The typed GraphStore opening gateway is described below; legacy Graph remains
available for v1 stores. See the
[A3 guide](../design/graphevo-2-application-models.md) for scope and limitations.

- `GraphID(rawValue: UUID = UUID())`: Sendable, Hashable, Codable graph identity;
  read-only `rawValue`.
- `GraphNodeID(graphID: GraphID, rawValue: UUID = UUID())`: Sendable, Hashable,
  Codable node identity; read-only `graphID` and `rawValue`.
- `GraphNodeKind`: `.entity`, `.relationship`, `.action`.
- `GraphEndpoints`: `.entity`, `.relationship(subject: GraphNodeID?, object:
  GraphNodeID?)`, `.action(subjects: Set<GraphNodeID>, objects: Set<GraphNodeID>)`;
  read-only `kind`.
- `GraphValue`: `.null`, `.boolean(Bool)`, `.integer(Int64)`,
  `.unsignedInteger(UInt64)`, `.floatingPoint(Double)`, `.decimal(Decimal)`,
  `.string(String)`, `.data(Data)`, `.date(Date)`, `.url(URL)`, `.uuid(UUID)`,
  `.array([GraphValue])`, `.object([String: GraphValue])`,
  `.encoded(GraphEncodedValue)`; Sendable and Equatable.
- `GraphEncodedValue(codec: String, version: UInt, data: Data) throws`: read-only
  codec/version/data; unknown codecs retain bytes without implicit execution.
- `GraphPropertyValue: Sendable`: `var graphValue: GraphValue { get }` and
  `init(graphValue: GraphValue) throws`. Conformances: GraphValue,
  GraphEncodedValue, String, Bool, Int, Int64, UInt64, Double, Decimal, Data,
  Date, URL, UUID, and conditional Optional, Array and string-keyed Dictionary.
- `GraphRecord(id:type:endpoints:properties:tags:groups:createdDate:) throws`:
  read-only fields; endpoints defaults to `.entity`, properties/tags/groups to
  empty and creation date to nil. Type/property keys must be nonempty and
  references must have the same graph ID.
- `GraphRecord.value<Value: GraphPropertyValue>(for:as:) throws -> Value`:
  defaults `as` to Value.self; missing keys and failed typed decoding differ.
- `GraphModel: Sendable`: read-only `id: GraphNodeID`; static `graphType: String`
  and `graphKind: GraphNodeKind`; `init(graphRecord: GraphRecord) throws` and
  `graphRecord() throws -> GraphRecord`.
- `GraphRecord.init<Model: GraphModel>(_ model: Model) throws` and
  `decoded<Model: GraphModel>(as: Model.Type = Model.self) throws -> Model`:
  checked mapping validates type, kind and identity. Application decoding and
  semantic validation belong to the consumer; their errors propagate unchanged.
  Optional application versions are ordinary properties, with no registration.
- `GraphPropertyChange`: `.set(GraphValue)` and `.remove`; setting null is
  distinct from removing a property in the detached contract.
- `GraphRecordPatch(id:properties:addingTags:removingTags:addingGroups:
  removingGroups:endpoints:) throws`: defaults all changes to empty/unchanged;
  read-only matching fields. `applying(to: GraphRecord) throws -> GraphRecord`
  preserves unknown fields and metadata, rejecting identity/kind conflicts.
- `GraphModelError`: `invalidRecord(String)`, `invalidValue`,
  `missingProperty(String)`, `propertyDecodingFailed(String, underlying: Error)`,
  `unexpectedType`, `unexpectedKind`, `identityMismatch`, `crossGraphReference`,
  `conflictingPatch`, `unsupportedLegacyValue(String)`; LocalizedError.

These detached values alone do not establish persistent membership, resolve
endpoint existence or commit edits. The typed persistence scopes below supply
identity, reference checks and value envelopes. Application compatibility is
consumer-owned; raw access and non-materializing queries do not classify formats.
See [consumer data](../design/graphevo-2-data-formats.md).
On the matrix experiment branch,
top-level Data uses a length-checked versioned binary envelope with legacy JSON
reads; nested and opaque values keep their existing representation. Older alpha
readers cannot consume the new format; no automatic conversion/downgrade is implied.
Complete legacy translation and
cloud cutover remain unfinished. Never apply a stale encoded model as a
whole-record replacement that drops unknown properties.


## GraphEvo 2 typed local persistence

All types below are available through `import GraphEvo` and compile in Swift 6.
See [the typed store guide](../design/graphevo-2-typed-store.md) for identity,
layout, complexity, adoption and migration limits.

`GraphStore` is a Sendable actor with:

```swift
static func open(at url: URL) async throws -> GraphStore
static func inMemory() async throws -> GraphStore
static func adoptLocalV1Store(at url: URL, backupRoot: URL) async throws
    -> (store: GraphStore, report: GraphV1AdoptionReport)
nonisolated let id: GraphID
nonisolated func makeNodeID() -> GraphNodeID
func close() async throws
func read<Value: Sendable>(
    _ body: @escaping @Sendable (GraphReadScope) throws -> Value
) async throws -> Value
func transaction<Value: Sendable>(
    _ body: @escaping @Sendable (GraphMutation) throws -> Value
) async throws -> Value
func fetch<Model: GraphModel>(
    _ id: GraphNodeID, as type: Model.Type = Model.self
) async throws -> Model?
func fetchAll<Model: GraphModel>(_ type: Model.Type) async throws -> [Model]
@discardableResult func insert<Model: GraphModel>(_ model: Model) async throws -> GraphNodeID
func patch<Model: GraphModel>(_ patch: GraphRecordPatch, as type: Model.Type) async throws -> Model
func delete(_ id: GraphNodeID) async throws
```

`GraphReadScope` is a context-confined class without Sendable conformance. Its
initializer and native context are not public. It has `graphID: GraphID`,
`record(for: GraphNodeID) throws -> GraphRecord?`, synchronous `fetch(_:as:)`
and `fetchAll(_:)` counterparts of the actor methods. It expires after the body.

`GraphMutation` is a final subclass with synchronous throwing methods:

```swift
@discardableResult func insert<Model: GraphModel>(_ model: Model) throws -> GraphNodeID
@discardableResult func insert(_ record: GraphRecord) throws -> GraphNodeID
func patch(_ patch: GraphRecordPatch) throws -> GraphRecord
func patch<Model: GraphModel>(_ patch: GraphRecordPatch, as type: Model.Type) throws -> Model
func delete(_ id: GraphNodeID) throws
```

Bodies do not suspend. Insert entities before referencing them. A failed body
rolls back; a failed typed patch validates before editing even if its error is
caught in the body. Partial updates preserve unknown properties. Entity deletion
removes incident relationships and action membership while retaining other
entities and valid empty actions. New IDs and required property-format metadata are persisted in reserved detail
properties; missing format metadata is reported as corrupt identity metadata rather
than exposing envelope bytes as application Data. Untouched adopted v1 nodes have
an explicit empty format list; they are not derived from local URI paths. `fetchAll` has a stable UUID
ordering. Descriptor queries use the bounded A7 execution contract documented
below; fetchAll remains separate from indexed query execution and inventory costs.

`GraphV1AdoptionReport` has read-only Sendable `graphID: GraphID`,
`nodeIDs: [String: GraphNodeID]` and `backupURL: URL?`. The map keys are original
v1 facade IDs. Repeated adoption returns retained identities and nil backupURL.
Adoption requires a quiescent current-schema local source with all legacy/native
writers closed; it backs up SQLite and present sidecars before identity edits.
It does not perform cloud cutover, convert every legacy codec or migrate an
incompatible native model.

`GraphStoreError: Error, LocalizedError` distinguishes `closed`, `ownershipConflict`, `expiredScope`,
`foreignGraph`, `duplicateIdentity`, `corruptIdentity`, `missingNode`, `missingGraph`,
`unresolvedReference`, `legacyStoreRequiresAdoption`, `unsupportedLayout`,
`reservedName`, and `persistence(underlying: Error)`. Model errors and caller body
errors retain their own types. Cancellation retains the A2 pre/post-save contract.
MF01 adds `writesSuspended` and `resourceReserved` for reversible local admission
restrictions. These errors do not indicate a failed consumer commit.

The legacy `GraphStoreOpeningError` also adds `runtimeOwnershipConflict(URL)`
and `requiresV2Runtime(URL)`: legacy readiness fails when a typed owner is active
or an adopted typed-layout store requires the new API. Retained native contexts
retain legacy ownership; dropping a facade alone is not proof of store closure.

## V2 alpha graph catalog and personal mirroring

The native mirroring/sharing APIs in this section and A5 below remain operational
transitional alpha APIs. M17 selects their replacement with explicit CloudKit
sync; see the [transition contract](../design/graphevo-2-custom-sync-transition.md).
This cleanup does not add public GraphCoordinator/ContextManager/CKSyncEngine APIs.

`GraphDatabase` is a public actor exposed through `import GraphEvo`. Its factories
and operations are:

```swift
static func open(at url: URL) async throws -> GraphDatabase
static func inMemory() async throws -> GraphDatabase
static func upgradeLocalA3Store(at url: URL, backupRoot: URL) async throws -> GraphDatabase
static func openMirrored(at url: URL, containerIdentifier: String) async throws -> GraphDatabase
func graphIDs() async throws -> [GraphID]
func createGraph() async throws -> GraphStore
func openGraph(_ id: GraphID) async throws -> GraphStore
func close() async throws
func prepareMirroring(for id: GraphID) async throws -> GraphMirrorBoundary
func inspectMirroring(for id: GraphID) async throws -> GraphMirrorMembership
```

Each graph has its own persisted identity and independent lease. The local
catalog uses a4.1; standalone A3 factories remain a3.1. Upgrade is explicit,
backed up and preserves application IDs. `GraphStoreError.missingGraph` means
that the requested graph is not in the current local catalog. Closed/configuration
errors use the same public translation as `GraphStore`.

The mirrored factory opens an owner-private native resource with no local
fallback. Share preparation sends no invitation and requires an owner-only
share. `GraphMirrorBoundary: Sendable, Equatable` contains read-only
`graphID: GraphID`, `zoneName: String`, `shareRecordName: String`.
`GraphMirrorMembership: Sendable, Equatable` contains read-only `graphID`,
`boundary: GraphMirrorBoundary?`, `nativeObjectCount: Int`,
`pendingMappingCount: Int`, `unexpectedZoneCount: Int`, including owned native
detail rows. Inspection does not request export. A missing boundary or mapping
is pending, not proof of absence. Neither result certifies remote graph recovery.

`GraphMirroringError: Error` distinguishes `localDatabase`,
`preparationPending`, `metadataUnavailable(underlying: any Error)`,
`invalidOwnerOnlyShare`, and `missingNativeResponse`.
Native framework errors retain their type. A durable request with unavailable
share metadata does not retry creation; ambiguous requests need a later recovery
path. Local opening/catalog presence do not guarantee a complete imported graph.
See the [A4 guide](../design/graphevo-2-graph-separation.md) for membership,
cancellation, integrity and the staged private/shared topology.

GraphEvo reexports its model/store modules at the product facade so clients
using `MemberImportVisibility` can resolve contextual enum cases and members
with one `import GraphEvo`. The external Swift 6 consumer enables that feature
when the compiler supports it.


## V2 alpha user sharing (A5)

```swift
extension GraphDatabase {
    static func openMirrored(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                             containerIdentifier: String) async throws -> GraphDatabase
    func cloudSetupStatus() async throws -> GraphCloudSetup
    func sharingIdentity() async throws -> GraphSharingIdentity
    func invite(_ recipient: GraphSharingIdentity, to id: GraphID,
                permission: GraphSharePermission = .readWrite) async throws -> GraphInvitation
    func acceptInvitation(_ invitation: GraphInvitation) async throws
    func sharingStatus(for id: GraphID) async throws -> GraphSharingStatus
    func setPermission(_ permission: GraphSharePermission, for recipient: GraphSharingIdentity,
                       in id: GraphID) async throws
    func revoke(_ recipient: GraphSharingIdentity, from id: GraphID) async throws
    func leaveGraph(_ id: GraphID) async throws
    func pendingSharedOperations() async throws -> [GraphPendingOperation]
}
extension GraphStore {
    @discardableResult func insertShared(_ records: [GraphRecord]) async throws -> [GraphNodeID]
    @discardableResult func insertShared<Model: GraphModel>(_ model: Model) async throws -> GraphNodeID
    func patchShared(_ patch: GraphRecordPatch) async throws -> GraphRecord
    @discardableResult func recoverSharedOperation() async throws -> [GraphNodeID]
}
```

The paired factory reserves both explicit resources under one native owner;
there is no cloud-to-local fallback. Local open and completed native setup are
separate from export/import and graph integrity. `GraphCloudSetup: Sendable`
contains `storeCount`, `readyStoreCount`, `latestFailureDomain: String?` and
`latestFailureCode: Int?`; counts are `Int`. A metadata preflight failure before
a durable share request can be retried; an ambiguous existing request cannot
replay share creation.

`GraphSharingIdentity: Sendable, Codable, Equatable` is opaque.
`GraphInvitation: Sendable, Codable` exposes only `graphID: GraphID`.
Both values are sensitive; protect transport, bind it to the intended account
and container, and never log invitations or identity payloads. Codable decoding
rejects empty recipient IDs and invitation URLs without HTTPS and a host.
Acceptance completion does not certify graph import.

`GraphSharePermission: String, Sendable, Codable` has `readOnly` and `readWrite`.
`GraphShareRole: Sendable, Equatable` has `owner`, `participant`, `unknown`.
`GraphSharingStoreScope: Sendable, Equatable` has `privateStore`, `sharedStore`.
`GraphSharingStatus: Sendable` exposes read-only `graphID`, `scope`, `role`,
`permission: GraphSharePermission?`, `accepted: Bool`, `metadataAvailable: Bool`
and `hasPendingOperation: Bool`. Status is an observation, not authorization
or synchronization proof. Owner access reduction/status do not require every
application payload to decode; permission grants validate graph integrity.
Leaving only purges the participant's exact share zone in the explicit shared
store, with no pending originating-device structural intent.

Synchronous scopes may edit existing shared detail values, remove details,
change endpoints or delete existing members. Creating shared nodes or new
detail rows requires awaited `insertShared`/`patchShared` outside the scope.
Even an empty shared insertion checks handle lifetime and mirrored configuration.
The library checks known accepted read/write metadata and native permission
advice before writes; server changes may race the local save. `patchShared`
returns a detached record after committing; application-model decoding is a
separate explicit step. Existing typed synchronous patch retains pre-mutation
decoding validation.

Structural operations stage unlinked components, assign every owned row to the
existing share, verify mappings, then finalize graph links locally. A durable
local journal beside the shared SQLite records partial work. Recovery never
replays native assignment; missing mappings and divergent state remain pending
or errors. `GraphSharedOperationKind: Sendable, Equatable` has `insertion` and
`patch`. `GraphPendingOperation: Sendable` exposes read-only `graphID`,
`operationID: UUID`, `kind` and `nodeIDs: [GraphNodeID]` (target IDs for patches).
`pendingSharedOperations()` remains readable while the writer awaits native
completion and after graph access disappears; it exposes no payload values.

`GraphSharingError: Error` distinguishes `sharedStoreRequired`, `metadataPending`,
`invalidInvitation`, `invalidParticipant`, `ownerRequired`, `participantRequired`.
`GraphStoreError` additionally distinguishes `permissionDenied`,
`sharedInsertionRequiresPreparation` and `pendingNativeOperation`. Native errors
retain their original type. A failed native operation may already have persisted
objects; inspect/recover recorded intent rather than resubmitting the mutation.

`MigrationBackupManager.backupStore` additionally copies the optional
`<SQLite>.graphevo-operations` directory. `BackupDescriptor.files` lists copied
entries, including this directory when present. Its restore path copies those
entries recursively. Obtain a quiescent source and back up both resources of a
pair with their ledgers. Close is not a cloud synchronization barrier.
See the [A5 contract](../design/graphevo-2-user-sharing.md) for recovery limits,
permissions, physical evidence and remaining beta gates.

## V2 alpha native attachments (A6)

```swift
extension GraphStore {
    nonisolated static var maximumAttachmentByteCount: Int { get } // 10 MiB
    func importAttachment(from source: URL, ownedBy ownerID: GraphNodeID,
                          fileName: String? = nil,
                          contentType: String = "public.data") async throws -> GraphAttachmentMetadata
    func attachment(_ id: GraphNodeID) async throws -> GraphAttachmentContent?
    func attachments(ownedBy ownerID: GraphNodeID) async throws -> [GraphAttachmentMetadata]
    func replaceAttachment(_ id: GraphNodeID, from source: URL,
                           fileName: String? = nil,
                           contentType: String? = nil) async throws -> GraphAttachmentMetadata
    func deleteAttachment(_ id: GraphNodeID) async throws
    @discardableResult func exportAttachment(_ id: GraphNodeID,
                                            to destination: URL) async throws -> GraphAttachmentMetadata
}
extension GraphReadScope {
    func attachment(_ id: GraphNodeID) throws -> GraphAttachmentContent?
    func attachments(ownedBy ownerID: GraphNodeID) throws -> [GraphAttachmentMetadata]
}
enum GraphStoreBackup {
    static func copyClosedDirectory(from source: URL, to destination: URL) async throws
}
```

`GraphAttachmentMetadata: Sendable, Equatable, Codable` exposes read-only
`id: GraphNodeID`, `ownerID: GraphNodeID`, `fileName: String`, `contentType: String`,
`byteCount: Int`, `sha256: String` and `revision: UUID`.
`GraphAttachmentContent: Sendable, Equatable` exposes `metadata` and `data: Data`.
Codable metadata is transport data, not authority or proof that bytes are locally
available. Complete reads verify content, version, identities, owner and checksum.
On the C03a experimental branch, `attachments(ownedBy:)` validates descriptive
metadata without decoding/verifying split content; listing does not certify body availability
or integrity. Existing A6 single-envelope files retain full validation on listing.
Nil denotes an absent local node; incomplete/invalid content or an unavailable
owner throws. This does not establish permanent cloud absence or corruption.

An attachment has exactly one application-node owner, of any public node kind,
in its own graph. Attachments cannot own attachments. Replacement preserves ID,
owner and creation date and rejects a locally changed revision. Owner deletion
cleans owned files, including those on implicitly deleted relationship edges;
transaction rollback preserves the previous content. Raw patches cannot transfer
ownership or replace valid content with malformed metadata. `GraphEvo.Attachment.v1`
and its `content` / experimental `attachmentMetadata` properties are reserved for this alpha feature. Current
native model hashes remain unchanged; v1 binary fields are not automatically
converted into attachments.

Import coordinates/security-scopes source access outside the write scope and
copies bounded bytes rather than retaining a source URL. Export snapshots then
writes a new caller-owned destination, refusing existing files and cleaning
intermediate artifacts on failure. Caller-controlled destination ownership is
required. Cancellation before local commit/publication preserves prior state;
started native shared assignment can retain partial intent, requiring A5 recovery
rather than an import replay. A locally committed result is distinct from export
or independent replica recovery.

The alpha buffers complete content and accepts empty files through 10 MiB.
Listing split metadata does not decode/verify the body; old envelopes retain full validation. Streaming, per-file
progress, eviction, selective download, a persistent offline-retention guarantee
and distributed replacement conflict resolution are unsupported.

`GraphAttachmentError: Error, LocalizedError` distinguishes `invalidMetadata`,
`invalidFileURL`, `limitExceeded(maxBytes: Int)`, `incompleteOrInvalidContent`,
`unsupportedVersion`, `notAnAttachment`, `missingOwner`, `conflict` and
`destinationExists`. Store/permission/native I/O errors retain their normal type.

The directory-backup helper requires all source owners closed, external writers
stopped and a new non-overlapping caller-controlled destination. It copies the
complete application-owned directory opaquely, including native external content
and operation ledgers, without discovering internal paths. It does not itself
certify quiescence, remote delivery or cloud rollback. The narrower
`MigrationBackupManager.backupStore` is insufficient for a whole-content backup
when native external content exists. See the [A6 contract](../design/graphevo-2-attachments.md).

## V2 alpha bounded queries and traversal (A7)

`GraphQuery<Model: GraphModel>: Sendable` selects the persistent type/kind and
requires a `GraphQueryBudget`. It provides value builders `where(_:)`,
`sorted(by: [GraphQuerySort])`, `limit(_ count: Int)`, `after(_ cursor:
GraphQueryCursor)` and `explain() throws -> GraphQueryPlan`.

```swift
extension GraphStore {
    func query<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphQueryResult<Model>
    func count<Model: GraphModel>(_ query: GraphQuery<Model>) async throws -> GraphQueryCount
    func project<Model: GraphModel>(_ query: GraphQuery<Model>, properties: Set<String>) async throws -> GraphQueryProjectionResult
    func aggregate<Model: GraphModel>(_ query: GraphQuery<Model>, _ aggregate: GraphQueryAggregate) async throws -> GraphQueryAggregateResult
    func traverse(_ traversal: GraphTraversal) async throws -> GraphTraversalResult
}
```

The same operations exist synchronously on GraphReadScope/GraphMutation. Scopes
remain non-Sendable and invalid outside their body. Count and aggregation cover
the full filtered set within the allowance, ignore order/limit and reject cursors.
Projection/fetch honor order/limit/cursor. Count/projection/aggregation do not
invoke application decoders; typed fetch decodes only returned rows and never
silently drops failures.

`GraphQueryBudget: Sendable, Equatable` has read-only `maximumCandidates`,
`maximumPropertyBytes`, `maximumSteps: Int`. Its throwing initializer requires
positive candidates below Int.max, nonnegative property allowance and positive
steps. Defaults are 32 MiB of charged property payload and 100,000 logical steps;
there is no default candidate allowance. Budgets are work limits, not result
counts, native I/O limits or hard memory/deadline guarantees. Candidate inventory
includes native node rows across the resource group; only selected-graph
application records are evaluated. Every query currently uses explicit bounded
inventory plus memory evaluation. No SQL/native-count optimization or silent
fallback is claimed. Opening/catalog costs are outside a query allowance.
On the M03 experiment branch, complete model results materialize all properties
of the requested type/kind. Other types and count/projection/aggregate/traversal
operations materialize descriptor-referenced keys, including nested related
predicates and sort/aggregate/projection dependencies. Skipped payloads are not
validated by unrelated queries. Explicit body references remain charged before
decoding; full file reads and sharing integrity still verify complete content.

`GraphQueryPredicate: Sendable, Equatable` is indirect and supports:

- `all`, `none`, `id(GraphNodeID)`, `type(String)`, `tag(String)`, `group(String)`,
  `exists(String)`;
- `property(String, GraphQueryComparison, GraphValue)`;
- `subject(GraphNodeID)`, `object(GraphNodeID)` for relationship/action endpoints;
- `and([GraphQueryPredicate])`, `or([GraphQueryPredicate])`, `not(GraphQueryPredicate)`
  and operators `&&`, `||`, `!`;
- `related(GraphQueryRelation, matching: GraphQueryPredicate)` for Entity neighbors.

Successive where calls combine with **AND**, unlike retained v1 Search OR.
Property names and strings are literal/case-sensitive; no v1 LIKE wildcard or
case-folding behavior is inherited. Missing comparisons are false; explicit null
participates in equality/inequality and does not match ordered/string operations.
Empty AND/OR are true/false. Reserved metadata keys are rejected. Expressions
allow at most 256 AST nodes/depth 32 and four nested related hops.

`GraphQueryComparison: Sendable, Equatable` has `equal`, `notEqual`, `lessThan`,
`lessThanOrEqual`, `greaterThan`, `greaterThanOrEqual`, `beginsWith`, `contains`.
Equality supports null/scalars; ordering requires homogeneous Bool, integer,
finite Double/Decimal, String or finite Date. UUID/URL support equality only;
URL equality follows Foundation. Numeric cases are not implicitly coerced.
Data/array/object/encoded comparisons and ordering are unsupported; presence and
projection retain opaque values. Unsupported operands/shapes fail before inventory.

`GraphQuerySortKey: Sendable, Equatable` has `identity`, `createdDate`,
`property(String)`. `GraphQuerySort: Sendable, Equatable` exposes `key`,
`direction: GraphQuerySortDirection` (`ascending`, `descending`) and
`missing: GraphQueryMissingValues` (`first`, `last`). Both enums are Sendable,
Equatable. Init defaults to ascending/missing last. At most eight sort keys;
UUID ascending is the final tie-breaker. Missing/null share a first/last bucket
independent of direction. Heterogeneous or unsupported ordered values fail before
page slicing.

`GraphQueryAggregate: Sendable` has `sum(String)`, `minimum(String)`,
`maximum(String)`. Sum supports homogeneous Int64/UInt64/finite Double and rejects
overflow/non-finite results; Decimal sum is unsupported. Min/max support ordered
scalars. Missing/null values do not contribute; no contributors produces nil.
Floating sum uses deterministic UUID input order, not exact arithmetic.

`GraphQueryRelation: Sendable, Equatable` has `outgoing(String?)`,
`incoming(String?)`, `actionObjects(String?)`, `actionSubjects(String?)`.
The optional string filters exact relationship/action type. Neighbors are Entity
endpoints in the same graph; hidden membership/root links are excluded. Related
predicates are existential, deduplicating neighbors per hop. Optional absent
endpoints/empty actions do not invent neighbors. Attachment ownership is not an
implicit edge.

`GraphTraversal: Sendable` initializes with `from origins: [GraphNodeID]`,
`via relation: GraphQueryRelation`, `maximumDepth: Int`, `budget: GraphQueryBudget`
and throws on empty origins/invalid depth or oversized input. Depth is 0...32.
Breadth-first traversal excludes origins, suppresses all revisits/cycles and
orders visits by depth then UUID. `GraphTraversalVisit: Sendable, Equatable`
contains `id: GraphNodeID`, `depth: Int`. There is no unbounded traversal or
claim that a depth-limited result exhausted the graph.

`GraphQueryResult<Model>: Sendable` exposes `items: [Model]`,
`nextCursor: GraphQueryCursor?`, `view: GraphQueryLocalView`,
`diagnostics: GraphQueryDiagnostics`. `GraphQueryProjectionResult: Sendable`
has `rows: [GraphQueryProjection]` and the same cursor/view/diagnostics.
Projection rows expose `id` and `values: [String: GraphValue]`; absent requested
keys are omitted, explicit null retained; at most 128 keys. `GraphQueryCount`
contains `value: Int`, view and diagnostics. `GraphQueryAggregateResult` contains
`value: GraphValue?`, `contributingCount: Int`, view and diagnostics.
`GraphTraversalResult` contains `visits: [GraphTraversalVisit]`, view and
diagnostics. These result structs are Sendable and read-only.

`GraphQueryCursor: Sendable` is opaque and not Codable. It binds logical graph,
persistent model type/kind, predicate structure and sort order. Positive page
limit is required when using it. Page size and allowance changes are allowed;
fetch/projection may share a cursor. Current-state keyset pagination compares
the retained tuple/UUID without offsets or looking up the anchor. Anchor deletion
is supported; intervening sort-key edits may repeat/omit rows and inserts before
the tuple are absent from later pages. It is not a frozen/durable paging session.

`GraphQueryLocalView: Sendable, Equatable` exposes `graphID`, `scopeID: UUID`,
`includesPendingChanges: Bool`. The flag marks mutation-scope execution, not a
claim that pending edits exist. Scope identity is neither a native generation
nor cloud-completeness marker. Separate pages execute in new local views.
`GraphQueryDiagnostics: Sendable` exposes `nativeCandidates`, `scopedNodes`,
`propertyBytesCharged`, `evaluationSteps: Int`. Byte charging is a documented
payload/structural tariff, not resident memory. Steps are logical engine work.
`GraphQueryPlan: Sendable` contains `strategy: Strategy`, `budget`;
`Strategy: Sendable, Equatable` currently has only `boundedInventoryAndMemory`.
Explain validates shape; graph-specific references/cursors are checked at execution.

`GraphQueryError: Error, Equatable, LocalizedError` distinguishes `invalidBudget`,
`invalidLimit`, `invalidPropertyName`, `invalidModelType`, `invalidTraversal`,
`invalidOrigin`, `unsupportedValue`, `unsupportedComparison`, `incomparableValues`,
`foreignGraph`, `invalidCursor`, `expressionTooComplex`, `arithmeticOverflow`,
`unsupportedStorage`, `budgetExceeded(GraphQueryBudgetDimension)`.
`GraphQueryBudgetDimension: Sendable, Equatable` has `candidates`, `propertyBytes`,
`steps`. Store/model/native errors retain their existing type. No partial result
is returned after budget exhaustion or cancellation. Checks run around inventory,
between snapshots and periodically in evaluation; native fetch/codec calls settle
before the next cancellation check.

See the [A7 contract](../design/graphevo-2-queries.md) for the capability matrix,
limits, moving-current-state semantics and retained test scope.

## V2 A8 observation and Combine (alpha)

Read the [A8 contract](../design/graphevo-2-observation.md) for delivery,
processing limits and lifecycle. These APIs do not change v1 Watch.

```swift
public enum GraphQueryState<Model: GraphModel>: Sendable {
    case value(GraphQueryResult<Model>)
    case failure(any Error)
}
public enum GraphObservationError: Error, Sendable { case accountChanged }
public struct GraphChangeSignal: Sendable {
    public enum Reason: Sendable {
        case initial, contextSave, storeChange, nativeOperation, accountChange, refresh
    }
    public let graphID: GraphID
    public let id: UUID
    public let reason: Reason
    public var requiresRescan: Bool { get } // Always true; no per-node event/replay position.
}
public struct GraphObservation<Value: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Value
    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async -> Value?
    }
    public func makeAsyncIterator() -> AsyncIterator
    public func cancel()
    public func refresh()
}
public struct GraphObservationPublisher<Value: Sendable>: Combine.Publisher {
    public typealias Output = Value
    public typealias Failure = any Error
    public func receive<S: Combine.Subscriber>(subscriber: S)
        where S.Input == Value, S.Failure == Failure
}
extension GraphStore {
    public func observe<Model: GraphModel>(_ query: GraphQuery<Model>)
        async throws -> GraphObservation<GraphQueryState<Model>>
    public func changes() async throws -> GraphObservation<GraphChangeSignal>
    public nonisolated func publisher<Model: GraphModel>(for query: GraphQuery<Model>)
        -> GraphObservationPublisher<GraphQueryState<Model>>
    public nonisolated func changePublisher() -> GraphObservationPublisher<GraphChangeSignal>
}
```

Each observation initially reads current local state. Exact query definitions,
concrete model types, row limits and all budget dimensions share a serial native
read worker within the same GraphStore handle. Each subscriber independently
decodes application models and receives newest states; another handle never
joins that group. Resource invalidation retains related-node/action/file dependencies.
A shared execution has one real scopeID and diagnostics for all recipients.
New subscriptions request a fresh read, never a cached result or a read begun
before registration; joining or refreshing a group can refresh its other members.
Output is newest-one, may coalesce intermediate states/errors, and may repeat
an unchanged result after unrelated changes. Cursor-based descriptors are
rejected; sort/limit describe the current first page. Recoverable errors produce
failure states and retry on the next hint/manual refresh. Handle close ends its
observations, retaining other handles. Buffered values may drain on termination.
Account-change invalidation remains sticky in that runtime: query observation
emits accountChanged and ends; it does not establish the complete account/cache
policy. Explicit cancellation, cancellation during iteration or dropping the
observation and iterator tears down the worker. A retained observation must be
cancelled when breaking a loop. Refresh is useful after foreground/resume.

Combine is cold per subscriber, starts on first positive demand, uses one
newest-value pending mailbox and serializes callbacks outside locks on a private
queue. UI consumers select receive(on:) themselves. Startup errors complete with
failure; refresh errors are state values. Demand does not throttle native writes
or mirroring. Cancellation is per subscriber; an admitted callback may finish.

Changes/changePublisher emit only live rescan hints; IDs are ephemeral and are
neither ordered transaction identities nor durable history cursors. Rescan on
startup/reconnect and reconcile the application's prior inventory. No per-node
deletions, durable replay, acknowledgements, exactly-once effects or cloud-import
completion are supplied. O04 remains a consolidation choice, not a completed
replay feature. Different query shapes still execute independently. Sequential
subscription startup and heavy/slow application decoders remain consolidation
work; sharing is not a total memory/time bound. See the
[consolidation adoption](../design/graphevo-2-observation.md#c04-consolidation-adoption)
for the accepted scope and remaining native-device acceptance.


### Identity-guarded query materialization (v2 consolidation)

Leading finite ID guards can avoid loading property bodies on excluded nodes of
the same model type. Selected complete models retain every field; candidate,
identity/membership/endpoint/format inventory stays complete and bounded. A
property condition before the ID guard, an unbounded Boolean alternative, related
predicates or traversal keeps conservative materialization. Skipped bodies are
not certified. Query signatures, cursor semantics and the reported bounded
inventory strategy are unchanged. See the
[query contract](../design/graphevo-2-queries.md#c02-consolidation-identity-guarded-materialization).

## Explicit native-identity schema (alpha)

```swift
public enum GraphDatabaseSchema: Sendable {
    case current
    case nativeIdentity
}

extension GraphDatabase {
    public static func open(at url: URL, schema: GraphDatabaseSchema) async throws -> GraphDatabase
    public static func inMemory(schema: GraphDatabaseSchema) async throws -> GraphDatabase
    public static func openMirrored(at url: URL, containerIdentifier: String,
                                    schema: GraphDatabaseSchema) async throws -> GraphDatabase
    public static func openMirrored(privateStoreAt privateURL: URL, sharedStoreAt sharedURL: URL,
                                    containerIdentifier: String, schema: GraphDatabaseSchema) async throws -> GraphDatabase
    public func validateIntegrity(of graphID: GraphID) async throws -> Int
}
```

`nativeIdentity` selects the explicit native layout for local, private-only mirrored
or private/shared mirrored resources. It uses optional native graph/node String projections and a configured
compound fetch index; no uniqueness constraint or specific SQL-plan guarantee is
implied. It does not convert an existing current/prototype store or erase an
incompatible path. Graph creation activates only newly allocated empty controls.
Incompatible alpha layouts start from empty stores under M13.

Existing no-schema overloads and `current` retain the previous model, including
mirrored opens. Native mirroring requires an explicit `schema: .nativeIdentity`.
The explicit native schema uses [S03](../design/graphevo-2-history-schema.md)
with model version identifier `GraphEvo.v2.schema.3`. It retains indexed graph/node
UUID projections, preserves them in deletion history and has no native
application-version column. Previous S02/S01
files are incompatible alpha inputs, never silently converted or relabeled.
The runtime validates this public Core Data
metadata before loading any existing resource, as well as native entity hashes.
Historical alpha.2 and unversioned prototype files are refused, including a
same-shape file carrying the wrong model identifier;
there is no automatic stamp, conversion or wipe. New local and mirrored native
files use the same versioned factory. Root protocol `nativeIdentityLayout =
alpha.1` is retained. No-schema/current defaults retain the original native
model. The local model-version gate prevents incompatible data from starting
export before catalog validation; it does not control native remote writers or
certify that a record's values have all arrived.

Mirrored opening reserves the whole topology before loading: exactly one private
resource or an explicit private/shared pair, using the same schema for both.
There is no fallback on explicit mirrored failure. Fresh local paths do not
establish empty/compatible cloud state; the caller must choose a controlled
compatible cloud environment or a separately supported migration/cutover.
Single-graph v1 adoption APIs retain their existing separate scope.

Native point hits validate targets/references; misses audit the same-view native
routing/identity inventory before returning nil. Mutations use common typed
writers. Queries remain bounded inventory/memory evaluation with full documented
candidate allowances and identity-guarded property loading; selecting this schema
does not select an indexed SQL query strategy. Scoped snapshots validate native
projections of consulted nodes, and descriptor/codec errors remain visible.

`validateIntegrity(of:)` supports both public database schemas and returns the
selected graph's current local application-row count, including attachments and excluding hidden
controls. It explicitly scans identities, structure and stored payloads/file
integrity. It does not invoke application model initializers, follow query byte
budgets or certify domain validity, another replica or CloudKit import completion.
It supports local and mirrored native owners through the same topology-checked resolver.
The operation can load complete large file bodies; metadata-only listing has a
different scope. A graph absent from the current catalog reports `missingGraph`.

See the [fresh native store contract](../design/graphevo-2-native-identity-integration.md#fresh-local-native-schema-api).


## V2 containing-app synchronization and extension readers

The v2 runtime rejects mirrored openings from app extensions with
`GraphStoreError.synchronizationUnavailableInExtension` before native loading.
The selected alpha policy gives the containing app CloudKit synchronization;
it also refuses isolated extension mirroring. This is a conservative library
policy, not an Apple-wide prohibition on CloudKit in extensions. A local reader
can use:

```swift
public static func openReadOnly(at url: URL,
    schema: GraphDatabaseSchema = .current) async throws -> GraphDatabase
public static func openReadOnly(privateStoreAt privateURL: URL,
    sharedStoreAt sharedURL: URL,
    schema: GraphDatabaseSchema = .current) async throws -> GraphDatabase
```

These methods open existing compatible SQLite resources through an ordinary
read-only Core Data container, preserving pair routing and explicit schema
selection. They never create missing stores/graphs or start CloudKit. Missing
resources produce `GraphStoreError.missingStore`; graph mutations produce
`GraphStoreError.readOnly`. Cloud operations are unsupported: their public
setup preflight may instead report a local database. Incompatible resources are not converted.
The existing same-process ownership/access compatibility remains enforced.
Query observations retain their conservative invalidation contract; callers
should query freshly after extension resume. This is not a global cross-process
lock, account/permission certificate, or completed iOS App Group/widget support.
See [the extension access contract](../design/graphevo-2-app-extension-access.md).

## V2 package-only graph coordinator foundation

The [exclusive coordinator increment](../design/graphevo-2-graph-coordinator.md)
adds internal GraphContextManager/GraphCoordinator ownership. It returns the
existing GraphStore type through package-only factories for local validation;
there is no new public opener or public coordinator API. Public GraphDatabase
continues to represent its existing multi-graph resources. Existing public
opening paths do not silently migrate to or activate the new owner path.


The [PH pending continuation](../design/graphevo-2-history-processing.md) adds
package-only collection, immutable batch preparation, subset acknowledgement,
abandonment and controlled imported patches on coordinated handles. These are
not public GraphStore APIs or activated CloudKit transport. Newly coordinated
stores retain a native purpose marker: old mirrored single/pair openings refuse
them before cloud loading; compatible local/read-only readers remain supported.
Unmarked older-alpha S03 stores are not silently adopted by the coordinator.


## V2 package-only engine foundation

The [engine foundation](../design/graphevo-2-sync-engine-foundation.md) adds
internal ContextManager session start/stop, exact zone binding, manual fetch,
status, route lookup and bounded read-only inbox access. Native activation is
availability-gated to iOS 17/macOS 14 and refused in app extensions. Package
platform floors and public signatures are unchanged. The implementation retains
opaque incoming events; it does not upload records or apply them to GraphStores.


## V2 package-only cloud record format

[CF01](../design/graphevo-2-cloud-record-format.md) encodes one logical primitive
per GraphEvoNode CKRecord with scoped UUID identity and serialized properties.
Package-only conversion accepts detached GraphRecords, PH batches and incoming
inbox envelopes; prepareCloudBatch retains pending work on encoding failure and
never sends/acknowledges it. No public signature or native schema changes. Native
system fields can be reused for the exact record; metadata persistence, actual
transport, incoming effects and asset support remain subsequent work.


## V2 package-only manual record transport

[T01](../design/graphevo-2-record-transport.md) connects internal sendCloudChanges
and applyCloudInbox operations, durable frozen attempts, native server metadata
and atomic incoming/send receipts. Native drivers use the ContextManager engines;
no public opener or automatic synchronization is enabled. Persisted routes contain
GraphID and zone only; app bootstrap must open each graph at its current URL after
restart. Unregistered resources remain pending. Schema S03 and CF01 are unchanged;
engine-session format 1 is refused without conversion by the new format-2 reader.


### Package-only automatic conflict transport (T03)

The new custom-cloud backend still has no public opening API. Its package-only
`GraphConflictPolicy` cases are `cloudWins` and `lastEditWins` (default).
`GraphContextManager.createGraph(id:at:conflictPolicy:)` selects a local persisted
policy; `GraphStore.conflictPolicy` is an async throwing getter and
`setConflictPolicy(_:)` is async throwing. All handles share changes. GraphRecord
and its application properties are unchanged. Graph stamps hidden edit dates;
consumers do not set them. Delete-wins overrides both policies and deleted node IDs
cannot be reused. See the [T03 contract](../design/graphevo-2-conflict-policies.md)
for bounded retry/report meanings, compatibility and structural refusal scope.


### Package-only CKAsset attachment transport (T04)

The custom-cloud ContextManager offers `exportCloudAttachment(_:to:configuration:timeout:)`
async throws, returning GraphAttachmentMetadata. It exports verified local bytes
or shares a fetch/import when absent; cancellation/deadline affect one caller,
without cancelling common sync work. The default deadline is five minutes and
existing destinations are refused. Existing public GraphStore attachment/export
methods retain local snapshot semantics. No native/temporary URL is returned.
See [T04](../design/graphevo-2-cloud-assets.md); no public custom-cloud opening is
introduced. Automatic CKAsset fetching does not provide metadata-first delivery.


### Package-only per-graph sync pause (T05)

ContextManager exposes `cloudSynchronizationState(for:)`,
`observeCloudSynchronization(for:)`, `pauseCloudSynchronization(for:)` and
`resumeCloudSynchronization(for:)`. Actor-isolated states are active,
pauseRequested and paused. Pause drains previously admitted sync operations;
new send/import operations report graphPaused. Local access and the existing PH
queue remain available. Independent waiter cancellation does not undo pause.
Resume during draining reports busy; resume never launches automatic work.
State is process-local, shared by manager handles and reset on full runtime
close/reopen. These package-only operations are not migration exclusivity,
engine stop or a new public opening. See [T05](../design/graphevo-2-sync-pause.md).


### T06 package-only foreground synchronization

GraphContextManager adds setAutomaticCloudSynchronizationActive(_:configuration:),
requestCloudSynchronization(configuration:), notifyRemoteCloudChanges(in:configuration:),
automaticCloudSynchronizationStatus(for:configuration:) and
observeAutomaticCloudSynchronization(for:configuration:). These are package-only,
require an existing session, and expose no new public opener. Activation is explicit;
local hints debounce 250ms/max1s and foreground reconciliation runs every 60s.
GraphAutomaticSyncStatus contains phase, retryAfter, payload-free failure family/code
and pendingWork; none certifies global sync completion. See [T06](../design/graphevo-2-automatic-sync.md)
for pause, lifecycle, retry, recovery and demo forwarding.


### Package-only T07 sharing candidate

The custom sync implementation adds no public opening or invitation API. The
internal ContextManager supports `cloudSharingIdentity(_:)`,
`inviteCloudParticipant(_:to:permission:configuration:)` and
`acceptCloudInvitation(_:configuration:)`. Owner zones stay private; participants
use shared zones. Read-only/pending participant mutations are refused across
handles, while import remains separate from acceptance. See the
[T07 contract](../design/graphevo-2-zone-sharing.md) for alpha state compatibility
and protected capability transport requirements.


### Package-only T08 sharing lifecycle candidate

No new public opener is exposed. Internal ContextManager operations manage
participants/permissions, stop sharing, leave, observe/recheck participation,
register current recovery locations and explicitly accept into a new empty store.
Confirmed loss and leave remove the participant replica even with pending edits;
old GraphStore handles are closed. Read-only downgrade retains data and continues
imports. Reopened participant data requires verified session-journal attachment.
Interrupted acceptance can resume at the current URL for its existing joining
generation. A missing local marker is reconstructed only for a verified untouched
replica, without granting application access. Inbox saturation blocks data
transport while membership verification and removal remain available; account
and other fatal session failures continue to block both paths.
See [T08](../design/graphevo-2-sharing-lifecycle.md) for state format 5 and recovery.

### Package-only MF01 local reservations and backups

`GraphContextManager.suspendLocalWrites(for:)` returns an owned, independently
released reservation shared by all graph aliases. It refuses new writers and
drains admitted/queued writers while preserving reads; it is separate from cloud
pause and the internal all-access maintenance reservation. Dropping a reservation
schedules cleanup. These controls are process-local and expose no raw contexts.

`createBackup(for:in:reason:artifacts:)` captures a complete native graph snapshot,
caller-supplied immutable journal artifacts and graph-only recovery evidence from
registered sessions. The optional reason is persisted in the relative-path,
checksummed manifest. `backups` supplies list/verify/retain/release/remove,
incomplete-stage cleanup and restoration into a new empty local directory.
Restoration never activates CloudKit or overwrites a live destination. Full
native reopen and attachment checks run on a disposable copy. No v1 backup helper,
native model or cloud record/session format is silently changed. See
[MF01](../design/graphevo-2-local-maintenance.md) for limits and remaining gates.

### Package-only MF02 compressed backup packages

New local backups are single **`.geb`** files. `GraphBackup.url` identifies an
immutable package (or a readable legacy directory), with `manifest` available
without payload extraction. `GraphRestoredBackup.directory` and `.storeURL`
identify a separately materialized local copy; packages expose no fake SQLite URL.

`backups.export(at:to:) async` verifies and copies the existing compressed package;
it never resnapshots a live graph. `backups.importBackup(at:in:) async` verifies
and adds it to a local collection without activating a graph or sync. Existing
destinations/duplicate IDs are refused. Legacy directory export creates a `.geb`.
The filesystem and manifest define listings, with no authoritative central index.

Graph snapshot reservations end after native copying. Compression, verification
and export/import continue asynchronously with owned cancellation and staged
publication. Manifest/header and compressed/expanded file limits apply; full
verification still includes native reopen, PH-preserving copy and attachment
digests. Retention owners are local collection metadata, not exported migration
locks. Independent cross-user graph activation, reference remapping, provider/UI
coordination and in-place/cloud restoration remain separate. See
[MF02](../design/graphevo-2-backup-packages.md) for the container and contract.

### Package-only MF03 bounded shared ledger

`GraphContextManager.graphLedger(for:configuration:)` reads cached control status;
`observeGraphLedger` immediately yields current status and bounded newest updates.
Both opt a registered cloud binding into control reconciliation. These APIs remain
available after graph handles close, until session stop or participation removal.

`updateGraphLedger(for:configuration:expectedRevision:mutation:)` persists local
control changes. `GraphLedgerMutation` supports begin, phase progress, retry,
interruption, resume, terminal finish and separate global/current-operation JSON.
Operation UUIDs and optional expected revision reject stale commands. Current and
previous operations retain complete details; a ring holds 32 significant events.
Retry counters coalesce without appending events. JSON objects are canonical and
bounded to 16 KiB each; the entire shared ledger is capped at 128 KiB.

`reconcileGraphLedger(for:configuration:acceptCloud:)` explicitly reconciles the
exact control record. Concurrent remote changes retain both values as a visible
conflict. `acceptCloud: true` explicitly discards local pending control changes,
without changing graph application data. `GraphLedgerStatus.confirmedRevision`
refers only to this control projection, never graph convergence. An owned running
operation recovered after restart requires explicit resume/interruption/finish.

Automatic foreground control shares ContextManager lifecycle and per-scope
admission, while graph-data pause does not suspend it. Read-only peers can observe
control updates. Revocation removes the participation's local ledger; old callbacks
cannot affect a new generation. Session format 6 is deliberately incompatible with
older alpha session documents; S03 and application wire formats are unchanged.
This is a migration foundation, not an executor, format registry or distributed
lock. See [MF03](../design/graphevo-2-shared-ledger.md).

### Logical graph emptying

`GraphStore.removeAll(maximumRecords: Int = 10_000) async throws -> Int` removes
all application primitives and owned attachments in one normal local transaction.
`GraphMutation.removeAll(maximumRecords:) throws -> Int` joins its enclosing
transaction, so a consumer can empty and repopulate atomically. Both return the
number of logical records removed, including attachments; an empty writable graph
returns zero. GraphID, hidden catalog/membership, conflict policy and sync metadata
remain intact. Limits must be positive; `GraphRemovalError.invalidLimit` and
`.recordLimitExceeded` refuse before destructive edits. The record limit is not
a total native inventory, payload memory, SQL-I/O or remote-work bound.

Normal cancellation/rollback, writer admission, read-only and participant
permissions apply. Existing history-sync delete-wins retains deleted IDs and
rejects their reuse; repopulation uses fresh IDs. Other local layouts keep their
existing identity policy. Query observations refresh through normal invalidations.
Cloud-backed graphs enqueue ordinary PH deletes for normal transport; zone, share
and ledger remain. Local success does not certify delivery or an atomic/global
cloud wipe, and does not delete records absent from the local replica. Exports and
backups remain caller-owned. See [MF04a](../design/graphevo-2-logical-emptying.md).


### Isolated migration preparation (package-only)

`GraphContextManager.prepareMigrationWorkspace(for:at:) async throws -> GraphMigrationWorkspace`
protects an open local/owner original with owned cloud-data pause and local-write
holds, then returns a complete mutable `graph` with the same GraphID/node IDs,
independent files and no sync session. The destination must be absent with an
existing parent. Participant sources are refused. Native runtime admission
rejects ordinary opening/activation of the marked copy.

`GraphMigrationWorkspace.id`, `.graph`, `.directory` and `.descriptor` identify
the working copy. `close() async throws` drains and closes working access,
preserves files and releases only its source holds. `discard() async throws`
then removes verified owned files; unknown/replaced resources are refused.
Normal transactions, queries, observations, attachments and `removeAll()` operate
only on the working copy. Its fresh PH baseline follows setup, excluding original
pending work and pre-copy history. No backup or cloud publication happens here.
`seal(limits: GraphMigrationWorkspaceLimits = .init()) async throws -> GraphMigrationChangeSet`
freezes writes and commits a validated, bounded logical ID/kind/save-or-delete
manifest in reserved native metadata. Reads continue; repeated seal returns the
same value. Before-save cancellation rolls back; after-save cancellation returns
the committed seal. No file bodies are included. Limits default to 4096 / 100,000 /
10,000 transactions/native changes/final logical changes and 4 MiB encoded bytes.

`GraphContextManager.openMigrationWorkspace(for:at:limits:) async throws -> GraphMigrationWorkspace`
reacquires original holds and validates descriptor format 2, exact store/file
identities, source freshness, retained PH and complete structure/files. It restores
editable or sealed state without replay. Current URLs permit same-volume moves;
replaced/copied files and incompatible format-1 alpha workspaces are refused.
Source bookkeeping is allowed only with no reconstructed application effects.
Activations rotate cleanup authority; stale controls cannot delete a reopened
copy. Detached cleanup retains native claims through deletion and on failure.

`GraphContextManager.publishMigrationWorkspace(_:backupsIn:reason:limits:) async throws -> GraphMigrationPublicationResult`
seals/validates, verifies a complete original backup, then commits all selected
final records/deletes and a native receipt atomically on the original. Default
limits: 10,000 records and 32 MiB weighted logical payload; the normal pending
and native PH limits also apply. No source-file replacement or consumer replay.
`receipt` proves local commit, not cloud delivery; `backupURL` uses the current
caller root. `backupRetentionPending` reports a failed post-commit unpin without
turning success into failure. Retry/reopen recovers the latest matching native
receipt before source-freshness checks, preserving subsequent ordinary edits.
Only this workspace's source holds are released on commit. Failed attempts retain
the verified backup; corruption refuses retry. Participant workspaces remain
refused. See [MF04](../design/graphevo-2-migration-workspace.md) and
[MF05](../design/graphevo-2-migration-publication.md).


### Explicit local v1 conversion (package-only)

`GraphContextManager.convertLocalV1Store(at:to:graphID:operationID:backupsIn:reason:limits:) async throws -> GraphV1ConversionResult`
validates one stopped local v1 source, verifies/pins a complete legacy backup and
commits a distinct native S03 graph plus stable legacy-ID map/receipt atomically.
Source files/model are not rewritten; no old cloud identity or PH is imported and
no cloud session starts. The caller persists the request IDs and supplies current
URLs again after restart. Repeat the same request to recover its receipt without
overwriting later v2 edits. Source changes/foreign destinations are refused.

The result identifies local commit, current backup URL and any pending cleanup
with its error. Cleanup failure does not falsify a committed conversion or release
failed native ownership. Open with the existing awaited `openGraph(id:at:)` only
after successful conversion/cleanup; automatic public migration is not enabled.
Limits default to 10,000 records, 100,000 native rows and 32 MiB weighted payload,
with explicit native-preview/PH, mapping and receipt bounds. Unknown/ambiguous
values refuse conversion instead of dropping data. See [MF07](../design/graphevo-2-v1-local-conversion.md).


### Internal store migration definitions (package-only)

`GraphStoreMigrationDefinition<Snapshot, Intent, Receipt>` separates concrete
source inspection/conversion/receipt validation from ContextManager's shared
`migrateStore(using:request:limits:)` sequence. The factory supplies one explicit
`GraphStoreMigrationSource`; unsupported configurations fail before conversion.
`GraphStoreMigrationRequest` carries current URLs and stable request IDs without
serializing paths. `GraphStoreMigrationResult<Receipt>` distinguishes native
commit from pending cleanup. V1 error/limit/result names remain package aliases.
This is library infrastructure, not consumer registration or automatic public
migration. No public signature changes. See [MF08](../design/graphevo-2-store-migrations.md).
