# GraphEvo 2 — migration manager renewal

Status: M1 implements a package-only Swift 6 checkpoint foundation. No public
migration executor, source conversion, runtime admission, import compatibility pipeline or cloud cutover is
activated. The existing v1 manager and registered application migrations retain
their behavior. See specification section 11 and PA08 in the post-alpha checklist.

## Maintainer decisions

Renew the migration manager as part of mandatory v1 data migration. Source API
compatibility is optional, but evaluate a compatibility layer using real existing
migrations before choosing its supported subset. Do not exclude it prematurely or
let it determine the new core design. Alpha-to-alpha conversion remains excluded;
mandatory v1 data conversion and beta compatibility remain required.

RecoveryV2 is a representative production consumer, not an architectural template
or the only supported migration shape. Design the manager independently and use
that example plus unrelated synthetic consumers to validate generality.

Maintainer clarification: consumer-authored migrations must cover both native
Core Data schema changes and internal application-data changes. The library owns
execution and lifecycle. Compatibility management must cover whole migrations
and individual records/updates arriving later from incompatible versions.
A completed full-store migration cannot disable subsequent compatibility work.

The target is an awaited manager with typed failures, detached progress/state,
explicit resource admission, protected source/backup handling, checkpointed
recovery and separate validation/activation. Completion of a preparation callback
is not completion of the whole migration or proof of cloud replication.

## Concrete v1 consumer: MyHomeBills RecoveryV2

Read-only inspection of the maintainer's MyHomeBills checkout examined
`MyHomeBill/Dati/Migrations/RecoveryV2/LegacyStoresV2.swift`, `RecoveryManifest.swift`,
`RecoveryPreparation.swift`, `RecoveryPublisher.swift`, `StoreReconciliationCoordinator.swift`
and the named regression cases in `MyHomeBillTests/RecoveryV2GraphTests.swift`.
The inspected checkout HEAD was `0ecbe094c5caf44de6a86b57ff92dc4cfc646465`;
local source inspection is not a release provenance assertion.
The maintainer identifies this migration as deployed in production; this work
inspected its implementation/tests without executing production data or claiming
an independent production acceptance test. No application source is copied.

The example illustrates requirements to test beyond adapting a callback:

- `preInit` discovers/protects sources and prepares an archived reconciliation
  result; `ready` publishes through the actual Graph. A phase callback's `.done`
  must not discard pending later work.
- A scoped/versioned manifest retains operation identity, generation, aliases,
  consumed source fingerprints, report/backup references and publication state.
- Publication guards both the analyzed domain snapshot and control fingerprint
  against intervening changes, then writes data and a fingerprint marker in one
  Graph transaction. Commit-before-checkpoint recovery inspects persisted evidence.
- Local interrupted work takes precedence over an observed remote completion.
  KVS completion metadata is not proof of local data materialization.
- Domain reconciliation, category repair, deduplication, user wipe suppression,
  late-baseline reconciliation and cache refresh are application policies.
  The library must provide extension points, not adopt those policies globally.
- Reports/backups have explicit ownership and retention; cleanup follows durable
  completion. Relative-path relocation and validation matter for restored stores.

Useful existing consumer tests include `testV2LifecycleCommitsBeforeLedgerDoneAndReadiness`,
`testLateBaselineAndCommitBeforeCheckpointRecovery`,
`testPublisherNoOpAndConcurrentEditProtection` and
`testOfflinePreparationRetainsBackupsWithoutPublishing`. Their code was inspected;
these application tests were not run by M1.

## Consumer-defined migrations, library-managed execution

Use one migration service with separate execution adapters, rather than requiring
every migration to resemble a whole-store RecoveryV2 reconciliation.

| Migration class | Consumer definition | GraphEvo responsibility |
|---|---|---|
| Native Core Data schema | Source/target schema references, supported route, prerequisites, optional pre/post data transformations and semantic checks | Inspect the actual store model, resolve the registered route, coordinate resource closure/admission, select a validated native migration mechanism, protect the source, reopen and verify |
| Application data | Logical format/type versions, selection/dependencies, typed transformation and validation, repeat/recovery policy | Admit awaited work, scoped transactions, durable checkpoints, cancellation, progress, conflict/recovery handling and publication of usable state |
| Imported record compatibility | Recognized source/target formats, discriminators/defaults for declared legacy formats, affected dependencies and deterministic upgrade policy | Discover affected local rows after native import, enqueue durable compatibility work, revalidate the source revision, transform or hold as incompatible, and refresh supported readers |

Registration precedes opening and declares stable IDs, versions, dependencies,
supported source ranges and target formats. Resolve a deterministic route or
return an explicit unsupported/ambiguous route; do not guess a conversion.
The registration contract and public names are not fixed by M1. Core Data schema
references travel through a privileged backend adapter; ordinary typed Graph
migration scopes do not expose implementation Managed objects. GraphEvo-owned
native model revisions remain library-defined routes. This does not yet promise
support for arbitrary consumer-supplied native models or every mapping technique.

Schema and data work may interleave: prepare data under schema A, transition
A to B, then complete a transformation under B. Per-step source capabilities and
validation must be explicit. A plan cannot request a B-only query before B exists.
Data-only migrations must work without a native model change. Schema changes
must be validated on local and mirrored resources separately; a successful local
migration does not establish CloudKit production compatibility.

Apple provides [NSStagedMigrationManager](https://developer.apple.com/documentation/coredata/nsstagedmigrationmanager)
and [NSCustomMigrationStage](https://developer.apple.com/documentation/coredata/nscustommigrationstage)
for ordered native transitions and custom pre/post work. Evaluate these and other
supported Core Data migration routes in a protected laboratory before selecting
an adapter. Do not enable automatic migration on ordinary Graph opens or promise
that every local schema transformation can be mirrored. Apple's
[CloudKit model guidance](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit)
and [schema deployment rules](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
require additive production evolution; incompatible changes need a separately
validated transition policy.

## Data-driven model direction

Maintainer direction, 2026-10-30: use Graph's data-driven representation to keep
native Core Data schema changes uncommon. Prefer consumer-defined logical type,
property and format evolution over adding native entities/attributes for every
application feature. Consolidate native identity/routing/version needs before
beta, while retaining explicit logical record format evolution and migrations.
This is a design objective, not a promise that native schema changes disappear
or that a data-only change needs no compatibility handling. Change the native
schema when correctness or measured costs justify it, under a supported route.

## Planned native migration experiment — SM01–SM03

Status: scheduled, not implemented or executed. Run before selecting the M2/M3
native-schema adapter. Start with a minimal, separately versioned Core Data model
in a disposable laboratory; repeat the meaningful accepted transition against
the Graph candidate model before claiming Graph integration support.

| ID | Experiment | Required evidence |
|---|---|---|
| SM01 | Explicitly enabled lightweight migration between compatible models | Protected populated source; actual destination model compatibility, exact identities/values/references, close/reopen and rejected unsupported source. Distinguish physical migration from any application data transformation. |
| SM02 | Local staged migration with custom pre/post transformations | Declared source/intermediate/target models, handler order and visible model capabilities; exact transformed data; injected handler failure and process interruption at stage boundaries, including retry/reopen outcome with source preservation. |
| SM03 | Lightweight/staged transition of an already mirrored store | Establish a populated cloud/replica baseline first; migrate one controlled writer, then verify exact values/topology from an independent peer and a fresh replica. Separately measure physical-schema outcome and export/import of changes made by pre/post handlers versus ordinary post-open context saves. |

SM03 must explicitly test the observation that physical/pre-open transformations
may not be replicated like normal mirrored context saves. Do not assume either
that all pre-open changes export or that none can export. Record retained history,
model/store versions, operation identity, native setup/import/export outcomes and
independent data recovery separately. Event success alone is insufficient.
Include a delayed incoming supported-format edit during publication and verify
stale-analysis rejection/reconciliation; do not claim that the manager's writer
gate pauses native imports. Distinguish a conflict from an unsupported route.

Use synthetic external stores and a separately authorized Development fixture,
never production/user stores. No implicit cloud reset, original-store rewrite,
blind stage replay or simultaneous independent ownership of one local file.
Bind each result to toolchain/OS/model hashes and preserve failed outcomes.
Publish a result with accepted routes and limitations before implementing the
native adapter; native and cloud success remain separate acceptance criteria.

## Version domains and cloud lifecycle

Keep native model/layout version, application data-format version and migration
operation identity distinct. The application build number or one global done
flag is insufficient. Per-record format discrimination is required where mixed
formats may coexist. Its storage location/envelope and legacy defaults remain
schema decisions to validate; do not freeze a new native field just for M1.
An old record without version metadata is accepted only through a declared legacy
format rule, never by guessing from whichever decoder happens to succeed.

Whole-store migration and ongoing import compatibility have distinct state:

- Whole migrations register local progress, semantic completion and activation.
  A remote completion projection is informational; each local replica must still
  establish schema compatibility and usable data. Fresh/partial replicas cannot
  skip initialization or treat absence as a complete empty source.
- After an import, changed records and dependency closures are checked against
  supported logical formats. A later old-format update to an already upgraded
  record must be evaluated again. Deduplication binds graph/node, source format,
  validated source revision/fingerprint and transformation version, not node ID
  alone. Do not assume a public CloudKit record version is available or atomic.
- Changes and destination-format metadata/commit evidence must be persisted in
  the same admitted transaction. Recheck consulted source revisions/dependencies
  before writing; if import or user edits changed them, discard the stale plan and
  re-evaluate current data. Completion markers are not a global transaction.
- Define conversion to converge without producing endless old/new rewrite loops.
  Delayed delivery, duplicate history, interrupted conversion, same-record edits,
  partially imported endpoints and deletes must not duplicate or resurrect data.
  Account/store identity changes invalidate inappropriate pending work.

Native CloudKit imports are owned by NSPersistentCloudKitContainer. Apple's
[TN3163](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer)
explains that imports apply remote data to the local store. [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
directs applications to consume persistent history after remote-change signals;
scheduling is controlled by the system. Build a local compatibility-admission
pipeline around this, not an assumed pre-import interceptor or sync pause.

Persistent history/native signals discover work; the journal and an internal
processing contract retain retry/recovery responsibility. Bind cursors to the
correct resource/account and atomically enqueue durable work before advancing
discovery, or retain the cursor on failure. History loss requires a bounded,
resumable rescan. A coalesced observation invalidation or container event alone
is not a durable work queue or an import-completion certificate. This manager
requires its own processing contract; it does not silently close A8/O04.

Do not publish incompatible payloads as normal typed query/observation results.
Define an explicit pending/incompatible/update-required state with the narrowest
safe scope: record/dependency closure, graph, or resource when routing is unknown.
Do not omit records and return a smaller successful result. Native import itself
may already have changed the SQLite store; this is a library read/write admission
boundary, not a claim to hide bytes from native import or repair an unmodifiable
store. Queries, observation, snapshots and local writers must share the policy.
The exact snapshot/isolation mechanism is an M2/M6 experiment, not delivered M1.

Supported older data may be converted by a registered consumer transformation.
Unknown future formats are retained and reported without lossy downgrade. An
unsupported native model or failed native import is a schema/sync error; a logical
record converter cannot make an undecodable/unimported native row available.
Shared read-only participants and widgets cannot persist upgrades. Hold the
required state until an authorized owner/upgraded writer establishes compatible
data; no bypass of A5 permissions or second synchronizer is permitted.

KVS completion, local completion, local export, native import and independent
replica validation remain different evidence. For the agreed v1-to-v2 cutover,
v1 writers still stop before conversion. The general post-migration pipeline
also covers later stale/incompatible deliveries, but does not magically prevent
old unsupported clients from writing or establish source completeness.

## General acceptance matrix

Validate the service with independent consumer-authored definitions as well as
RecoveryV2. Required cases include:

- Data-only format conversion without a model change; native schema-only and
  interleaved schema/data transitions; unsupported and ambiguous paths.
- Full migration followed by a delayed old-format insert and an old-format update
  to the same converted record; duplicate delivery and restart after effect commit.
- Newer unknown format and unknown legacy format; missing/partial dependencies;
  semantic conflict, deletion and conflict during conversion; no silent omission.
- Two replicas at different supported versions, fresh-replica recovery, failed
  export, delayed imports, repeated conversion and bounded convergence.
- History expiration, pending-work crash, account switch, widget-before-app and
  shared read-only participant; no unauthorized mutation or cursor-based loss.
- Existing v1 consumer phase/ledger compatibility, plus a minimal unrelated app
  with custom data transformations. No app-specific repair policy in the manager.

## Compatibility evaluation

| Existing contract | Proposed treatment | Still to demonstrate |
|---|---|---|
| Migration ID/version and local completion records | Explicit import with source scope/version provenance; preserve completed versus pending/interrupted states | Reader for the actual v1 ledger and collision/reset cases |
| Callback-based phase work independent of Graph | Candidate adapter to awaited phase work | Exactly-once completion, cancellation, missing/duplicate callbacks and lifetime |
| `needsRun` and context metadata | Explicit evaluation context/state; preserve local-interruption priority | Existing decision matrix and unsupported context values |
| `Graph`-dependent publication and remote-change handlers | Port to typed v2 scopes or run a separately admitted legacy stage before cutover | No simultaneous legacy/v2 ownership; real publication port |
| Application manifests and semantic reconciliation | Remain application-owned artifacts/policies with recovery hooks | Artifact persistence/relocation and semantic validator |
| KVS, resets, support UI/progress | Separate optional projections and application integration | Local durability despite failed publication; newer-state precedence |

Do not claim that wrapping `handlePhase` makes `LegacyStoresV2` source compatible:
its ready phase requires the legacy Graph and its publisher relies on domain
semantics. Keep importing historical completion separate from rerunning a body.

## M1: package-only journal

`GraphMigrationJournal.shared` in GraphEvoStore serializes journal calls in one
process. Its methods are actor-isolated and awaited; plans, intents and snapshots
are detached Codable/Sendable values. There is no public alias or opening hook.
This is foundational bookkeeping, not the complete migration manager.

A plan binds scope, migration ID/version, source fingerprint, destination identity
and ordered unique step IDs. Callers must eventually derive those identities from
validated resources; M1 treats them as opaque values and cannot establish source
completeness or recognize arbitrary file aliases. Reopening requires an exact
plan match, retains the operation UUID, and rejects corrupt/unsupported state.
Initial creation never overwrites an existing operation.

Before invoking an effect, `begin` persists a unique intent with operation UUID,
step ID, attempt token and expected result fingerprint. Another begin is refused
while that intent is outstanding. The future trusted adapter must write the exact
intent marker **in the same destination transaction as the corresponding effect**.
Only after reading that marker from the committed destination may it call
`confirmCommitted`. Confirmation is idempotent for an already completed intent.
An old attempt cannot complete a later attempt with the same step/fingerprint.

After an interruption, the outstanding intent remains unresolved. Missing marker
alone does not prove absence of effect. The adapter must independently establish
that no effect occurred before `confirmNotApplied` permits a new attempt.
Unknown outcomes stay pending; no arbitrary migration body is automatically
replayed. M1 records the adapter's classification; it does not inspect a database
or certify that the classification is true.

Completed steps do not imply semantic validity. An explicit validation transition
requires all steps; activation is recorded separately after external validation
and activation. Their verification and interruption/reopen protocol belong to
later increments. The bookkeeping transitions themselves are not evidence of
validation or activation. Cancellation prevents new admission but does not
prevent recording an already committed effect or its externally established
activation outcome.

All reads validate the persisted state. Updates publish through Foundation atomic
file replacement and propagate encoding/filesystem failures. No in-memory success
is cached before persistence. This is process-interruption bookkeeping, not an
fsync/power-loss guarantee or a two-file transaction. Journals are protected local
artifacts, not payload logs. No KVS projection, global lock, retention cleanup,
backup or source/destination mutation is performed. All callers must currently
use the singleton in one controlled process; ordinary app/widget/native writers
are not excluded by this component. It must not be wired to production conversion
until explicit admission is implemented.

## Increment sequence and acceptance

1. **M1 — journal foundation:** ordered plans, durable intents, exact recovery
   identity and separate validation/activation states. Test interruption modeling,
   replay refusal, stale evidence, concurrent admission, corruption and cancellation.
2. **M2 — manager/admission and artifact lifecycle:** connect explicit resource
   ownership, backup protection, awaited phase execution, bounded progress and
   recovery hooks. Define widget-before-app and close/cancellation behavior;
   never retain a cross-process lifetime lock across iOS suspension. Complete
   SM01–SM03 before selecting the native migration adapter; do not infer export
   behavior from a successful local schema transition.
3. **M3 — v1 compatibility experiment:** import actual ledger fixtures and evaluate
   representative existing migrations, including a RecoveryV2 slice. Validate
   separate minimal consumer-authored data and native-schema plans so no one
   application's lifecycle defines the service. Publish the supported adapter
   subset and porting guide.
4. **M4 — v1 local conversion:** frozen source/codec matrix, graph-scoped identity
   mappings, all node/value/topology/file cases, validated destination activation
   and fault-injected recovery. Source copies and backups remain protected.
5. **M5 — coordinated cloud cutover:** establish stopped old writers and a complete
   source, one conversion authority, duplicate prevention, late/offline old clients,
   graph/share destination policy and independent v2 replica recovery. KVS cannot
   establish this fence. Do not activate an empty cloud destination as success.
6. **M6 — ongoing cloud format compatibility:** durable import processing,
   per-record format policy, dependency/admission gating, authorized upgrades,
   stale/future format handling and cross-replica convergence. Design this with
   M2/M4/M5, not after freezing their APIs. Separate full-operation completion
   from later incompatible inserts/updates; validate the general matrix above.

Representative local/cloud feasibility still gates beta. Full tooling, real-store
conversion and interruption/recovery acceptance gate stable 2.0. Neither this
manager work nor the widget baseline freezes the schema or promotes a release.

## M1 verification

The complete macOS package run passed 527 tests (322 legacy, 118 store including
the first seven journal cases, 64 runtime and 23 model). Two additional journal
regressions were then added for inconsistent persisted states and invalid/skipped
plans; the final focused suite passed all nine cases. Manifest validation and
`git diff --check` pass. No native source/destination migration, cloud operation
or MyHomeBills hosted test was executed. CI must validate the published head
on both macOS and iOS before merge.
