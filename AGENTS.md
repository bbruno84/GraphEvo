# GraphEvo — instructions for AI agents

## Current v2 development entry point

Read [development status](docs/design/graphevo-2-development-status.md) before
choosing v2 work or a base branch. Consolidation is integrated into
`codex/graphevo-2` through #78/#81. Historical cost/metadata/matrix branches are
not active integration lines. New focused v2 branches start from and return
directly to `codex/graphevo-2`. Complete review/checks/integration before the
next increment; do not rebuild the former experiment-parent stack. Preserve
historical reports/branches and their actual scope. Update the status page on
integration changes and the post-alpha checklist on gate changes.

## Selected v2 synchronization transition

M17 selects explicit CloudKit sync. Read the
[transition contract](docs/design/graphevo-2-custom-sync-transition.md) before
sync/runtime/sharing changes. The ContextManager owns private/shared engines,
at most one per configured CloudKit database in the synchronization process.
One GraphCoordinator will own one graph and local store; it does not own an
independent engine targeting the same database. The old native mirroring code
is transitional under `Persistence/LegacyMirroring` and runtime `LegacyMirroring`.
Do not extend it with replacement sync features or silently reinterpret existing
mirrored files as custom-sync stores. Preserve local typed behavior and v1 data
migration support. The retained CS01 branch is evidence, not code to merge.
The isolation cleanup alone does not implement the new owners/transport. Read
the [local coordinator contract](docs/design/graphevo-2-graph-coordinator.md)
before modifying the package-only owner path. Preserve exclusiveGraphID during
resource canonicalization; generic leases must not coalesce with exclusive owners.
Manager tokens cover pending requests and live handles. Last release retains
registration on detach failure, including initialization/partial-load quarantine.
Public opening remains later work; package-only foreground orchestration follows
[T06](docs/design/graphevo-2-automatic-sync.md), and manual transport follows [T01](docs/design/graphevo-2-record-transport.md).

## Selected v2 native schema

Read [S03](docs/design/graphevo-2-history-schema.md) before native model work.
M18 retains S02's twelve entities, optional ge2GraphID/ge2NodeID and compound
indexes; it enables deletion-history preservation on these six node attributes.
Explicit `.nativeIdentity` and coordinated openings use `GraphEvo.v2.schema.3`.
No-schema/current/v1 defaults stay unchanged. S02/S01/lab files are refused before
loading, never relabelled/migrated/erased; fresh alpha stores follow M13. Preserve
historical factories and their actual flags/models. Application meaning and
optional versions remain consumer-owned under M16; no format registry or native
data-version column returns. PH01 remains an unmerged experiment. S03 adoption
does not implement a history processor/outbox or establish cloud acceptance.
Record concrete evidence and migration/local/cloud effects before another native
revision. Native schema migration and mandatory v1 conversion remain library work.

The [S01 device protocol](Experiments/S01NativeProbe/README.md) extends the public
file fixture with guarded empty replicas and same-process seed/invitation. Keep
writers alive through independent peer observation; never replay a consumed
mutation or copy native stores into a supposedly fresh replica. Its
[16-stage result](docs/design/results/s01-native-sharing-recovery-2026-10-30.md)
closes only the bounded historical S01 sharing/recovery item. S03 device
acceptance, migration execution, v1 conversion and broader native/account/
conflict gates remain open. Application-format admission is withdrawn by M16.

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
7. Follow this order: **review, CI, merge**. Complete implementation and relevant
   local verification, open the PR without `ci-checkpoint`, then review and resolve
   findings. Only after review is complete, immediately before an authorized merge,
   request the required remote CI checkpoint on the reviewed head. Do not start
   expensive alpha CI before review or while review fixes are still being prepared.
   V2 alpha PRs use the explicit [CI checkpoint policy](docs/design/graphevo-2-ci-checkpoints.md):
   full remote CI is not required on every alpha PR. A skipped job is not a tested
   checkpoint. Run full remote CI at agreed delivery checkpoints and before
   alpha/beta tags. A source change after review requires focused re-review before
   another required checkpoint; remove the label before intermediate pushes.
   Merge through the PR only after the required checks pass and merge is authorized.
   Stable/v1/release automatic checks remain required.
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

SQLite reads pin their query generation. In-memory read scopes instead join the
local writer gate for coherent multi-fetch views; a reader behind an active
memory writer waits for its commit. Preserve queued-reader cancellation/draining
and independent-resource progress. Privileged in-memory native callbacks must
not reenter a read on the same resource while retaining that gate.

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

Read [consumer data](docs/design/graphevo-2-data-formats.md) before model work.
GraphRecord has no application version field; GraphModel has no format policy
or registration requirement. Versions may be ordinary consumer properties.
Typed mapping validates kind/type/identity and propagates consumer decoder
failures. Generic access and count/projection/aggregate do not classify app
compatibility. Preserve structural, codec, permission, ownership and budget
checks. Migration lifecycle, source protection and cloud processing remain open;
removing format admission does not enable the package-only migration manager.

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
costs and synthetic desktop results from supported production envelopes. Experimental
harnesses, including functional smoke modes, run locally and are excluded from CI.
CI validates library behavior and consumer integration. Candidate metadata/
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

M03b also filters requested native property rows before reading their values,
using Session-confined explicit-store batches with pending changes. Complete
model-type records still use complete snapshots. Keep native transformer-error
capture active across property fetch/value access and evaluation; a requested
legacy decoder failure must not silently become an absent value. The unique
native-transformer probe must distinguish skipped-body reads from requested
failures. No row index may survive its query/scope.

For database Sessions, route native owners by graphID before fetching any
per-graph ID/format/staging metadata. Do not rely on deferred native transformer
execution: older Core Data can transform fetched values eagerly. Preserve the
full native candidate count while excluding foreign per-graph payload rows.


## C02b local native identity laboratory

The [C02b contract](docs/design/graphevo-2-native-identity-experiment.md) defines a
package-only model/opener experiment. Never select it from default public opens,
automatically migrate an incompatible file or activate a partial backfill. It
uses normal runtime ownership/scopes but validates point targets/references;
full graph integrity is explicit and separately timed. Missing columns/old
writers/cloud imports remain integration gates, not proof of node absence.
Protect the closed source directory and migrate only an owned disposable copy
to a new destination. Native UUIDs come from archived logical IDs, never local
URIs or CloudKit mappings. No uniqueness constraint or cloud acceptance is
inferred from configured local indexes. Retain action fan-out costs and failures.


C02b endpoint checks batch up to 128 UUIDs across all node kinds and only selected
identity/staging property rows. Topology prefetch must not fetch property sets or
endpoint payload bodies. Changed owners use facade reads for their pending local
view; retain staged, missing, duplicate and raw-mismatched endpoint regressions.
The internal executable adds a package scheme: use `GraphEvo-Package` for Xcode
package tests. Keep its `@main` source out of a file named `main.swift` for Xcode
16 compatibility.


## C04a shared observation laboratory

The [C04a contract](docs/design/graphevo-2-shared-observation-experiment.md) keeps
public observe/publisher behavior unchanged. Group only exact validated query
shapes/budgets and concrete model types within one explicit laboratory/handle.
Share immutable query records, not application model construction. Late joins
require a new read; no replay cache or cross-handle lease is permitted. Keep broad
relationship/action/file/native invalidation. The last cancellation must retire
worker and native source atomically against new joins; finish/delivery and value
destruction occur outside locks. Account changes supersede in-flight reads.
Injected sources/checkpoints are deterministic local tests, not CloudKit proof.
Keep baseline/sample counts, startup overhead and mixed-query outcomes even if
they regress. Default schemas, observer APIs and query budgets are not changed.


## C04 public observation consolidation

The first adoption branch routes public observe/publisher through one lazy
GraphStore-owned coordinator; the [adoption contract](docs/design/graphevo-2-observation.md#c04-consolidation-adoption)
settles shared view identity and join/refresh semantics. Keep idle graph/source
references weak to avoid a handle cycle. Exact query/model/limit/budgets share
native detached records; model decoding and delivery remain subscriber-owned.
The package-only independent A8 path is retained solely as a cost control, and
shared measurements must exercise public observe. Do not claim public startup,
heavy-decoder or physical native acceptance from C04a local timing alone. Schema,
migration and integration-line promotion remain separate reviewed work.


## Identity-guarded query materialization

Leading finite ID guards may skip same-model property rows/bodies, while complete
bounded native identity/membership/endpoint/format inventory remains. Preserve
Boolean order: do not use a later ID to hide an earlier property error. Related
predicates and traversal disable this optimization. Keep complete fields for all
potentially eligible model records and unchanged candidate/step/structural charges.
Empty-key owners must be excluded before native property fetching; retain the
same-model native transformer poison probe. See the [query contract](docs/design/graphevo-2-queries.md#c02-consolidation-identity-guarded-materialization).
No schema/native identity activation, SQL predicate capability, total-memory bound
or certification of skipped bodies is implied.


## Native identity integration readiness

Read the [integration contract](docs/design/graphevo-2-native-identity-integration.md).
The package-only native lookup now audits complete same-view identity metadata
before returning nil. Missing/misrouted projections are errors; valid staged
rows block the audit with pendingNativeOperation. Do not decode unrelated bodies,
repair identities or cache an audit across scopes. Found targets remain targeted;
full integrity is explicit and separate. Retain the extra negative-lookup cost.
All-writer projection maintenance, protected-source conversion/recovery and native
private/shared adoption remain gates; default schemas/openers are unchanged.


## Common native identity writers

GraphNativeIdentityColumns is an optional-model helper: default models have no
columns and retain existing behavior. New application/control rows use common
stamping before membership/assignment. Persisted projections are validated,
never silently filled; explicit conversion owns backfill. Reject partial/mixed
column definitions before shared intent reservation. Common mutation admission
and shared finalization preserve native projection checks and pending intent.
The package-only `openLab(fullAdapter: true)` tests ordinary local APIs without
the old prototype's mutation workaround. It is not a public schema opener or
physical native-column sharing proof. See the [writer contract](docs/design/graphevo-2-native-identity-integration.md#common-writer-projection-maintenance).


## Fresh alpha stores (M13)

Incompatible alpha layouts start from empty stores. Do not build alpha-to-alpha
conversion, downgrade or interrupted alpha-conversion recovery as an adoption
gate. This supersedes earlier alpha-conversion follow-ups above. Next native
layout work targets fresh local and controlled mirrored store initialization.
Do not automatically erase incompatible existing files or cloud data. Mandatory
v1-to-v2 migration and beta data compatibility remain distinct requirements.
See the delivery plan and native identity integration contract.


## Explicit fresh native local schema

GraphDatabaseSchema.nativeIdentity selects the public fresh local alpha layout;
no-schema/current opens keep the previous model; explicit mirrored selection
uses the public native overloads described below.
Use the shared GraphNativeIdentityAccess resolver, with distinct public/prototype
activation markers. Public graph activation requires new empty controls; never
call historical backfill/copy helpers from ordinary native opens. Snapshots check
consulted native projections; allowUnprojectedRows is only for explicit historical
backfill. Queries retain full bounded inventory and existing property policies.
validateIntegrity(of:) is explicit full storage/payload validation, not app-domain
validation or a CloudKit certificate. Fresh paired/native physical acceptance and
v1 migration remain separate. See the fresh local native schema contract.


## Fresh native paired laboratory

GraphNativeIdentityPairedLaboratory is internal physical-test infrastructure.
Its compatibility wrapper now delegates to public schema overloads. Mirrored
admission permits exactly one private resource or a private/shared pair matching
runtime URLs. Local/prototype adapters remain local-only; no-schema mirrored
opens retain the current model. Use the
[one-use host](Experiments/NativeIdentityPairedProbe/README.md) with new controlled
fixtures and protected run-bound transports. Offline container tests have no
cloud options and prove no assignment/import. Do not replay mutations, reset
clouds implicitly, backfill imported projections or treat a reset confirmation
as proof that another old writer cannot run later. Controlled native paired and
attachment acceptance is recorded below; public mirrored adoption is separate.


The [controlled device result](docs/design/results/native-identity-paired-devices-2026-10-29.md)
now records native A5 sharing/recovery/lifecycle and separate A6 file acceptance
on iPad/XR; it supersedes the initial connectivity block for that bounded scope.
Retain the first Cocoa merge-conflict recovery failure and later successful
explicit recovery of its original ledger without reassignment. The host's
recover-after-conflict ticket is explicit journal recovery, not permission to
replay patchShared or arbitrary transaction bodies. Public mirrored adoption,
broader crash/conflict/account/scale coverage and v1 migration remain separate.


## Public native mirrored schema

Both openMirrored overload shapes accept explicit GraphDatabaseSchema selection.
The native factory requires standard model version identifier
GraphEvo.v2.schema.2 in every existing resource before native loading;
matching entity hashes alone must not activate unversioned prototype data.
New local/mirrored native files get the identifier from their fresh model factory.
Do not manually stamp old files, use another native coordinator, convert or erase
as an opening side effect. No-schema/current opens retain their prior model.
The root alpha.1 logical protocol is retained. S02 contains graph/node identity
only. Consumer versions are ordinary data, never interpreted by Graph. Reject
mixed/malformed identity shapes; retain codec/structure validation.
validateIntegrity(of:) supports both legitimate mirrored topologies but remains
a current-local full payload check. Use the public consumer host to distinguish
published API evidence from historical @testable laboratory coverage.

Public mirrored host launches use a fresh `--launch-ticket` receipt bound to
CoreDevice PID and scene activation. Launch success or a termination signal is
not proof that new CLI arguments reached the app. A receipt is not a native
stage/export certificate; never replay reserved writes to recover missing host
acknowledgements. Invitation trace instrumentation belongs only in the external
copy made by `Experiments/PublicMirroredProbe/prepare_invite_triage.py`, never
the shipping library. The maintainer authorized continuing after the launcher
fix while waiting for the historical anomalies to recur; retain them as open
incidents without claiming established causes.


## V2 containing app and extension access

Read `docs/design/graphevo-2-app-extension-access.md`. The containing app owns
CloudKit synchronization. The v2 runtime rejects mirrored configuration from
an extension bundle before native model/loading and gateway claims. `openReadOnly` uses
ordinary native read-only containers for existing single/paired files; missing
resources, mutations and extension mirroring have public typed errors. Never
create a store in a widget as a fallback, start a second cloud synchronizer,
relax same-process ownership, or retain a lifetime file lock across suspension.
The role check is not a universal process lock or third-party-writer detector.
Local extension writes and iOS App Group/suspension/account policy remain gates;
macOS independent-process observation evidence is not physical-widget coverage.
Keep the library independent of WidgetKit and refresh queries after resume.


## Actual WidgetKit laboratory

`Experiments/WidgetAccessProbe` prepares a disposable configured demo with a real
embedded WidgetKit extension and App Group, using only public Graph APIs.
Keep account-specific project/signing changes and original demo edits out of
tracked source. The app owns the native mirrored pair; the widget opens existing
resources read-only and closes every lease per invocation. Its manifest has IDs
and mode, never the counter value used as query evidence. Preview data is not a
provider read. Retain exact run/value, PID, public refusal and separate liveness/
render evidence; never replay reserved writes to refresh a widget. Keep reports
under App Group Library/Application Support so native device transport can read
them. Simulator tests require ad-hoc signing for real group mapping. The actual
hardware baseline is scoped in `docs/design/results/widget-app-group-2026-10-29.md`;
iOS 18 real-widget, lifecycle/account/protected-data and interactive writes remain
open. Do not infer cloud export/recovery from a local widget or publish personal
Home Screen images or generated stores/logs.


## Native schema migration laboratory

`Experiments/SchemaMigrationProbe` and internal GraphSchemaMigrationLaboratory
exercise explicit owned synthetic v1/native/versioned models. Never select this
loader from public opens, stamp alpha activation or mistake physical schema
migration for full v1 identity/catalog/value conversion. Generic Core Data writes
inside native staged handlers are confined to this framework experiment; normal
operations use Node facades. Native schema migration is internal library work;
consumer migrations target application data. Keep the optional node version
experimental and distinguish it from existing property-row appDataVersion.
Use distinct transport/report filenames, one-use assignment intents and exact
launch process/ticket binding. Missing mappings never authorize reassignment.
Retain initial harness failures, source copies and independent replica evidence.
A thrown pre-handler may already have saved; do not blindly replay it. Read
`docs/design/results/schema-migration-2026-10-30.md` for accepted scope and open
historical-store, concurrency, interruption and Production gates.


## V2 migration journal foundation

Read [the manager contract](docs/design/graphevo-2-migration-manager.md) before
migration-manager work. M1 is package-only bookkeeping, with no public executor
or runtime/import admission. Consumers define application-data migrations; native
schema routes are internal GraphEvo work. Never treat a journal marker, KVS flag
or missing destination marker as a distributed fence or proof of no effect.
Preserve source/backup ownership, pending intents and separate validation/activation.

## M2a local data migration laboratory

Read [M2a](docs/design/graphevo-2-data-migration-local.md) before changing the
package-only manager or adapter. Keep the laboratory model identifier separate
from public S02. It retains historical version metadata only inside the fixture.
Consumer transformations are pure detached-value callbacks. Publish values,
native version and effect marker atomically under the runtime writer boundary;
recheck the full selected preimage and verify actual target state on recovery.
Missing markers alone do not prove no effect. Never replay the consumer closure
for a retained prepared artifact or mistake journal completion for public-store
activation. Cloud/native imports, ordinary app/widget admission and production
backup/retention are outside this laboratory's accepted scope.


## V2 Persistent History pending publication

Read [the PH processing contract](docs/design/graphevo-2-history-processing.md)
before sync/checkpoint work. S03 remains unchanged. New coordinated stores reserve
`GraphEvo.v2.historySyncGraphID`; unmarked alpha stores are not silently adopted.
Refuse marked resources before any old mirrored single/pair native load, including
shared secondaries. Generic readers must not create a second graph there.

Pending operations and secure-token Data share one runtime-owned save on the
hidden root. Stable local/import/metadata authors separate upload discovery from
observed imports; exclude metadata at history fetch to avoid feedback loops.
Never reset corrupt/expired state, advance past unresolved details, prune history,
or clear a newer generation using an older receipt. Complete or abandon every
prepared batch, including empty batches. Count limits are not total resource bounds.
The package patch seam is not full incoming/conflict/inbox support. Retain actual
process-kill, engine ordering, history retention and physical-cloud gates.


## V2 CKSyncEngine foundation

Read [the engine contract](docs/design/graphevo-2-sync-engine-foundation.md) before
session/routing/inbox work. ContextManager owns one private/shared engine pair,
not one engine per graph. Reserve the container before asynchronous account checks;
keep ownership and the directory lock on failed cleanup. The environment label
namespaces disk state, while signing entitlements select the actual cloud environment.

Preserve incoming events before engine-state advancement in the same local
session document. Never confuse that inbox with a graph's PH pending checkpoint,
consume events before an import/effect protocol exists, or silently reset corrupt
state. Delegate failure blocks later checkpoints and schedules cancellation outside
the callback. Stop drains admitted work; late callbacks cannot recreate state.
Native scheduling remains manual/package-only. T01 adds outgoing changes and
receipted GraphRecord application; the #109 foundation alone does not. CKAsset values (including encrypted/array fields) are refused without
advancing the cursor until durable asset staging exists. Keep physical-engine,
actual crash/power-loss, rewrite-cost, account, asset and end-to-end gates open.


## V2 CF01 cloud record format

Read [CF01](docs/design/graphevo-2-cloud-record-format.md) before wire/transport
work. M19 selects one GraphEvoNode CKRecord per logical primitive, one bound zone
per graph, with opaque typed-value properties. Never export native detail rows,
controls, PH generations or local checkpoints. Native S03 remains unchanged.

Canonical node UUID record names are the new explicit custom-backend protocol,
not legacy CloudKit mapping results or v1 conversion. Require exact graph/node,
kind, scoped route and system-field identity; never regenerate corrupt metadata.
Retain lossless value-envelope compatibility if GraphValueCodec changes. Refuse
attachment saves until CKAsset staging exists. Prepared artifacts are not send
admission or receipts; failed encoding releases only its own attempt and retains
pending work. Decode does not apply events, resolve endpoints or consume inbox
entries. Persist server metadata/effects and implement recovery before upload
acknowledgement or inbox consumption. Keep schema deployment, real server tags,
private cross-device sync, conflicts, assets and migration gates open.


## V2 T01 manual record transport

Read [T01](docs/design/graphevo-2-record-transport.md) before native send/import or
receipt changes. Persist graph/zone identity only, never sandbox/store URLs.
Runtime registration keeps the canonical URL; StoreKey may be case-folded and is
not a path. App bootstrap must register graphs at current URLs after restart.
Do not auto-open a resource from restored cloud state. Preserve portable moves.

Frozen attempts, server metadata and effect/receipt markers use one native save
with the related PH changes. Native send-result envelopes must be retained before
engine state advances. Recover those receipts and pending incoming effects before
new sends; resolve same-record conflicts under T03 and refuse unsupported structural
conflicts atomically. Never infer version
equality from missing change tags. Consume session envelopes only after durable
effects. Receipt cleanup may remain pending after a successful effect; prune only
markers absent from the validated same-session retained work. A marker is bound
to event ID/content, account/zone, native store UUID and PH epoch.

The engine document is format 3 and native transport state format 2; refuse older
alpha state unchanged. Native S03 does not change; wire format 2 reads format 1. Import uses Node facades, dependency ordering and final validation;
missing endpoints/conflicts retain the inbox. Zone deletion blocks transport and
preserves local data, before unrelated app-body decoding. Never recreate it as a
retry fallback. Raw PH-only acknowledgement/patch import is prohibited once a graph
has transport state. Keep real server tags/CAS/device delivery, power-loss, backup
consistency, resource envelopes, assets, automatic scheduling and account/cache
policy gates open. Injected bus tests are not physical CloudKit acceptance.


## V2 T03 automatic conflicts

Read [T03](docs/design/graphevo-2-conflict-policies.md) before conflict/receipt or
edit-date work. Default lastEditWins compares current consumer edit dates, ties
cloud; cloudWins chooses remote. Policy is local root metadata shared by handles.
Stamp actual consumer primitive changes once per transaction before save, including
surviving action edits. No dates from PH/createdDate, no stamping imports/retries.
Keep GraphRecord application properties unchanged and S03 unchanged.

Retain validated server archives in durable conflict receipts. Settle all results
from a send together before retiring its attempt; acknowledge only matching
generations. A local winner keeps current data/date and rebases server fields.
At most one targeted retry per manual call; distinguish resolved from published.
Delete-wins and persistent deleted-ID traces prevent resurrection/ID reuse, even
for same-cut old saves. Refuse unsupported pending structural effects atomically.
Retain explicit trace/receipt bounds and cost gates; no automatic trace pruning,
cloud reset, path persistence or consumer-body replay. T01/T02 physical reports
remain pinned historical evidence, not assertions about the new policy runtime.


## V2 T04 CKAsset transport

Read [T04](docs/design/graphevo-2-cloud-assets.md) before changing assets or async
file delivery. Attachments use wire3 with one CKAsset and complete metadata; normal
records retain wire2. S03 and local legacy/split attachment representation remain
unchanged. Automatic complete transfer is selected, without metadata-first or
on-demand network promises. Publish content/metadata atomically and import files
after owners, including edge/action owners.

Portable durable archives retain bounded bytes, never SDK/file URLs. Materialize
native send files only outside native scopes and retain them until send completion.
Reject restored CKAssets; never follow a persisted staging path. The 10MiB/file
and existing encoded transport/session/receipt bounds still apply. Extra durable
byte copies are a measured-cost follow-up, not a streaming/SQL-placement guarantee.
Keep independent wait cancellation/deadlines, shared refresh and exclusive caller-
owned export destinations. No network awaits or file-system I/O inside native
transactions. Preserve real-device evidence separately from injected transport.


## V2 T05 graph synchronization pause

Read [T05](docs/design/graphevo-2-sync-pause.md) before changing sync admission.
The owning ContextManager tracks active/pauseRequested/paused per graph in memory.
Reject new sync cycles after request; drain the already-admitted cycle through
receipts, native effects and cleanup, including its bounded retry. A failed
operation retains work and still settles its admission. Never pause by cancelling
the common database engine. Local writes/PH remain available in the existing queue.

Filter new native fetches by currently admitted zones and count existing scoped
fetches before suspension. Global control notifications can be retained without
applying paused graph data. T04 refresh work owns admission independently of UI
cancellation; shared fetch coverage must include the requested graph or perform
a targeted fetch under its existing permit. Do not allow an unrelated operation
to borrow an old permit. Resume during draining is busy; state observation is
newest-only, not durable replay. Full close/reopen resets process-local state;
stop does not resume it. No automatic scheduling, distributed/migration exclusion,
new persisted format or schema change is part of this increment.


## V2 T06 foreground synchronization

Read [T06](docs/design/graphevo-2-automatic-sync.md) before changing scheduling.
Explicit package-only activation, aggregate scene activity and a 60s foreground
reconciliation drive the existing manual engine path. Keep SDK automatic sync
disabled and retain one worker per scope, fair graph turns, T05 admission, durable
PH/inbox/receipt ownership and generation checks. Filter consumer commit hints
before coalescing; imports/bookkeeping must not feed uploads. No permanent graph
lease or idle timer/feed retain cycle. New hints cannot bypass retryAfter/backoff,
permanent graph failures or sticky session failures. Foreground polling is not
background/APNs acceptance. Experiments/devices remain local; review precedes CI.


## V2 T07 explicit zone sharing

Read [T07](docs/design/graphevo-2-zone-sharing.md) before custom sharing changes.
Owners remain in private zones; participants bind the owner's zone in shared.
Use private account-targeted capabilities without persisted local paths. Keep
CKShare control records out of primitive decoding and prioritize them before
bounded application inbox selection. Complete read-only preflight before reserving
creation; persist intent in an awaited operation-scoped callback immediately
before the native create/save. Never clear ambiguous-save intent on a generic
network error. Inspect already accepted invitations on recovery, and protect
an empty participant replica before acceptance. Consumer permissions must cover
all handles, reopenings and attachments; imports bypass consumer write checks.
Sharing uses T05 admission and the session scope gate/drain. S03 is unchanged;
new session format 4 refuses old alpha state without modifying it. Historical
A5 native sharing is not the replacement backend's acceptance evidence.


## V2 T08 sharing lifecycle

Read [T08](docs/design/graphevo-2-sharing-lifecycle.md) before lifecycle changes.
Confirmed shared-access loss and explicit leave purge the participant's exclusive
store and pending work; owner-private data remains. Inspect current membership
before destructive interpretation of control events/errors. Joining absence,
network/quota/authentication and read-only downgrade are not revocation evidence.
Persist removal first, block app access, drain/invalidate every lease, and retain
runtime claims through native destruction and exact owned-artifact cleanup.
Retry cleanup only for unchanged post-destruction artifacts; never adopt a file
that appeared after cleanup or belongs to a replacement store. Recover a missing
join marker only for the same native UUID and an untouched, unaccepted joining
generation. Keep data access fenced until explicit acceptance finishes.
Restart registration supplies current URLs; check native UUID/purpose without app
payload decoding. No persisted sandbox paths or silent old-alpha conversion.
Old generations never regain access; rejoin is explicit, empty and resets only
the shared engine through supported nil serialization. The control worker runs
while foreground/paused but never fetches paused app bodies. Keep Debug purge
barriers out of Release. Record exact physical pins separately from CI/review.
An application inbox limit keeps data transport blocked but must not disable
membership inspection, purge or foreground lifecycle control. Reserve bounded
journal space for participant removal; account and other fatal failures remain
sticky and must never be bypassed by control work.

## V2 MF01 local maintenance

Read [MF01](docs/design/graphevo-2-local-maintenance.md) before changing local
admission or backups. Owned write reservations cover the native owner and all
aliases, drain admitted/queued writers, allow ordinary reads and never release
another request. Maintenance additionally drains/refuses reads. Retained leases
span cancellation/close and late releases remain generation-bound. No cross-process
writer fence or new writable widget route is implied.

Create backups through native Core Data copying and full-content verification,
never an inferred external-storage path or a raw live SQLite/WAL copy. Preserve
consumer reasons, relative manifests, ownership markers and graph-owned recovery
artifacts. Validate native stores on disposable copies; retain their files/claims
on detachment failure. Per-graph cloud recovery evidence excludes other graphs
and opaque engine state and is never blindly restored. Restore only into empty
local destinations until protected activation/reconciliation is implemented.

Finite root locks protect file operations; durable retention owners protect
required backups without a migration-lifetime file lock. Unknown/corrupt ownership
is not deletion authority. Cleanup must preserve another caller's manual cloud
pause and local reservation. Keep the v1 backup helper unchanged unless a separately
validated v1 route is explicitly implemented. MF01 and T08 integrate together in
#120 after corrective review and one combined CI checkpoint. Future increments
start from `codex/graphevo-2` and retain review/corrections before CI and authorized
merge. MF02's compressed packages extend this baseline in #121.

## V2 MF02 backup packages

Read [MF02](docs/design/graphevo-2-backup-packages.md) before package changes.
The selected extension is `.geb`. Keep manifest-first discovery independent of
payload extraction and preserve bounded byte/file/depth checks, strict DEFLATE
end/input accounting and exclusive regular-file extraction. SDK zlib is linked;
no vendored implementation/dependency is introduced. No compression/file I/O runs
on the main actor. Cancellation forwards to owned I/O workers and awaits cleanup.
Release snapshot-owned local/cloud holds after native copying, preserving manual
pauses and other reservations. Verify before atomic package publication.
Keep legacy directory reads/export, durable retention and native attachment/PH
verification. Package import does not activate a graph or restore account/share/
engine state. Independent cross-user graph adoption remains executor work.
Measurements and cross-platform probes stay local; review precedes CI and merge.
MF02 integrates through #121 after corrective review and one combined macOS/iOS
checkpoint. Future increments start from `codex/graphevo-2`; retain package import
versus independent graph activation as separate contracts and acceptance evidence.


## V2 MF03 shared graph ledger

Read [MF03](docs/design/graphevo-2-shared-ledger.md) before control-metadata work.
The package-only ledger is outside Core Data/application nodes: full current and
previous operations, 32 compact events and bounded consumer-owned JSON. Retries
coalesce; history is diagnostic, not migration eligibility or a distributed lock.
Session format 6 rejects older alpha documents without alteration. S03 and graph
record/asset formats remain unchanged. Only registered cloud bindings are enabled.
Control records bypass the application inbox/PH but retain account, permission,
generation and stop fences. Reuse ContextManager's scope gate/engine ownership;
continue control reconciliation during graph-data pause. Persist the exact
in-flight projection before sending, acknowledge only that revision and retain
newer local work. Foreign revisions require explicit resolution; never replay
consumer bodies or use wall clocks to choose a winner. Revocation discards that
generation's pending control work. Backup evidence is graph-scoped and restoration
must not rewind the shared ledger/session. An owned unfinished operation recovered
after restart requires an explicit consumer recovery decision. Review precedes CI
and authorized merge; disposable laboratories and physical runs remain local.

MF03 integrates through #122 after corrective review and full CI #303 on
`a2f029a`; subsequent integration/evidence updates are documentation-only. Keep
original physical evidence (`9c6ee82`) distinct from corrective scheduler and
generation-fence tests (`7dd8ecf`). Migration execution remains separate work.


## V2 MF04a logical emptying

Read [MF04a](docs/design/graphevo-2-logical-emptying.md) before graph emptying.
GraphStore/GraphMutation.removeAll performs one scoped preflight and one normal
transaction, preserving GraphID/catalog/membership and sync/transport metadata.
Detach hidden membership and application-action inverses before deleting entities;
the legacy facade otherwise deletes connected Actions. Preserve cancellation,
permissions, identity/deletion evidence and per-graph isolation. Limits bound
selected logical records, not complete native inventory or attachment memory.
Use the existing PH/CKSyncEngine delete path; never destroy the zone/share, reset
PH or discard a frozen batch as a shortcut. A late old-save success must leave a
newer delete pending. Local success is not global cloud emptiness/convergence.
The workspace executor remains separate design work. Review precedes CI and merge.

MF04a integrates through #123 after review and full macOS/iOS CI #311 on
`5ca2644`; review added two adversarial tests without changing shipping source
`a19ae62`. The MF04 workspace/publication contract remains design-only; do not
claim that GraphStore.removeAll by itself creates an isolated migration copy.


## V2 MF04b isolated working copies

Read [MF04](docs/design/graphevo-2-migration-workspace.md) before workspace work.
Preparation uses owned source cloud/local holds, a complete native copy and exact
workspace-purpose admission. No sync session is attached to the editable copy;
ordinary runtime openings must refuse it. Participant workspaces remain disabled.
Preserve application identities/content and deleted-ID evidence, clear only the
copy's transport/checkpoint authority and capture a fresh PH token after one
working setup transaction. Never guess native sortable fields or use dates as a
history cut. No backup is created before final validation. Close/discard drain
working access; removal checks physical directory/file identity and bounded
ownership markers after detachment. Failed cleanup retains files/native claims.
Sealing, PH reduction, restart/source-freshness recovery and publication are still
separate work; descriptors are not an activation or migration-completion claim.
Review/corrections precede CI and authorized merge; physical labs stay local.


MF04b integrates through #124 after review and one full macOS/iOS CI checkpoint
#317 on `181b80c`. Shipping source remains `168eb0a`; review adds two negative
admission checks. Integration notes are documentation-only. Future work starts
from `codex/graphevo-2`; keep seal/reduction, restart/source freshness, participant
activation and publication gates open until separately implemented and validated.
