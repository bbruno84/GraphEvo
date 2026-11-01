# GraphEvo 2 — migration manager renewal

Current implementation direction: the
[migration foundations roadmap](graphevo-2-migration-foundations.md) records the
maintainer's custom-sync decisions after T08: protected local admission, central
backups, a separate shared control ledger and working-graph/PH publication.
Consumers own application compatibility and cross-device coordination. Native
mirroring/import-version assumptions below retain historical scope and must not
be implemented as current requirements. M1/M2a evidence remains unchanged.

Status: M1 implements the package-only Swift 6 checkpoint foundation; M2a adds
isolated local execution. No public migration executor, production source
conversion, runtime admission, import compatibility pipeline or cloud cutover is
activated. The existing v1 manager and registered application migrations retain
their behavior. See specification section 11 and PA08 in the post-alpha checklist.

The subsequent [M2a local vertical slice](graphevo-2-data-migration-local.md)
adds declared data versions, prepared pure consumer transformations, atomic
data/version/marker publication and checkpoint reconciliation on isolated local
stores. It does not activate public version-aware opening or cloud processing.

Maintainer decision M16 removes native/public application versioning and the
proposed common format registry. [Consumer data](graphevo-2-data-formats.md) and
[S02](graphevo-2-identity-schema.md) define the replacement boundary. M2a remains
a historical isolated laboratory, not the intended public version contract.
Production backup, resource readiness and migration activation remain open.

## Maintainer decisions

Renew the migration manager as part of mandatory v1 data migration. Source API
compatibility is optional, but evaluate a compatibility layer using real existing
migrations before choosing its supported subset. Do not exclude it prematurely or
let it determine the new core design. Alpha-to-alpha conversion remains excluded;
mandatory v1 data conversion and beta compatibility remain required.

RecoveryV2 is a representative production consumer, not an architectural template
or the only supported migration shape. Design the manager independently and use
that example plus unrelated synthetic consumers to validate generality.

Maintainer decision M14 supersedes the earlier broader proposal: consumers define
application-data migrations; GraphEvo owns native Core Data schema changes
internally. External native interventions are not automatically supported by the
consumer manager. The library owns execution and lifecycle. Compatibility management must cover whole migrations
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

Consumers register logical application-data transformations, with stable IDs,
revision and explicit dependency/selection/validation rules. Any source/target
application versions are ordinary consumer data, not centrally registered formats.
GraphEvo manages admission, scoped transactions, durable effect/checkpoint
reconciliation, cancellation and publication of usable state. Ongoing imported
record processing is a separate pipeline under consumer-defined policy; whole
migration completion cannot disable later incompatible inserts/updates.

Native Core Data model references, mappings and staged routes are library-internal
implementation concerns, not consumer migration definitions. Ordinary Graph scopes
never expose Managed objects. The manager cannot promise that an arbitrary external
model change is supported, pause native imports or infer export from local save.
Internal schema transitions may bracket application-data work, but the consumer
contract describes logical capabilities rather than native model registration.

Resolve deterministic supported data routes or report unsupported/ambiguous input;
do not guess a source format from successful decoding. Data-only evolution works
without a native model change. Keep native model/layout, GraphValue codec, consumer
record format and migration operation versions distinct.

## Data-driven model direction

Maintainer direction, 2026-10-30: use Graph's data-driven representation to keep
native Core Data schema changes uncommon. Prefer consumer-defined logical type,
property and format evolution over adding native entities/attributes for every
application feature. Consolidate native identity/routing needs before
beta, while retaining explicit logical record format evolution and migrations.
This is a design objective, not a promise that native schema changes disappear
or that a data-only change needs no compatibility handling. Change the native
schema when correctness or measured costs justify it, under a supported route.

## Internal native schema evidence — SM01–SM03

The [completed experiment](results/schema-migration-2026-10-30.md) covers additive
lightweight/staged local transitions and final staged-handler replication on
iPad/XR, including fresh recovery before ordinary post-open saves. This is bounded
fixture evidence; historical stores/codecs, real process interruption, concurrent
imports and Production rollout remain separate gates. It does not implement
complete logical v1 conversion or certify arbitrary native routes.

[S01 device acceptance](results/s01-native-sharing-recovery-2026-10-30.md) verifies
its original sharing/files/fresh-recovery fixture. M16 now selects identity-only
[S02](graphevo-2-identity-schema.md); its device acceptance remains open. Native
schema evolution stays internal. Do not
replay reserved stages, reset cloud data implicitly or treat events as a global
synchronization certificate.

## Version domains and cloud lifecycle

Keep native model/layout version, optional consumer data versions and migration
operation revision distinct. Graph does not require per-record version metadata.
The consumer defines selection and validation, optionally using ordinary version
properties. There is no central registry or global application compatibility
block. Library ownership and scoped transactions protect migration execution;
they do not interpret application meaning or suspend native cloud imports.

Whole-store migration and ongoing import compatibility have distinct state:

- Whole migrations register local progress, semantic completion and activation.
  A remote completion projection is informational; each local replica must still
  establish schema compatibility and usable data. Fresh/partial replicas cannot
  skip initialization or treat absence as a complete empty source.
- After an import, changed records and dependency closures are checked against
  consumer-defined selection and validation rules. A later old-format update to an already upgraded
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

Typed materialization invokes consumer decoding and propagates failures without
silently dropping records. Generic reads and non-materializing queries remain
available; the library does not infer application compatibility from version
numbers. Consumers define handling of unknown/older data and semantic readiness.
The manager may execute their explicit selections and transformations, respecting
permissions, stale-source validation and durable recovery. Native model/codec or
structural failures remain library errors. A read-only participant or widget
cannot persist repairs; it must not bypass A5 permission checks.

KVS completion, local completion, local export, native import and independent
replica validation remain different evidence. For the agreed v1-to-v2 cutover,
v1 writers still stop before conversion. The general post-migration pipeline
also covers later stale/incompatible deliveries, but does not magically prevent
old unsupported clients from writing or establish source completeness.

## General acceptance matrix

Validate the service with independent consumer-authored definitions as well as
RecoveryV2. Required cases include:

- Consumer data-only format conversion without a model change, unsupported and
  ambiguous formats; separately test library-internal native transitions and their
  ordering with data work, without consumer native-schema registration.
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
   library-internal native migration evidence; do not infer export behavior from
   a successful local schema transition. Consumer plans never register native routes.
3. **M3 — v1 compatibility experiment:** import actual ledger fixtures and evaluate
   representative existing migrations, including a RecoveryV2 slice. Validate
   separate minimal consumer-authored data plans and internal schema fixtures so
   no one application's lifecycle defines the service. Publish the supported adapter
   subset and porting guide.
4. **M4 — v1 local conversion:** frozen source/codec matrix, graph-scoped identity
   mappings, all node/value/topology/file cases, validated destination activation
   and fault-injected recovery. Source copies and backups remain protected.
5. **M5 — coordinated cloud cutover:** establish stopped old writers and a complete
   source, one conversion authority, duplicate prevention, late/offline old clients,
   graph/share destination policy and independent v2 replica recovery. KVS cannot
   establish this fence. Do not activate an empty cloud destination as success.
6. **M6 — ongoing cloud data processing:** durable import discovery,
   consumer selection/validation, permission-aware transformations,
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
