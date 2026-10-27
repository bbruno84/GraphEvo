# GraphEvo — instructions for AI agents

This file is the operational entry point for agents working in the repository.
Before changing code, read `README.md` for the project overview and consult the
relevant documentation in `docs/`.

## Library purpose

GraphEvo is a Swift library based on Core Data. It exposes a graph model:

- `Graph` represents an open store and its Core Data context;
- `Node` is the common base for public objects;
- `Entity` represents a domain object;
- `Relationship` connects a subject to an object;
- `Action` represents an action with subjects and objects;
- `Search` executes queries;
- `Watch` observes local and remote changes.

The complete public API reference is in
[`docs/api/public-api.md`](docs/api/public-api.md).

## Repository map

| Path | Responsibility |
|---|---|
| `Sources/GraphEvo/Graph.swift` | Graph opening, readiness, context, and delegates |
| `Sources/GraphEvo/Node.swift` | Common properties, tags, groups, and deletion |
| `Sources/GraphEvo/Entity.swift` | Entities and relationship/action access |
| `Sources/GraphEvo/Relationship.swift` | Directed relationships |
| `Sources/GraphEvo/Action.swift` | Actions and their subjects/objects |
| `Sources/GraphEvo/Search.swift` | Typed queries |
| `Sources/GraphEvo/Predicate.swift` | Filter construction |
| `Sources/GraphEvo/Watch.swift` | Change observation |
| `Sources/GraphEvo/Persistence/` | Configuration, stores, metadata, and contexts |
| `Sources/GraphEvo/Migration/` | Migrations, ledger, backups, and logging |
| `Sources/GraphEvo/Tools/` | Merge, deduplication, and diagnostics |
| `Sources/GraphEvo/Transformer/` | Safe encoding of heterogeneous values |
| `Sources/GraphEvoRuntime/` | V2 package-internal Swift 6 store ownership and lifecycle |
| `Tests/GraphEvoTests/` | Functional and regression tests |
| `Tests/GraphEvoRuntimeTests/` | V2 ownership, aliases, lease lifecycle and current-schema integration |

On the v2 line the manifest requires Swift tools 6.0. The runtime and its tests
compile in Swift 6 mode; legacy facade/test targets temporarily remain in Swift
5 mode. There is one public product. The package-only runtime is not a raw Core
Data application API. Use a fresh `Model.makeModel()` factory through
`GraphRuntimeSchema.current`; do not concurrently hash/copy `Model.create()`'s
cached native model. A1 does not authorize simultaneous legacy/v2 ownership of
one file. Before exposing that integration, retire the old gateway or coordinate
ownership exclusion explicitly. See
[A1 runtime scope](docs/design/graphevo-2-store-runtime.md).

The final lease retains registry ownership until native detachment succeeds.
A shutdown failure must not remove that entry or permit another owner. Caller
cancellation must not cancel other opening waiters or abandon close cleanup.

## Architectural rules

1. Use the public `Entity`, `Relationship`, and `Action` facades. Do not create
   or manipulate Core Data `Managed*` classes directly; they are implementation
   details.
2. Every domain object must belong to the correct `Graph`. Do not combine
   `Search` instances built on different graphs.
3. After changing data, call `graph.sync()` when the context must be persisted.
4. Use `whenReady` when code must distinguish a ready graph from a failed open.
5. Do not add automatic migrations for incompatible stores: GraphEvo must leave
   the files and path unchanged and report `incompatibleStore`.
6. Preserve existing public behavior and update tests when changing a contract.

## Store configuration and URLs

`GraphStoreConfiguration.location` may identify a directory or a SQLite file. It
is an explicit file location when the extension is `.sqlite`.

- Directory: GraphEvo builds `GraphEvo_<name>.sqlite` inside it.
- `.sqlite` file: the complete path is authoritative and is not rewritten.
- `resolvedLocation`: the effective directory used for resolution.
- `storeURL`: the canonical URL calculated from the configuration.
- `resolvedStoreURL`: the URL actually opened, including legacy-store reuse.
- `appGroupIdentifier`: may replace a directory for directory-based
  configuration; it does not move an explicit `.sqlite` file.
- `.inMemory`: uses an in-memory store; URLs are calculated but do not point
  to a persistent file.

When changing this logic, verify at least: a new directory, an existing
explicit file, a not-yet-created explicit file, App Group, legacy store,
in-memory backend, and names with upper- or lowercase extensions.

## Essential operational APIs

### Opening and saving

```swift
var config = GraphStoreConfiguration()
config.name = "Main"
let graph = Graph(configuration: config)

graph.whenReady { result in
    switch result {
    case .success(let graph): graph.sync()
    case .failure(let error): print(error.localizedDescription)
    }
}
```

Prefer `Graph(configuration:migrationEnabled:)` for explicit configurations,
`Graph(storeURL:backend:migrationEnabled:)` when the caller owns an exact
directory or file, `whenReady` for opening results, `sync` for synchronous
saves, `async` for asynchronous saves, and `newBackgroundContext()` for
background Core Data work.

### Creating and changing data

```swift
let user = Entity("User", graph: graph)
user[dynamicMember: "email"] = "ada@example.com"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
user.is(relationship: "writes").of(note)
graph.sync()
```

Node properties are dynamic and typed as `Any?`. Use the public transformers
and coders documented in the API reference for complex values.

### Queries

```swift
let activeUsers = Search<Entity>(graph: graph)
    .where(.type("User") && .has(tags: "active"))
    .sync()
```

Successive `where` calls are currently combined with OR. For an explicit
compound expression, build a `Predicate` with `&&`, `||`, and `!` first.

### Watchers

A watcher is initially stopped. Configure its filter and delegate, then call
`resume()`. Use `pause()` to suspend it and `clear()` to remove the filter.
Callbacks distinguish `GraphSource.local` and `GraphSource.cloud`.

For Graph-level batches, assign `Graph.watchReportCompletion` and select sources
with `Graph.watchReportSources`. Batch reports do not apply Watch predicates,
are delivered on the main thread, and do not disable legacy callbacks.

`Node.validateStructure()` checks saved local state for Entity, Relationship,
and Action. Entity scope includes direct edges, their details and endpoints;
endpoint entities are not traversed recursively. Optional absent references
are informational. Report delivery uses the same validator: cloud history
batches retain their delivery token on failure, while local delivery remains
best-effort. Deleted owners are excluded. The validator does not retry or
certify import completion. Decoder errors must fail structural validation.
Retained local deletion records may supersede pending remote events; missing
rows alone are not deletion evidence. Remote deletions supersede inserts/updates;
when their typed event cannot be reconstructed, reports expose
`unmaterializedDeletions` with IDs and causes. Consumers must inspect this array
even when `events` is empty. `Node.createdDateIfPresent` exposes an absent date;
`createdDate` uses a read-only `Date.distantPast` fallback. Do not change the Core
Data model to make that field required. See `docs/guides/structural-validation.md`.


## CloudKit and Persistent History

Container identifier precedence is:

1. `configuration.cloudKitContainerIdentifier`;
2. `Graph.cloudKitContainerIdentifier`;
3. `GraphCloudKitContainerIdentifier` in Info.plist.

Without an identifier the graph remains local. If CloudKit is unavailable,
GraphEvo may emit a warning and use a local fallback.

Graph prepares Persistent History automatically after a successful CloudKit
open. The public `ph_prepareOnLaunchAfterContainerReady()` helper can be called
again after readiness; processing and batch methods remain internal.
Persistent History uses a persisted token and filters local-authored
transactions to avoid duplicate callbacks on the originating device.

## Migrations

`waitsForApplicationMigrations` is an opt-in bootstrap/readiness gate. Preserve
its default `false` behavior when modifying lifecycle code. `graph.transaction`
offers public Node APIs on a scoped private context; do not escape the facade,
perform external writes inside its body, or mistake it for a CloudKit pause.

Completion publication to KVS is best-effort after durable local completion.
Do not convert a KVS acceptance failure into a migration failure. Keep it pending
for retry, and never overwrite a newer validated remote projection already
visible/observed with superseded pending work. Durable ledger failures still
propagate; KVS provides neither distributed locking nor delivery acknowledgement.
New remote resets observe KVS before allocating their generation. Local-only
resets do not consult KVS; publication retries must never rebase their generation.

Register migrations before creating or opening a graph:

```swift
GraphMigrationManager.registerMigration(MyMigration())
```

The phases are `.preInit`, `.postInit`, `.postMigration`, and `.ready`. A
migration declares `id`, implements `handlePhase`, reports whether it needs to
run through `needsRun`, and calls its completion with `GraphMigrationResult`.

Use `MigrationBackupManager` before transforming a store. A store backup
includes `.sqlite` and, when present, `.sqlite-wal` and `.sqlite-shm` files.

## Change workflow

1. Identify the responsible module and read its related tests.
2. Check whether the change affects a public API, persistent URL, Core Data
   model, synchronization, or watcher behavior.
3. Implement the change while preserving compatibility and existing naming.
4. Add or update regression tests.
5. Update the API document and the relevant thematic guide.
6. Run `git diff --check` and the available tests.
7. Clearly summarize changed files, tests, and environmental limitations.

All comments and documentation must be written in English. This includes
Markdown files, API comments, inline code comments, test comments, and user-
facing diagnostic messages introduced or modified by an agent.

All implementations and distributions must comply with the requirements of
the applicable software licenses, including attribution, copyright, notice,
and redistribution obligations. Before adding or adapting third-party code,
review its license and preserve the required notices.

## Branching model

The repository maintains separate v1 and v2 integration lines while GraphEvo 2
is developed:

- `master`: contains only the latest stable release. Hotfix branches start from
  `master` and are merged back through a pull request.
- `develop`: v1 integration and maintenance until the 2.0 stable promotion.
  Ordinary v1 feature and bugfix branches start here and return through PRs.
- `codex/graphevo-2-design`: the specification and planning branch. Its existing
  PR remains documentation-only and targets `develop`.
- `codex/graphevo-2`: the v2 integration branch, initially created from the
  planning branch with the agreed specification. Breaking v2 implementation
  work belongs here, not in the v1 `develop` line.
- `codex/v2-<topic>`: focused v2 feature/fix branches created from
  `codex/graphevo-2`, with PRs targeting `codex/graphevo-2`. The first runtime
  increment uses `codex/v2-store-runtime`.
- `release/<version>`: ordinary v1 release branches start from `develop` at
  feature freeze. **Exception for 2.0:** create `release/2.0` from
  `codex/graphevo-2` only after all alpha areas, including observation, meet the
  beta gate. Release branches accept stabilization fixes and refinements.

Publish alpha tags from reviewed v2 integration commits and beta tags from
`release/2.0`; a branch setup or successful build is not a release request.
Keep schema/API evolution within alpha and require documented migration for
incompatible adopted beta data. See the
[v2 delivery plan](docs/design/graphevo-2-delivery-plan.md).

Existing public API examples and compatibility rules in this file describe v1.
For deliberate v2 changes, follow the
[v2 specification](docs/design/graphevo-2-specification.md) and decision register:
source API compatibility is optional, while migration of v1 data is mandatory.
V2 OS deployment floors may be raised as technically appropriate; the maintainer
has removed the v1 OS compatibility constraint. Record the rationale and update
the supported test matrix instead of treating current manifest floors as frozen.
Start with the current schema as a candidate; do not freeze a replacement schema
before exercising the new stack and its features.

The historical branch `rebase/graphMHB-base` must be retained as project
history. Do not delete, rename, rewrite, or use it as a base for ordinary
feature work unless explicitly requested.

Stable releases are promoted from the appropriate release branch into
`master` through a pull request. During parallel v1/v2 work, assess v1 fixes
individually for forward-porting to v2; the refactor may need a different
implementation. V2 release fixes return to `codex/graphevo-2` and must not bring
unfinished v2 code into the v1 `develop` branch. Promote the final stable 2.0
release to both `master` and `develop` through reviewed PRs; do not merge merely
to set up branches.

## Git and pull-request workflow

Keep every change tracked, described, and easy to reverse. Do not work directly
on shared or release branches unless explicitly requested.

1. Start on the correct branch and verify a clean tree:

   ```bash
   git status --short --branch
   git fetch --prune
   ```

2. Create a dedicated descriptive branch from the applicable integration line,
   such as `codex/docs-agents-workflow`, `codex/fix-store-resolution`, or
   `codex/v2-store-runtime`. Verify the PR targets the correct integration line.
3. Keep the change focused; do not include unrelated files or formatting.
4. Update code, tests, and documentation together when they describe one
   behavior. Commit messages should explain intent, for example:

   ```text
   docs: document GraphStoreConfiguration URL resolution
   fix: preserve explicit SQLite store URLs
   test: cover legacy store fallback
   ```

5. Before opening a PR, run:

   ```bash
   git diff --check
   git status --short --branch
   git diff --stat
   swift package dump-package
   swift test
   ```

   If a check cannot run, describe why in the PR and work summary. Do not hide
   a failed test or alter code only to bypass a non-representative limitation.
6. Publish the branch and open a PR against the intended target branch. Include
   the goal, context, behavior before/after, files or modules, tests, risks,
   limitations, follow-up work, and updated documentation.
7. Wait for review and automated checks before merging. Merge through the PR.
8. For tracked fixes, add a new commit or update the PR. Avoid rewriting shared
   branch history. Prefer a revert commit for already-merged changes.
9. Never use destructive commands such as `git reset --hard` or `git checkout --`
   without an explicit request and a verified target.

## Recommended checks

```bash
git diff --check
swift package dump-package
swift test
```

The package declares iOS 16+ and macOS 13+, but some code imports Apple
frameworks available only in the corresponding SDK. If `swift test` fails on a
macOS runner because of `UIKit` or `PDFKit`, report the limitation without
changing imports just to make a non-representative local test pass.

## Avoid these mistakes

- Do not use `Graph(name:)`; the public initializer requires a configuration or
  a `storeURL`.
- Do not assume `location` is always the final SQLite file.
- Do not use `storeURL` when you need to know which legacy file is opened; use
  `resolvedStoreURL`.
- Do not modify `Managed*` classes directly to fix public API behavior.
- Do not treat `GraphReadiness` as the result of an application migration;
  migrations report errors through `GraphEvent`.
- Do not introduce CloudKit synchronization without fallback and event handling.
- Do not commit store files, tokens, or test-generated logs.

## Documentation updates

When a public signature changes, always update
[`docs/api/public-api.md`](docs/api/public-api.md). When an operational flow
changes, update this file and the corresponding guide in `docs/`. Keep
`README.md` introductory; do not duplicate the complete API reference there.

## CloudKit node identities

Use `graph.cloudRecordID(for:)` or ordered `cloudRecordIDs(for:)` with nodes from
that facade's own context, on its queue. Scoped transaction/snapshot facades reuse
the open container. Missing mappings are optional and never cached. Validate
ownership even for local/fallback stores; misuse is a typed error. Never derive
CloudKit IDs from Graph IDs, obtain permanent IDs, save, or request export as a
side effect of lookup. Identity metadata is not pinned to a snapshot generation
and is not proof of sync completion. Keep injected mapping tests distinct from
real cross-device CloudKit verification.

## Opt-in transaction diagnostics

`transaction(diagnosticID:_:)` preserves the original transaction guard and
result. It queues `GraphEvent.transactionDiagnostic` outcome and then an
asynchronous history supplement, correlated by the caller's UUID. Never invoke
the diagnostic delegate from a transaction context/lock scope. Keep summaries
payload-free and bounded, distinguish truncated/unavailable history from no
writes, and never infer causal CloudKit bookkeeping from a generation mismatch.
History is observational, non-atomic and never a replacement concurrency guard.
The original overload must perform no trace history reads.

## GraphEvo 2 async runtime

The package-internal StoreHandle transaction boundary serializes local writers
per StoreResources owner and drains admitted reads/writes before detachment.
Adapter closures are synchronous, return Sendable values, and must never save
independently or escape contexts/nodes. Public typed scopes remain A3 work;
legacy/v2 ownership exclusion is required before adding a public opening path.
Cancellation before the final pre-save check rolls back pending edits; after a
successful save return the committed result even if cancellation was requested.
Do not replay arbitrary bodies. See
[the A2 contract](docs/design/graphevo-2-async-transactions.md).

## GraphEvo 2 model contracts

GraphEvoModel compiles detached GraphModel/GraphRecord/value/patch contracts in
Swift 6; GraphEvo exposes explicit aliases through its existing product. The
package-only GraphRecordMapper uses Node facades on the current scoped context.
It requires explicit identity mapping, propagates decoder errors and converts
all changed values before editing. Null, UUID and encoded-payload writes and
structural endpoint edits are rejected until lossless storage/resolution exists.
Do not claim that value IDs are already persisted or expose a v2 store opener
before resolving legacy ownership exclusion. See
[the A3 contract](docs/design/graphevo-2-application-models.md).

## GraphEvo 2 typed local store

GraphStore and its non-Sendable GraphReadScope/GraphMutation scopes compile in
Swift 6 in GraphEvoStore. The Graph target supplies only a scoped Node-facade
adapter. Layout a3.1 stores UUID identities and versioned property envelopes in
reserved __graphevo_v2. detail properties without changing the native model.
Do not derive IDs from Core Data URIs or silently regenerate corrupt IDs.
Legacy and runtime native coordinators acquire incompatible gateway leases;
retained legacy contexts retain ownership. Release a detached legacy lease only
after verifying the coordinator has no stores, never during a reset/reopen gap.
The new public path supports explicit null/UUID/encoded values; the plain legacy
GraphRecordMapper restrictions above still apply to that older adapter.
Current-schema local adoption requires stopped external/v1 writers and a backup
before identity edits. It does not establish a cloud cutover. See
[typed local operations](docs/design/graphevo-2-typed-store.md).

## V2 A4 graph catalog and native boundaries

`GraphDatabase` opens a4.1 multi-graph resources and returns independent
`GraphStore` leases. Preserve hidden root/membership links and their exclusion
from application snapshots. The native model is unchanged. A3-to-A4 local
upgrade is explicit and backed up; never silently upgrade a3.1 or cloud data.
`openMirrored` currently owns a private store. The private/shared resource pair
and participant assignment belong to A5. Native share callbacks hold runtime
admission and the writer gate through completion. A durable share request with
missing native metadata is pending: never create another share as a fallback.
Native opening, catalog presence, share persistence, local record mappings and
independent replica integrity are separate facts. Inspect every owned detail
row when validating boundaries. See `docs/design/graphevo-2-graph-separation.md`
and `Experiments/A4NativeProbe/README.md`. Do not replay reserved probe stages
or commit generated stores, case envelopes, device logs or local signing files.


## V2 paired stores and user sharing

The v2 alpha uses `GraphDatabase` / `GraphStore` / `GraphModel`; legacy facade
rules above remain applicable to the internal Core Data adapter. Read the
[A5 contract](docs/design/graphevo-2-user-sharing.md) before changing sharing.
One native owner reserves both canonical private/shared resources and their
identities before loading. Retain all claims on failed native detachment.
Native setup completion, local save, mappings and independent recovery are
separate evidence; none is a global synchronization certificate.

Use explicit awaited shared insertion/patch for new participant rows; never
link unassigned objects to an existing shared graph. Keep partial intent in the
originating shared store's local operation ledger, include it in backups, and
recover without replaying native share assignment. Never erase another operation
on a pre-invocation error. Reserved metadata removals are forbidden as well as
sets. Leave/purge requires the exact participant zone in the explicit shared
store. Access reduction must not depend on decoding unrelated app payloads.
Protect account identity/invitation transports and never log their values.
Real-device probes retain writer owners until independent peer observation;
closing after local save is not an export barrier. The Debug assignment-pause
seam is test infrastructure and must remain absent in Release.

## V2 native attachments

Read the [A6 contract](docs/design/graphevo-2-attachments.md) before changing
attachment persistence. The alpha uses reserved logical type
`GraphEvo.Attachment.v1` over the unchanged native model. C03a experiments with
separate `attachmentMetadata` and `content` values; retain dual reads and preserve
legacy envelopes on replacement, with no implicit conversion/downgrade claim.
Metadata-only listing does not certify content availability/integrity; full reads
and native sharing checks must still validate both values. Validate identity, same-graph exclusive
owner, byte count and digest; no owner transfer or attachment-owned attachment.
Prepare security-scoped coordinated I/O outside write scopes. Participant
imports use A5 assignment/journal recovery; replacement edits the existing
values under permission/revision checks. Do not replay partial native import.
Owner deletion must include files on implicitly deleted edges, with dependency
and permission checks before edits. Preserve rollback and surviving actions.
Use whole-directory backups from a quiescent closed source for external content;
SQLite/WAL/SHM/ledger copying alone cannot certify a complete attachment backup.
No internal external-storage paths or fake progress/streaming states are public.

## V2 bounded queries

Read the [A7 contract](docs/design/graphevo-2-queries.md) before changing query
execution. Descriptors require explicit candidate allowance; current encoded
properties use bounded native inventory plus memory evaluation, never a silent
fallback. Candidate allowance includes all local native node rows in the resource
group; only scoped application records enter evaluation. Charge consulted payload before
typed envelope decoding and reject limits without partial output. The M03
experiment retains full node identity/membership/endpoint/format-list inventory
but selects descriptor-referenced properties for non-returned types and
non-record operations. Collect nested related predicates, sort/projection and
aggregate keys; full model-type results retain all fields. Do not certify
skipped payloads or evade a budget on an explicitly requested body. This is not
a total memory/time or SQL-I/O bound. Preserve AND composition, literal strings,
missing/null distinction, exact numeric cases and UUID ordering tie-breaks.
Cursors bind graph/descriptor, are current-state values and never certify a
frozen snapshot or cloud completion. Traversal excludes hidden links and origins,
deduplicates cycles, and has explicit depth/work bounds. Pass runtime cancellation
checks through trusted scope metadata; no context or managed object escapes.
A8 must add explicit dependency invalidation; these APIs do not imply observation
or durable processing. Attachment representation costs are deferred to the agreed
end-of-alpha review; do not silently redesign file ownership during query work.

## V2 consolidation follow-ups

Keep the [post-alpha checklist](docs/design/graphevo-2-post-alpha-checklist.md)
updated when a v2 increment introduces or resolves a deferred check. Link
closure evidence and retain its actual scope. B items gate beta entry; R items
gate stable 2.0. A8 implementation and migration feasibility still belong before
beta; mandatory v1 data migration cannot be deferred beyond stable release.

## V2 observation and Combine

Read the [A8 contract](docs/design/graphevo-2-observation.md) before changing
observation. Native invalidations are bounded rescan hints, scoped to a runtime
resource group, not per-node events or proof of import completion. Subscribe
before the initial read; preserve conservative related/action/file invalidation,
visible recoverable failure states and per-handle lifecycle. Query observation
rejects continuation cursors. Native account changes remain sticky for that
runtime and terminate observed queries; do not infer full account/cache safety.
Never deliver downstream under persistence/state locks. Combine is a cold adapter
with positive demand, one pending newest value and serialized callbacks; it does
not provide durable replay or control native writers. Keep O04 open until stable
processing scope is selected. Retain physical remote evidence separately from
injected signals and keep alpha/beta gates in the post-alpha checklist updated.

## V2 consolidation cost measurements

Read the [consolidation plan](docs/design/graphevo-2-consolidation.md) and
[C01 procedure](Experiments/ConsolidationCosts/README.md) before cost-driven
schema/execution changes. The standalone Release consumer uses only public
GraphDatabase/GraphStore APIs and new external temporary local fixtures. Never
point it at application/device/cloud stores, retry failed seeds or commit its
stores/raw logs. Retain expected budget refusals and semantic assertions; do
not silently increase budgets or remove ownership/integrity checks to improve
measurements. Distinguish whole-process sampled peaks, operation latency, open
costs and synthetic desktop results from supported production envelopes. CI
runs a functional smoke only, with no timing pass threshold. Candidate metadata/
binary changes retain accepted file identity/ownership and require migration,
whole-content backup and actual native sharing validation before selection.

## C02a experimental metadata lookup

The [C02a contract](docs/design/graphevo-2-metadata-experiment.md) describes the
preferred B variant on the experiment branch. Metadata rows are Session/context
confined, fetched only for reserved keys, with lazy value access and explicit
native-store routing. Temporary/new owners and tiny persisted inventories use
the original facade lookup; include pending edits on persisted owners. Never
retain the native row index across scopes, cache decoded user values globally,
obtain permanent IDs or save as a lookup side effect. Preserve full inventory,
membership/identity/format checks, typed errors and query allowances. C02a is
not complete selective lookup, file-content separation or a shared-observer
engine. Retain A's insertion regression and B's observer-memory trade-off in
comparisons; read-only device evidence is not new native-assignment coverage.


## Cost matrix binary envelope experiment

M02 encodes top-level GraphValue.data with a distinct binary magic, version and
big-endian declared byte length. Keep legacy JSON decoding and nested/opaque
payload semantics; reject unsupported versions and truncated/extended bodies.
No alpha downgrade support or automatic rewrite is implied. See the
[matrix](docs/design/graphevo-2-experiment-matrix.md). Native synchronization,
full content checksum checks and mandatory v1 migration remain binding.
