# GraphEvo 2 — design outline

Status: initial discussion draft. This document is a working outline for the
future specification, not an approved architecture or a promise of API behavior.

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

Proposed goals:

- Preserve the concepts of Graph, Entity, Relationship, Action, Search, and Watch,
  while allowing their public contracts to evolve in a major release.
- Make supported usage safe under Swift 6 language mode and strict concurrency.
- Provide native asynchronous opening, reads, writes, and change observation.
- Give each open store an explicit owner and consistent operation coordination.
- Design user sharing together with graph ownership and CloudKit topology.
- Provide a documented adoption path for applications and existing data.
- Keep local persistence useful independently of CloudKit.

This planning phase does not authorize changes to production stores, CloudKit
schemas, deployment targets, or current public behavior. Replacing Core Data,
adopting SwiftData, or implementing a custom CloudKit synchronization engine is
not an accepted decision. Evaluate a backend change only against concrete
requirements and migration costs.

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

### Isolation and graph objects

Choose the public isolation model before choosing actor placement. Candidates
include an isolated live-object API, scoped read/write access, and transferable
immutable snapshots. Compare them using the same application scenarios.

Define what may cross a task or actor boundary, how node identities are resolved,
and how dynamic property values are represented. Context-bound facades must not
escape a scoped operation accidentally. An actor around a container alone does
not establish these guarantees.

### Operations and observations

Define asynchronous opening and error delivery; read consistency; write commit
and rollback boundaries; pending-edit ownership; conflict handling; and
cancellation before, during, and after a durable save. Decide whether a write
body may suspend, since suspension can allow interleaving.

Evaluate an asynchronous change stream, including ordering, buffering, slow
consumers, cancellation, replay, and delivery guarantees. Specify how local
changes and remote history become observations without claiming that a completed
import means the entire graph is available.

### CloudKit and sharing

Design private and shared data as part of the store topology. Define the
boundary of a shareable graph: root, included nodes, relationship and action
dependencies, cycles, and links to data outside the share.

Cover owner and participant behavior, invitation creation and acceptance,
read-only access, leaving, revocation, ownership constraints, offline work,
account changes, and unavailable shared data. Keep platform restrictions and
product policy separate; verify the relevant Apple APIs before accepting a
sharing design.

Local readiness, durable save, export, import, and share availability need
distinct meanings. Define fallback policy explicitly, particularly when shared
data cannot be opened safely or permissions have changed.

## 5. Compatibility and adoption

Treat these as separate decisions:

| Compatibility surface | Required investigation |
|---|---|
| Source API | Which v1 patterns remain, need adapters, or require application changes? |
| Local data | Can existing SQLite stores be opened with the same model and metadata? |
| CloudKit data | Can existing records, zones, identities, and mirroring metadata be retained? |
| Operational behavior | What happens to migrations, history cursors, watchers, backups, and reset flows? |

Do not assume that preserving source API names preserves store compatibility,
or that a compatible local store establishes CloudKit continuity. Define backup,
failure recovery, and downgrade limits before enabling any transition.
Incompatible stores must not be silently rewritten or moved.

## 6. Decisions to resolve

All entries are open. Proposed directions above are inputs to these decisions.

| ID | Question | Evidence needed before acceptance |
|---|---|---|
| D01 | What owns an open store and how is its lifetime managed? | Concurrent-open and multiple-handle lifecycle scenarios |
| D02 | Are public nodes isolated live objects, scoped facades, snapshots, or a combination? | Small consumer examples compiled with strict concurrency |
| D03 | What defines a transaction and can its body suspend? | Atomicity, cancellation, conflict, and reentrancy scenarios |
| D04 | How are dynamic values typed and transferred? | Supported-value inventory and encoding compatibility review |
| D05 | What is the shareable unit and how are private/shared stores organized? | Owner/participant prototype and graph-boundary rules |
| D06 | What guarantees does change observation provide? | Ordering, replay, deletion, and slow-consumer scenarios |
| D07 | Which v1 compatibility guarantees are retained? | Local-store fixtures, CloudKit continuity checks, and adoption examples |
| D08 | What are the minimum OS, tools, and Swift language versions? | Required API availability and consumer impact assessment |
| D09 | How are cloud failure, fallback, and account changes represented? | State transitions and recovery scenarios |

## 7. Validation scenarios for the specification

The specification should attach observable acceptance criteria to at least:

- Two handles opening and using the same store, including incompatible requests,
  pending changes, concurrent transactions, reset, purge, and handle release.
- Two independent stores, plus an app and extension using the same App Group
  store; explicitly state the guarantees in each case.
- Swift 6 consumers reading, writing, and observing across actor boundaries.
- Cancellation around commit and observation delivery; conflicts involving
  local writers and remote imports.
- Private CloudKit synchronization across devices, separately from simulated
  history and injected identity tests.
- Sharing between different accounts, including offline edits, read-only
  participants, invitation acceptance, revocation, and account changes.
- Adoption from a populated v1 local and CloudKit store, with backup and failed
  transition recovery; reopening and downgrade behavior must be explicit.

## 8. Path from outline to specification

1. Agree on goals, supported application scenarios, and release boundaries.
2. Audit current ownership and concurrency behavior; reproduce suspected defects.
3. Compare minimal public API sketches and resolve D01–D04 through a small
   local-store prototype with multiple handles and a Swift 6 consumer.
4. Prototype sharing between accounts and use the results to resolve D05 and
   its implications for identity, persistence, and observation.
5. Resolve the remaining decisions and document compatibility constraints.
6. Write the normative specification: API contracts, state transitions, error
   model, persistence and sharing topology, acceptance criteria, and rollout.
7. Plan implementation in validated increments, keeping v1 maintenance separate.

Record accepted decisions with date, rationale, rejected alternatives, and
evidence. Keep unresolved questions visible rather than presenting illustrative
API sketches as final contracts.
