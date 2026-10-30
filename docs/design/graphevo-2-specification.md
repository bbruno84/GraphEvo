# GraphEvo 2 — initial specification

Status: initial specification, 2026-10-26. The
[A1 runtime increment](graphevo-2-store-runtime.md) implements the first local
ownership foundation; other working contracts are not implied to be implemented.
This is the current design entry point; the [outline](graphevo-2-outline.md)
retains the earlier discussion and the [verification register](graphevo-2-test-checklist.md)
retains experimental evidence. The [delivery plan](graphevo-2-delivery-plan.md)
defines implementation order and release gates. The [decision register](graphevo-2-decisions.md)
separates maintainer decisions, technical proposals and unresolved choices.

**Agreed requirements** record explicit maintainer direction. **Working
contracts** are technical proposals for implementation and review during alpha.
**Open decisions** have no selected contract yet. Proposed API names, internal
types and storage representations may change throughout alpha.

## 1. Product and release boundary

GraphEvo remains an independent Swift graph library built on Core Data. M17
selects explicit CloudKit synchronization through CKSyncEngine, replacing the
initial NSPersistentCloudKitContainer direction. See the
[transition contract](graphevo-2-custom-sync-transition.md) for ContextManager engine
ownership and per-graph GraphCoordinators. Earlier native-mirroring sections
remain historical working contracts pending their replacement.
It supports local persistence without an
iCloud account and synchronization/sharing when explicitly configured. The
application supplies its domain models and owns its UI and business workflows.
GraphEvo owns persistence, graph integrity and its documented synchronization
integration. UI-specific adapters may sit above the core.

V2 minimum OS versions may be raised as needed for the chosen architecture and
APIs. The v1 deployment floors are not a compatibility requirement. Record the
technical rationale and test matrix when selecting a new floor; compiler/SDK
requirements and deployment availability remain separate decisions.

The release is **2.0**, developed through alpha releases followed by beta
releases. V1 remains a separate maintenance line. There is no requirement to
ship successive transitional architectures through the 1.x public API.

All eight implementation areas in the delivery plan remain alpha work. Schema
and API consolidation occurs at the beta gate, after query and observation
work has tested the foundations. Mandatory v1 data migration is designed and
exercised throughout alpha, then completed and validated during beta.

Source compatibility is optional. A compatibility adapter may be considered
after the v2 contracts stabilize; it must preserve their isolation and error
semantics. **Migration of existing v1 data is mandatory.** Physical in-place
opening, unchanged internal filenames and unchanged cloud record IDs are not
assumed migration techniques.

The cloud transition uses a **coordinated cutover**: v1 stops writing before
conversion. Concurrent v1/v2 writes to the same cloud dataset are not a required
operating mode. Establishing and verifying that prerequisite is part of the
migration design, not an assumed capability of the old clients.

## 2. Requirements and traceability

| ID | Agreed requirement | Specification area | Verification |
|---|---|---|---|
| R01 | Separate graphs remain independent worlds, including personal cloud graphs and graphs shared with other users; no cross-graph relationships | Sections 3 and 7 | V01, V02 |
| R02 | Swift 6 support and native async/await wherever asynchronous work is appropriate | Sections 4 and 5 | V03 |
| R03 | Protocol-based application models replace dynamic-member access as the primary API | Section 6 | V04 |
| R04 | Native file/attachment lifecycle through Core Data and its mirroring stack | Section 8 | V05 |
| R05 | Stronger querying with explicit capabilities and costs | Section 9 | V06 |
| R06 | Store/context ownership and coordination match the resource shared by Graph handles | Sections 4 and 5 | V03, V08 |
| R07 | Reassess Watch for query observation, remote changes and processing needs | Section 10 | V07 |
| R08 | Migrate v1 data into v2, including a defined cloud transition and recoverable failures | Section 11 | V08 and dedicated migration fixtures |
| R09 | Deliver directly as 2.0 through alpha and beta; keep schema flexible through all eight alpha areas | Section 1 and delivery plan | Release gates |
| R10 | Remain independent of the integrating app; Core Data is the integration boundary | Sections 1, 6 and 7 | Independent sample consumers |

The verification IDs refer to the existing register. A partial observation is
evidence for a design candidate, not acceptance of its entire requirement.

## 3. Graph semantics, schema and identity

### Agreed requirements

Preserve the domain concepts of Entity, directed Relationship and Action with
subjects and objects. Tags, groups, node properties and graph structure from v1
must have a migration destination even if their representation changes.

The current persistent schema was the first candidate exercised by A1–A8 and
consolidation. The [S01 native schema decision](graphevo-2-persistent-schema.md)
now fixes the 2.0 target: retain that structure, add graph/node UUID projections
and an optional application record-format version, with the existing compound
identity indexes. Query, attachment, sharing and migration review justifies no
other native structure. S01 records exact fields, semantics, adoption work and
the evidence required to reopen the decision. The single-entity V09 laboratory
model remains framework evidence, not the selected library schema.

The [A2 implementation contract](graphevo-2-async-transactions.md) records the
local runtime behavior, trusted adapter restrictions and cancellation boundaries.
A3 now connects typed public scopes through the
[local typed store](graphevo-2-typed-store.md), with legacy/runtime ownership exclusion. A2 raises macOS to 13 for the native cancellation
signal lock; iOS remains 16. These provisional floors follow M11.

### Working contracts

- A logical graph is a membership and sharing boundary. A physical SQLite
  store is a persistence resource. They are separate concepts even when an
  early local implementation happens to map them one-to-one.
- A graph includes its entities, relationships, actions, detail rows and
  attachments. Dependencies belong to the same graph. A library write rejects
  a reference to another graph before committing that mutation.
- Cycles within a graph are supported by the domain model; traversal must be
  bounded. Sharing validation must include cycles and disconnected members
  before the graph-membership implementation is accepted.
- Public logical identity includes graph identity and node identity. It must
  remain meaningful across reopening and supported device replication; it is
  distinct from Core Data object IDs, CloudKit mappings and application keys.
  The storage representation and v1 identity translation remain D14 decisions.
- Applications may have business keys distinct from library identity. An
  unrelated record with the same business key is not silently merged.
- Duplicate logical identities are reported or reconciled by an explicit
  policy. A uniqueness assertion inside one process is not a distributed lock.
- Locally committed structure must satisfy the documented graph invariants.
  Remote imports can expose incomplete structures. Reads must distinguish
  absent optional data, unresolved dependencies and decoding failure rather
  than manufacture required values or silently discard invalid objects.
- Deleting an entity removes its incident directed relationships and membership
  in action endpoint sets within the same local operation. Other endpoint
  entities survive. The policy for an action left without endpoints remains
  provisional; migration must preserve valid existing empty/optional structures.
  Detail and attachment cleanup must avoid orphaned owned content.

Before beta, implement and validate S01, publish supported model identifiers and
complete the v1 mapping. Selection of the target does not close those gates.

## 4. Resource ownership, lifecycle and isolation

### Working contracts

One process-local runtime owns a compatible open persistence resource set:
container, store loading, private contexts, operation admission, history
processing and native observation. Graph handles access that runtime; each
handle selects a logical graph. Multiple graphs may share the physical runtime
without sharing logical membership or unsaved edits.

Concurrent compatible opens join one opening operation. An incompatible request
for an already-owned or overlapping resource set fails explicitly. Resource
identity includes resolved file locations, backend, model compatibility and
cloud destination/environment. An in-memory resource has an explicit identity
instead of being coalesced accidentally by a calculated file URL. URL alias
handling must be tested; unsupported aliases are rejected or documented rather
than presented as separate owners of the same file.

Opening is an awaited operation returning a usable handle or a typed error.
Its successful result means local persistence is usable in the reported mode;
it does not mean cloud recovery, share preparation or graph import is complete.
Expose separate local lifecycle, synchronization and access states.

Releasing/closing one handle invalidates that handle and its subscriptions,
without invalidating another live handle. Final runtime shutdown stops new work,
drains admitted commits, stops observers and detaches stores. A stale handle
rejects new work. Reset, graph deletion and store destruction are distinct,
explicit operations with their affected scopes identified.

The runtime is not globally MainActor-isolated. Core Data work stays on its
context queue; supported async paths use native asynchronous context execution.
Do not implement them by wrapping `performAndWait` in an async declaration.
Thread-owned locks never span suspension points. Any callback bridge must
handle completion, errors and lifetime exactly once, and document synchronous
native work that it cannot make nonblocking by adding a continuation.

The public default is immutable transferable model values, IDs and query
descriptors. Context-bound mutation/read adapters are confined to their operation
scope. Managed objects and contexts are implementation details; they never
become Sendable by assertion or escape to another task. Application model
conformance alone does not confer Sendable conformance.

An actor/registry protects only participating writers in its process. Remote
imports and other processes require separate conflict and visibility policies.
App Group app/extension access is an explicit support decision before beta,
backed by iOS tests if included. The macOS two-process probe is not that proof.

### A1 implementation decisions

An internal Swift 6 target owns one local resource per entry. Native async
container operations supply operation-scoped private contexts, avoiding transfer
of a retained non-Sendable context on older SDKs. The existing Graph facade is
not rewired yet. Model identity crosses the boundary as immutable
hashes and a fresh-model factory, not a cached native model. Compatible callers
receive independent leases; only the final lease detaches the native store.
Opening cancellation releases a caller's lease after native loading completes;
it does not cancel other waiters. A failed shutdown retains ownership and its
error until an explicit future recovery policy can handle it. Explicit close is
awaited; deallocation initiates best-effort release. See the A1 document for
file alias rules, failure boundaries and acceptance evidence.

After an opening suspension, revalidate the current registry generation, lease
and any established file identity. A snapshot taken before file creation must
not overwrite a fingerprint established by another completed opening waiter.

## 5. Reads, transactions, cancellation and failures

### Working contracts

| Operation | Successful completion means | Failure/cancellation boundary |
|---|---|---|
| Open | Local resources usable in the reported configuration/mode | No silent replacement of an incompatible store |
| Read | A decoded result from the documented local read view | Missing, unresolved and invalid data are distinguishable |
| Local transaction | Its mutation was durably saved in the target local store | Roll back its own unsaved edits on a pre-commit failure |
| Share operation | The named native sharing step reached its reported state | Partial preparation is visible and reconciled explicitly |
| Observe | Initial/current state or documented change information delivered | Delivery does not acknowledge cloud convergence |
| Close | This handle released; final runtime close also drained/detached | Does not discard another handle's admitted work |

A local transaction targets one graph and one store. Its scoped body is
synchronous and throwing, even though admission/execution is awaited. External
I/O is prepared beforehand and the state is revalidated inside the transaction.
There is no suspension, nested transaction, independent save or externally
visible side effect inside that body. Results crossing isolation boundaries
are safe values. A failed operation cannot leak pending edits into the next
operation or save another handle's uncommitted state.

Participating local writes are serialized per physical writer resource. An
actor suspended while awaiting `context.perform` is not itself a transaction
lock. Admission/shutdown and context execution must enforce the policy together.
Serialization does not imply serializable transactions against remote imports.
Read-view consistency, stale-write checking and the external conflict policy
must be selected and tested before beta; disjoint-edit convergence does not
settle same-property conflicts. Do not rerun arbitrary transaction bodies
automatically after a conflict.

Cancellation observed before the operation commits prevents the pending write
where the operation can still cooperate. Carry the caller's cancellation
signal explicitly into native work when necessary. Once saving has begun,
cancellation may not prevent commit. After a known durable save, return the
committed outcome rather than a cancellation error implying rollback.
Interruption with an uncertain outcome requires reconciliation by operation
identity/state; it must not trigger blind replay.

Ordinary transactions make no atomic guarantee spanning CloudKit export,
share assignment, invitation delivery or multiple stores. Membership preparation
may require native asynchronous steps outside the local transaction. Those
steps need separate progress/outcome and recovery rules, especially when an
earlier step already persisted data.

Errors identify the operation and affected scope, and distinguish configuration,
incompatible store, unavailable/closed resource, ownership mismatch, missing
data, decoding, integrity, conflict, permission, cloud availability and migration
failures. Preserve useful underlying errors without including payloads or
private account/invitation data in default diagnostics. Retry guidance is
specific; a generic cloud error is not permission to delete and rebuild a store.

## 6. Typed application models

The [first A3 increment](graphevo-2-application-models.md) supplies GraphModel,
GraphRecord, graph-aware value IDs, explicit values and partial patches through
the public GraphEvo product. A package adapter exercises the current schema;
the [A3 continuation](graphevo-2-typed-store.md) adds public scoped CRUD,
persisted graph/node IDs, a versioned value envelope and current-schema local
v1 adoption with backup. The plain legacy bridge retains its null restriction;
the typed path preserves explicit null. Complete source/codec and cloud migration
remain pending. These alpha contracts are subject to revision.

### Working contracts

Applications conform their models to a GraphEvo protocol with explicit mapping
of logical type, identity, property encoding/decoding and relationship/action
references. The first candidate uses GraphModel with GraphPropertyValue conversions; the
protocol naming and capability split remain alpha design choices. No macro is required to use
the core API; generation may be evaluated later.

Ordinary reads return values detached from a context. Editing a previously read
value is local application work until it is submitted to an explicit mutation
operation. Changes are validated against current stored state/selected revision
policy rather than accidentally saving a stale whole-model replacement.
Scoped adapters provide graph operations without exposing Managed classes.
Live context-bound models are not the primary cross-task API.

The mapping contract distinguishes missing property, explicit absence, invalid
representation and unsupported value type. Decoding errors propagate. The
supported value/codec matrix must cover v1 values or give a lossless retained
representation plus an application conversion hook. Unknown logical types or
keys cannot be silently deleted during migration or a partial typed edit.

Persisted type/property keys are explicit and stable across Swift renames.
`Codable` is an encoding option, not an automatic promise that all nested fields
are store-queryable. Model references use graph-aware identities; loading a
model does not implicitly fetch an unbounded connected graph.

Acceptance examples include a UI consumer and a non-UI consumer, typed round
trips, failed decoding, partial updates, Entity/Relationship/Action models,
tags/groups and cross-task transfer without concurrency suppressions.

## 7. Graph separation, mirroring and user sharing

### Agreed requirements and evidence

Distinct graphs remain separate cloud worlds even before inviting another
user. Apps operate through GraphEvo/Core Data rather than CKRecord/CKAsset
mutation. Apple-specific configuration, native sharing UI integration and
diagnostics may require a narrow explicit platform boundary.

The working cloud topology is a runtime with private and shared stores, with
one owner-only share boundary per personal graph, later inviting users to that
same graph. V01/V02/V09 support this candidate under tested conditions.
Separate zones do not promise one local SQLite per graph, selective download,
independent encryption or unlimited zone count. The [A4 implementation](graphevo-2-graph-separation.md)
now tests the actual v1-derived candidate model, including owned detail rows,
cycles, disconnected entities and empty endpoints. It uses the owner-private
resource for personal graphs. The [A5 candidate](graphevo-2-user-sharing.md) adds
the shared-store resource pair, participant routing, explicit native assignment
of new detail rows and local durable intent recovery. The schema remains an
alpha candidate; cloud migration and account-change policy remain release gates.

### Working contracts

- Every member, including properties, tags/groups, edges, actions and files,
  belongs to its graph's native sharing boundary. Disconnected members are
  included intentionally; reachability from one business entity is insufficient.
- A participant-created member is routed to the appropriate shared store and
  existing share before unsafe links are introduced. The supported insertion
  procedure is library-owned and tested with exact identity/membership checks.
  V09's successful array assignment does not erase earlier insertion failures.
- Expose invitation creation/acceptance, owner/participant role, read/write
  permission, leave and revocation with distinct outcomes. Native metadata
  availability may lag; pending is not equivalent to absent or denied.
- Honor public permission advice before writes. A local save is not evidence
  that a participant was authorized to publish or that its edit will propagate.
  Server-side permission changes can race local work and require reconciliation.
- Distinguish local readiness, local commit, export/import activity, known graph
  integrity and access state. Do not offer a global synchronized/completed
  Boolean based on container events or local emptiness.
- Local-only graphs work without iCloud. For a configured cloud graph, the
  default proposal is an explicit degraded/unavailable state, preserving its
  identity and cached data; no silent substitute graph/store is created.
  Account changes and revoked shared access do not trigger automatic republishing
  of retained data to a different account. Exact cache/access policy remains D09.
- The host controls lifecycle integration and native presentation. The library
  exposes semantic operations and small platform adapters, not app workflows.

Offline/reconnect, permission races, same-property conflicts and account changes
remain explicit acceptance gaps. A successful bounded recovery is evidence of
that fixture, not a cloud latency or global-completeness guarantee.

## 8. Files and attachments

### Working contracts

Provide attachment import, metadata/read, replacement, deletion and export
through Core Data and its mirroring stack. Use a dedicated binary lifecycle;
whether its storage is a node, property or separate owned detail is decided
during alpha. An attachment has a graph, an owner/reference policy, a filename,
content type and stable identity. Shared content follows the graph's access
boundary. Deleting owned content cleans up references and bytes according to
the selected ownership policy.

Import/export accepts application file URLs without exposing Core Data's
internal storage paths. Import reads the selected content rather than retaining
an unsafe dependency on the source URL. Export has explicit file ownership and
cleanup: the default proposal is an application-selected destination owned by
the caller, with any temporary convenience export documented separately.
Security-scoped URL access and long file I/O are prepared outside write scopes.

Local replacement either preserves the previous committed content or commits
the new content with corresponding metadata. Remote visibility and multi-row
metadata/content consistency follow the selected representation and need
validation; no atomic cross-device file delivery is assumed.

V09 establishes byte/checksum recovery for 512-byte and 10 MiB files across
accounts, replacement and deletion. It does not establish peak memory,
streaming, per-file progress, selective download, eviction or offline retention.
Publish a measured supported envelope before beta; unsupported capabilities
must be stated rather than simulated by misleading API states.

The [A6 candidate](graphevo-2-attachments.md) uses one logical attachment Entity
with a versioned metadata/content value over the unchanged native model. It
selects exclusive same-graph ownership by any application node, a 10-MiB alpha
buffered-content envelope, local revision checks and opaque whole-directory
backups from closed sources. It neither freezes that representation nor changes
ordinary v1 binary properties into attachments without explicit migration.

## 9. Query engine

### Working contracts

Queries are typed descriptions evaluated asynchronously against one logical
graph. Initial core capabilities are type/identity/property/tag/group filters,
Boolean composition, deterministic sorting, limits and count. Add relationship
and action predicates, projections, pagination and selected aggregations during
alpha based on translation and cost evidence. Exact supported operators/types
must be listed before beta.

Composition has one explicit meaning: a descriptor contains an explicit
Boolean expression; successive filters combine with AND in the proposed v2
API, while OR is requested explicitly. This differs from v1's successive-where
behavior and must be highlighted in migration/API-adapter guidance.

No unsupported expression silently falls back to fetching the entire graph.
Reject it with a capability error or require explicit bounded in-memory work.
Related-node predicates must include graph scope. Traversal specifies direction,
depth/work bounds, cycle handling and duplicate semantics. Stable ordering uses
a deterministic identity tie-breaker.

The initial pagination proposal is cursor-based current-state pagination.
Intervening edits can change later results; it is not a frozen multi-page
snapshot. Snapshot pagination is a separate capability if adopted. Query
results identify the promised local view rather than implying cloud completeness.

The [A7 candidate](graphevo-2-queries.md) implements this contract with an
explicit bounded native inventory and memory evaluator over the current encoded
layout. Its capability matrix fixes missing/null behavior, exact numeric cases,
related/BFS limits, cursor binding and local-view identity. This is not native
scalar predicate/count/projection pushdown or a performance certification.
Attachment ownership remains unchanged; its representation costs are assessed
at the agreed end-of-alpha consolidation.

## 10. Observation and the future of Watch

### Agreed requirement and working contracts

Retain the three consumer needs: one-shot queries, updated query results, and
changes used for processing. The Watch name and current delegates are optional.
Share infrastructure where useful while documenting each delivery contract.

The default query-observation proposal is an AsyncSequence of immutable current
results: initial fetch, subsequent relevant refreshes and explicit termination.
Bounded buffering may coalesce superseded states because this API represents
current state. Cancellation releases its resources; resubscription fetches a
new current result. Related properties that affect membership/order/value must
invalidate correctly, not only direct changes to the fetched entity.

Processing changes is separate from coalesced query state. Before beta decide
whether v2 supports durable replay or only a bounded live feed plus explicit
rescan. If durable processing is included, specify consumer identity, cursor
persistence, acknowledgement, retained-history gaps, deletion reconstruction,
retry and idempotency. Do not promise exactly-once side effects. If replay is
deferred, document the limitation and the application's recovery route.

Observation states include invalid/undecodable/incomplete imported data and
unmaterialized deletions where relevant. A token or notification cannot certify
that a whole graph has arrived. Callbacks/stream continuations are not invoked
under persistence locks or inside mutation scopes in a way that permits reentry.

The [A8 candidate](graphevo-2-observation.md) implements bounded newest-state
async observation, conservative resource-group dependency invalidation and a
cold demand-aware Combine adapter. Processing currently offers live rescan
hints; O04's durable replay choice remains open. Recoverable query errors are
states, handle close terminates its feeds, and native account-change hints are
sticky/terminal for query observation. These are alpha contracts, not complete
account/cache policy, migration feasibility or beta acceptance.

## 11. Mandatory v1 data migration and recovery

### Agreed requirement

Every supported v1 data format has a documented path into the final v2 model.
Start with the current supported v1 release/develop baseline, freeze named source
model fixtures early, and identify any older supported variants before beta.
An unchanged-schema alpha must not be represented as proof of final migration.

GraphEvo manages native Core Data schema transitions internally. The renewed
consumer migration manager handles application-data formats and transformations,
not consumer registration of native schema plans. External native interventions
are not automatically supported. Application versions and compatibility are
consumer-owned ordinary data, not native schema fields or a Graph registry.
[S02](graphevo-2-identity-schema.md) retains graph/node identity only. Migration
execution must still account for partial and later imports; no journal marker
or application version is a cloud pause or complete-import certificate.

Migration preserves logical graphs, node kinds/types, values and their encoding
meaning, tags, groups, valid optional/absent values and timestamps, directed
links, action endpoints and owned binary content. Unsupported legacy codecs or
corrupt structures produce actionable findings and an explicit conversion or
retention policy; they are never silently skipped. Library migration cannot
infer arbitrary application business semantics.

V1 node IDs currently incorporate a Core Data URI component. Rebuilding a store
may change them. Inventory their application use and provide retained logical
IDs or an explicit graph-scoped old-to-new identity mapping. Do not promise
unchanged physical object/cloud IDs as a substitute for logical preservation.
Source identity and translated references must be verified together.

### General migration service

Consumer-authored migrations cover native Core Data schema transitions and
application-data transformations; GraphEvo manages registration, route selection,
resource admission, awaited execution, recovery, validation and activation.
Schema/data stages may interleave under explicit source/target capabilities.
RecoveryV2 is one real compatibility/regression example, not the service template.

Whole-migration completion does not disable compatibility processing of later
cloud records. Version native layout, logical record formats and migration
operations independently. After native imports, detect supported old-format
inserts/updates and apply registered transformations under revision/dependency
and permission checks. Retain future/unknown data with explicit incompatible or
update-required states; never silently downgrade or omit incompatible rows from
successful typed results. Do not assume a pre-import interception mechanism.

The [manager renewal contract](graphevo-2-migration-manager.md) details the
consumer/library boundary, native framework limits, compatibility experiment,
durable processing and required acceptance matrix. These requirements are not
implemented by the package-only M1 journal. The coordinated initial v1 cutover
below remains required; general compatibility processing cannot stop unsupported
old clients or certify complete source synchronization.

### Working migration protocol

1. Identify source model/version, graph scope, codecs, cloud environment and
   transition policy. Refuse ambiguous sources without overwriting them.
2. Establish controlled source access and a supported consistent backup,
   including external content. Copying an actively mirrored SQLite directory
   is not a defined backup. Byte-preservation claims require testing on the
   actual backup/inspection path.
3. Prepare the destination and durable migration journal with source identity,
   transformation version, progress and identity mapping. Recovery must tolerate
   interruption without blindly repeating already-applied effects.
4. Transform and verify values and topology, including unknown-but-preserved
   keys, action endpoints, attachment bytes and duplicate identity detection.
   Validation is semantic, not just equal row counts.
5. Activate only a validated destination. Document replacement/reopen mechanics,
   source retention, failure recovery and rollback boundaries.
6. Complete the separately designed cloud transition and replica recovery.
   Distinguish local validation from remote replication evidence. Retire source
   data only under the documented transition policy.

This protocol allows a validated compatible reuse path or a staged conversion;
it does not preselect export/import or in-place mutation. Cleanup, cancellation
and resumption have explicit phases. Observational KVS metadata is not a
distributed migration lock or a cross-device commit acknowledgement.

Cloud migration must account for existing v1 records in the old cloud layout,
repeated migration on other devices, duplicate prevention, late v1 writers,
missing local cloud data and fresh v2 replica recovery. The agreed mode is a
coordinated cutover: v1 stops writing before conversion. Define how the host
establishes the cutover, reconciles pending source writes and handles an offline
old device returning later. Neither a local flag nor a container export event
proves that all old devices have stopped or that the source is complete. Until
the cutover prerequisites are satisfied, expose migration as pending/blocked
rather than activating a destination as if it were complete. Concurrent normal
v1/v2 writing is not a requirement; late-writer recovery still needs a policy.
Cloud continuity is mandatory as a supported transition outcome; unchanged
zones/record IDs or zero downtime are not assumed. Do not automatically create
a fresh empty cloud graph and label that a successful migration.

Beta must complete real representative v1 local/cloud conversions, interruption
and retry checks, independent-device recovery and application adoption. A
downgrade is only supported where explicitly documented; restoring a local
backup cannot undo cloud changes already published. The final 2.0 cannot ship
with data migration left to an optional API compatibility layer.

## 12. Evidence, scope and completion

The [post-alpha checklist](graphevo-2-post-alpha-checklist.md) consolidates
remaining end-of-alpha decisions and beta/stable acceptance work. Update it
when introducing or closing an implementation follow-up.

Use the existing verification register as the test inventory. Add v2 integration
acceptance cases alongside direct-framework results. Compile independent UI and
non-UI consumers in Swift 6; distinguish local/unit, simulated history, simulator
and physical cross-device/account evidence. Record performance budgets only
after representative datasets and file sizes are measured.

The [decision register](graphevo-2-decisions.md) owns unresolved choices; the
[delivery plan](graphevo-2-delivery-plan.md) owns release gates. A new failure
updates the evidence and affected decision rather than retroactively changing
a successful experiment's scope. None of these documents changes the current
v1 public API or authorizes production schema/store conversion.
