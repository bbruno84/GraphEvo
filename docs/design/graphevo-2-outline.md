# GraphEvo 2 — design outline

Status: evolving discussion draft. This document records agreed requirements
and open design questions for the future specification. It is not an approved
architecture or a promise of final API behavior.

## 1. Context and purpose

GraphEvo evolved from CosmicMind/Graph and preserves its approachable graph
model. The maintainer reports approximately one month in production without
crashes or observed problems. That experience supports deliberate planning;
it does not establish concurrency safety for every usage pattern.

The next major version should preserve the useful domain concepts while making
store ownership, concurrency, and CloudKit integration explicit. Native Swift
Concurrency and sharing between users are central design goals.

This outline separates observations about v1 from proposed directions and open
decisions. Each accepted decision should eventually record its rationale,
alternatives, compatibility impact, and validation criteria.

Accepted direction: v1 compatibility must not constrain the v2 design. Public
APIs and the persistent model may change. An optional compatibility layer may
ease adoption where its behavior can be supported safely; its scope remains open.

## 2. Current baseline

The baseline is `develop` at `4dc0a7f`. This is a source and documentation review,
not a completed concurrency audit or a Swift 6 language-mode build assessment.

| Area | Current observation | Design pressure |
|---|---|---|
| Persistence | Uses persistent containers, a main-queue view context, private contexts, and Persistent History | Clarify resource ownership and execution boundaries |
| Multiple Graph instances | The registry serializes store opening and reuses compatible SQLite contexts and containers | Sharing a context also shares pending edits and invalidation effects |
| Operation coordination | Persistence locks and purge state belong to individual Graph instances | Coordination scope must match the shared resource scope |
| CloudKit | Private database integration, local fallback, history processing, and observer ownership already exist | Unify their lifecycle with store ownership; assess the one-independent-cloud-store restriction |
| Sharing | No public sharing lifecycle or shared-store topology is exposed | Define participants, permissions, graph boundaries, and failure behavior |
| Concurrency API | Saves and readiness use callbacks; queries and scoped transactions are synchronous | Define native asynchronous operations and cancellation semantics |
| Swift language | Package manifest uses Swift tools 5.9; public nodes remain context-bound and properties use `Any?` | Establish a Swift 6 isolation and value-transfer contract |
| Context execution | Synchronous searches, saves, and transaction steps use `performAndWait` | Use native asynchronous context access in asynchronous operation paths |
| Application models | Public properties are accessed dynamically through node facades | Define protocol-based integration for typed application models |
| Binary content | Transformable property values already allow external binary storage | Add a dedicated attachment contract beyond generic value storage |

The registry already provides meaningful protection. A race between instances
must be demonstrated with a reproducible scenario before it is recorded as a
confirmed defect. Likewise, a tools-version declaration alone does not prove
incompatibility with a Swift 6 compiler.

Baseline references:

- [Persistence](../concepts/persistence.md) and [CloudKit](../concepts/cloudkit.md).
- [Public API](../api/public-api.md), [watchers](../guides/watchers.md),
  [Persistent History](../migrations/persistent-history.md), and
  [structural validation](../guides/structural-validation.md).
- [Context setup](../../Sources/GraphEvo/Context.swift),
  [registry](../../Sources/GraphEvo/Persistence/GraphContextRegistry.swift),
  [Graph state](../../Sources/GraphEvo/Graph.swift), and
  [save operations](../../Sources/GraphEvo/Persistence/Storage.swift).

## 3. Goals and boundaries

Goals and agreed requirements:

- Preserve useful graph concepts and query/observation capabilities, while
  allowing public contracts and abstractions, including Search and Watch,
  to evolve or be replaced in a major release.
- Make supported usage safe under Swift 6 language mode and strict concurrency.
- Provide native asynchronous opening, reads, writes, and change observation.
- Use async/await wherever the operation involves asynchronous work; use Core
  Data's native asynchronous context APIs rather than blocking wrappers.
- Replace dynamic-member access as the primary application API with typed
  application models conforming to a GraphEvo protocol.
- Provide native attachment support through Core Data and its mirroring stack.
- Give each open store an explicit owner and consistent operation coordination.
- Design user sharing together with graph ownership and CloudKit topology.
- Keep distinct graphs as separate worlds, including in CloudKit, with no
  relationships between graphs. This is a requirement whose feasibility must
  be verified against supported Apple APIs before selecting an implementation.
- Design APIs and the persistent model around v2 requirements, allowing breaking
  changes independently of the optional v1 compatibility layer.
- Define an explicit adoption and data-transition strategy after establishing
  the target design.
- Keep local persistence useful independently of CloudKit.
- Strengthen querying and reassess observation against general library use
  cases, without assuming the current Watch abstraction must be retained.
- Remain independent of the integrating application. Real application needs
  inform priorities and validation without defining app-specific core contracts.

This planning phase does not authorize changes to production stores, CloudKit
schemas, deployment targets, or current public behavior. Replacing Core Data,
adopting SwiftData, or implementing a custom CloudKit synchronization engine is
not an accepted decision. Evaluate a backend change only against concrete
requirements and migration costs.

The integration boundary is Core Data and `NSPersistentCloudKitContainer`.
Application-facing models and attachments should not require direct handling of
CloudKit records, assets, or zones. Platform details may still be necessary for
configuration, sharing, and diagnostics; any such exposure needs justification.

Use the maintainer's application as one important consumer, alongside small
independent examples. Favor capabilities justified by the graph model and
supported persistence stack; avoid both embedding application workflows in the
core and speculative expansion unrelated to practical use.

## 4. Proposed architectural direction

### Store ownership and lifecycle

Explore a shared runtime for each store identity. It would own the container,
context creation, lifecycle state, operation coordination, remote observation,
and history processing. Public Graph instances would access this runtime rather
than each partially owning shared infrastructure.

Specify identity normalization, compatible configurations, concurrent opening,
failed opening, release and reopening, and independent stores. Distinguish
in-process coordination from separate processes accessing an App Group store.
CloudKit imports and external writers are outside an application actor's control.

### Identity, integrity, consistency, and recovery

These are foundational design areas to resolve, not selected implementations:

- Identity and integrity: distinguish domain identity, local persistence
  identity, and cloud mapping; define identity scope across graphs and devices.
  Define deletion rules, dangling references, duplicate identities, and how
  temporarily incomplete imported structures are represented. Do not assume
  application identity is interchangeable with a Core Data or CloudKit ID.
- Conflicts and consistency: state local transaction guarantees, read visibility
  during writes and imports, and concurrent-edit behavior. Separate what the
  library controls from eventual mirroring and platform conflict handling.
  Async/await alone does not establish a consistency model.
- Lifecycle and recovery: define opening, closing, reopening, account changes,
  permission loss, synchronization failures, and restore behavior. Expose useful
  states and errors so a consumer can choose a recovery action without depending
  on internal context management. Keep destructive recovery explicit.

### Isolation and graph objects

Choose the public isolation model before choosing actor placement. Candidates
include an isolated live-object API, scoped read/write access, and transferable
immutable snapshots. Compare them using the same application scenarios.

Define what may cross a task or actor boundary, how node identities are resolved,
and how application model values are represented. Context-bound facades must not
escape a scoped operation accidentally. An actor around a container alone does
not establish these guarantees.

### Typed application models

Requirement R03 — protocol-based model integration. Applications should use
their own typed models conforming to a GraphEvo protocol, replacing the current
dynamic-member property API as the primary integration surface. The intended
result is typed property access and compiler checking in application code.

The protocol name and requirements remain open. Define identity, graph type,
property encoding and decoding, and the representation of relationships and
actions. Decide whether models are value snapshots, isolated live objects, or
scoped representations, and how edits become durable. Do not assume that an
arbitrary conforming model is `Sendable` or independent of a context.

Explicit conversion is a candidate; macros or generated mapping may reduce
boilerplate later but are not agreed requirements. Retention of dynamic access
in an optional v1 adapter is a separate decision.

### Operations and observations

Requirement R02 — native Swift Concurrency. Use async/await for operations that
can be managed asynchronously, including opening, queries, writes, transactions,
and supported cloud/sharing operations. Return values and propagate errors
directly, using `async throws` where appropriate. Immediate property access and
pure in-memory operations need not become asynchronous merely for consistency.

Use `try await context.perform { ... }` where appropriate in asynchronous Core
Data paths. Its closure still executes on the context's queue and is synchronous;
the caller can suspend while awaiting its result. Do not wrap `performAndWait`
inside an async method and treat that as a concurrency redesign. Review existing
cross-context calls and lock ordering; thread-owned locks must not span an
`await`. Heavy persistence work needs private contexts, and context-bound objects
must not escape their execution boundary.

Callback adapters may remain internal where Apple only provides callback APIs.
Their presence does not invalidate an asynchronous contract. Merely naming a
method `async`, dispatching work, or marking a blocking method `async` does not
provide that contract. Apple's native asynchronous context API is described in
[Bring Core Data concurrency to Swift and SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10017/).

Define asynchronous opening and error delivery; read consistency; write commit
and rollback boundaries; pending-edit ownership; conflict handling; and
cancellation before, during, and after a durable save. Decide whether a write
body may suspend, since suspension can allow interleaving.

Evaluate an asynchronous change stream, including ordering, buffering, slow
consumers, cancellation, replay, and delivery guarantees. Specify how local
changes and remote history become observations without claiming that a completed
import means the entire graph is available.

### Query engine and observation

Requirement R05 — stronger graph querying. Explore typed property filters,
relationship traversal, sorting, pagination, counts, projections, and
aggregations. These are candidate capabilities to assess, not a commitment to
implement every query feature. Use representative graph questions to decide
which operations are valuable and feasible with Core Data.

Distinguish work translated into store queries from graph processing performed
in memory. Define costs, result consistency, pagination stability, and behavior
for unsupported expressions; avoid silently materializing an entire graph to
evaluate a filter. Deep traversal needs explicit bounds and cycle semantics
before any public contract is accepted.

Reassess Watch without deciding now to retain or remove it. Current consumer
uses include UI refresh, reacting to remote imports, and triggering data
processing. Capture these as general needs rather than application workflows:

- Execute a query once and obtain its result.
- Observe a query result as membership, ordering, or relevant values change.
- Consume changes for further processing, with an explicit delivery contract.

Evaluate whether these need separate APIs or can share infrastructure while
preserving distinct guarantees. An observable result is not automatically a
durable, replayable change log, and a change notification is not proof of cloud
completion. Assess `AsyncSequence` as a delivery surface alongside ordering,
coalescing, buffering, cancellation, replay, and idempotent-consumer needs.
The Watch name and existing callback structure are not requirements for v2.

### CloudKit and sharing

Requirement R01 — graph separation in CloudKit. Distinct graphs must remain
separate worlds, with no relationships between graphs. The desired cloud
separation applies both to personal graphs that have never been shared and to
graphs shared between users. Feasibility with Apple's supported resources,
particularly `NSPersistentCloudKitContainer`, remains to be verified.

Do not assume that separate SQLite stores produce separate cloud namespaces,
or that one graph can map to an arbitrary record zone. Verify the available
isolation boundaries, their constraints, and their behavior across devices
before choosing a store, zone, share, or container mapping. If the desired
separation cannot be achieved with the supported APIs, bring the limitation
back to discussion before changing the requirement or the synchronization stack.

The [V01 T1 experiment](results/v01-t1-2026-10-23.md) observed native rejection
of two stores assigned to the same cloud container/private scope within one
`NSPersistentCloudKitContainer`. The subsequent
[T5 experiment](results/v01-t5-2026-10-23.md) used two independent one-store
owners with the same model and private cloud destination: a fresh independent
iPad replica recovered both logical graphs together. Separate local files and
owners therefore did not satisfy R01 in that trial. R01 remains open; discuss
other supported boundaries before selecting a topology or changing the stack.
The [T6 owner-only share experiment](results/v01-t6-2026-10-23.md) remained
inconclusive at the first native share callback. Separate share zones are a
documented API capability, but their suitability for R01 has not been demonstrated
by this incomplete run; no sharing topology is selected from it.

Design private and shared data as part of the store topology only after this
feasibility check. Define the boundary of a shareable graph: root, included
nodes, relationship and action dependencies, and cycles within that graph.

Cover owner and participant behavior, invitation creation and acceptance,
read-only access, leaving, revocation, ownership constraints, offline work,
account changes, and unavailable shared data. Keep platform restrictions and
product policy separate; verify the relevant Apple APIs before accepting a
sharing design.

Local readiness, durable save, export, import, and share availability need
distinct meanings. Define fallback policy explicitly, particularly when shared
data cannot be opened safely or permissions have changed.

### Native attachments

Requirement R04 — native attachment support. GraphEvo should manage binary
content through Core Data and `NSPersistentCloudKitContainer`, without requiring
applications to manage `CKAsset` or implement a separate cloud transfer path.
Whether attachments are node properties, nodes in their own right, or both
remains open.

Documentation confirms the following foundation:

- A Core Data binary attribute can expose content as `Data` and enable
  `allowsExternalBinaryDataStorage`. This allows Core Data to choose external
  file storage; it does not require every value to be stored externally.
  See [Apple's attribute documentation](https://developer.apple.com/documentation/coredata/nsattributedescription/allowsexternalbinarydatastorage).
- The mirroring stack transparently maps variable-length values to CloudKit
  assets when needed. Local external storage and cloud asset serialization are
  distinct decisions managed by Apple. See
  [Reading CloudKit Records for Core Data](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data).
- V1 already enables external binary storage for transformable property values
  in [Model.swift](../../Sources/GraphEvo/Model.swift); this alone does not provide
  a public attachment lifecycle.

Explore a dedicated attachment representation with metadata and binary content,
including import from a file URL, reading, replacement, deletion, and export to
an application-usable file. A Core Data internal external-storage path must not
be treated as a stable public file URL. Define filename, content type, ownership,
temporary export lifetime, and cleanup behavior explicitly.

This is documentation-level feasibility, not a completed implementation test.
Measure memory and performance for representative file sizes. Verify sharing,
offline access, replacement, deletion, backup/restore of external content, and
cancellation behavior. Streaming, selective downloads, cache eviction, and
per-attachment transfer progress are not established capabilities of this design.
Local save completion must remain distinct from remote transfer completion.

## 5. Adoption and optional compatibility

V1 source compatibility and in-place store compatibility are not requirements
for the v2 core. Choose the target API and persistent model for correctness,
concurrency, and sharing first. Document the transition costs and supported
adoption paths without requiring the new architecture to reproduce v1 internals.

Evaluate an optional compatibility layer separately. It may adapt selected v1
patterns to the v2 core where their semantics remain safe. It must not weaken
the isolation model or promise behavior the core cannot provide. Full v1 API
coverage is not assumed; unsupported patterns may require application changes.

Treat these as separate decisions:

| Compatibility surface | Required investigation |
|---|---|
| Source API | Which v1 patterns merit an optional adapter, and which require application changes? |
| Local data | Does the target model permit direct reuse, or require explicit migration or export/import? |
| CloudKit data | Can existing cloud data be retained, or is a separate cloud transition required? |
| Operational behavior | What happens to migrations, history cursors, watchers, backups, and reset flows? |

Do not assume that preserving source API names preserves store compatibility,
or that a compatible local store establishes CloudKit continuity. Define backup,
failure recovery, and downgrade limits before enabling any transition.
Incompatible stores must not be silently rewritten or moved. An API adapter
does not by itself migrate SQLite or CloudKit data.

## 6. Decisions to resolve

All entries are open. Proposed directions above are inputs to these decisions.

| ID | Question | Evidence needed before acceptance |
|---|---|---|
| D01 | What owns an open store and how is its lifetime managed? | Concurrent-open and multiple-handle lifecycle scenarios |
| D02 | Are public nodes isolated live objects, scoped facades, snapshots, or a combination? | Small consumer examples compiled with strict concurrency |
| D03 | What defines a transaction and can its body suspend? | Atomicity, cancellation, conflict, and reentrancy scenarios |
| D04 | How are typed model properties encoded and transferred? | Supported-value inventory, strict-concurrency examples, and target-model encoding review |
| D05 | What is the shareable unit and how are private/shared stores organized? | Owner/participant prototype and graph-boundary rules |
| D06 | What guarantees does change observation provide? | Ordering, replay, deletion, and slow-consumer scenarios |
| D07 | Which adoption paths and optional v1 adapters should be supported? | Target-model transition experiments, adapter feasibility, and application adoption examples |
| D08 | What are the minimum OS, tools, and Swift language versions? | Required API availability and consumer impact assessment |
| D09 | How are cloud failure, fallback, and account changes represented? | State transitions and recovery scenarios |
| D10 | Can R01 be implemented using supported Apple APIs, and with what isolation guarantees? | Apple documentation/API review and a multi-graph, multi-device prototype covering unshared and shared graphs |
| D11 | What protocol maps application models, identity, relationships, and actions to the graph? | Typed consumer examples covering read, edit, save, and relationship traversal |
| D12 | What attachment representation and lifecycle can the selected stack support? | Binary-storage prototype, memory measurements, external-content backup/restore, and cross-device sharing checks |
| D13 | Which query operations belong in v2, and how are execution cost and unsupported expressions exposed? | Independent typed-query examples, Core Data translation experiments, and traversal/pagination benchmarks |
| D14 | What identity, integrity, and conflict contracts apply across devices and imports? | Identity round trips, deletion/incomplete-import scenarios, and concurrent-edit tests |

## 7. Validation scenarios for the specification

The specification should attach observable acceptance criteria to at least:

- Two handles opening and using the same store, including incompatible requests,
  pending changes, concurrent transactions, reset, purge, and handle release.
- Two independent stores, plus an app and extension using the same App Group
  store; explicitly state the guarantees in each case.
- Swift 6 consumers reading, writing, and observing across actor boundaries.
- Native async context operations without blocking bridges or locks held across
  suspension, with error propagation and explicit cancellation outcomes.
- Typed application models without dynamic-member access, including identity,
  relationships, persistence round trips, and supported boundary transfers.
- Attachments of representative sizes, covering import/export, metadata,
  replacement, deletion, offline reads, backup/restore, and shared access;
  simulated tests and real-device mirroring checks must be distinguished.
- Cancellation around commit and observation delivery; conflicts involving
  local writers and remote imports.
- Private CloudKit synchronization across devices, separately from simulated
  history and injected identity tests.
- Sharing between different accounts, including offline edits, read-only
  participants, invitation acceptance, revocation, and account changes.
- The selected transition paths from populated v1 local and CloudKit stores,
  with backup and failed-transition recovery; direct opening is not assumed,
  and reopening and downgrade limits must be explicit.
- Any selected compatibility adapters, including explicit rejection of v1
  patterns that cannot preserve v2 isolation and operation guarantees.
- Queries covering typed filters, related nodes, stable ordering/pagination,
  counts, and selected aggregations; compare store execution with any explicit
  in-memory processing and test bounded traversal over cycles.
- Query observation and change consumption as separate contracts, covering
  membership changes, reordered results, deletion, remote imports, slow
  consumers, cancellation, and any selected replay behavior.
- Identity continuity across devices, deletion integrity, duplicate identities,
  and temporarily incomplete imported data.
- Account changes, revoked permissions, failed opening, closing/reopening,
  and documented recovery paths with actionable errors.
- Small consumers independent of the maintainer's app, exercising both UI-facing
  observation and non-UI data processing without application-specific hooks.

Performance and verifiability apply across all areas. Establish representative
data sets and measurable budgets for query latency, attachment memory use, and
import/observation processing before accepting performance claims. Keep local
unit tests, simulated remote history, and real cross-device/account acceptance
checks explicitly distinct; no single category substitutes for the others.

## 8. Path from outline to specification

Before drafting the normative specification, follow the separate
[framework verification roadmap](graphevo-2-verification-roadmap.md), starting
with recovery and assessment of GraphEvoDemo. Experiment outcomes inform the
decisions below; this outline does not imply those experiments have run.

1. Agree on goals, supported application scenarios, and release boundaries.
2. Audit current ownership and concurrency behavior; reproduce suspected defects.
3. Resolve foundational identity, ownership, and consistency questions before
   building higher-level contracts. Check Apple constraints on graph separation
   and sharing early, since they may affect these foundations.
4. Compare minimal public API sketches through focused prototypes with multiple
   handles, Swift 6 consumers, and sharing between accounts. Build typed models,
   queries, observation, and attachments on the validated foundations, using
   independent consumer examples as well as the maintainer's application.
5. Resolve the remaining decisions, define data-transition paths, and evaluate
   optional compatibility adapters against the target design.
6. Write the normative specification: API contracts, state transitions, error
   model, persistence and sharing topology, acceptance criteria, and rollout.
7. Plan implementation in validated increments, keeping v1 maintenance separate.

Record accepted decisions with date, rationale, rejected alternatives, and
evidence. Keep unresolved questions visible rather than presenting illustrative
API sketches as final contracts.
