# GraphEvo 2 — migration manager renewal

Status: M1 implements a package-only Swift 6 checkpoint foundation. No public
migration executor, source conversion, runtime admission or cloud cutover is
activated. The existing v1 manager and registered application migrations retain
their behavior. See specification section 11 and PA08 in the post-alpha checklist.

## Maintainer decisions

Renew the migration manager as part of mandatory v1 data migration. Source API
compatibility is optional, but evaluate a compatibility layer using real existing
migrations before choosing its supported subset. Do not exclude it prematurely or
let it determine the new core design. Alpha-to-alpha conversion remains excluded;
mandatory v1 data conversion and beta compatibility remain required.

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

The example establishes requirements beyond adapting a callback:

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
   never retain a cross-process lifetime lock across iOS suspension.
3. **M3 — v1 compatibility experiment:** import actual ledger fixtures and port a
   representative preparation/publication slice of RecoveryV2 with an independent
   library consumer. Publish the precise supported adapter subset and porting guide.
4. **M4 — v1 local conversion:** frozen source/codec matrix, graph-scoped identity
   mappings, all node/value/topology/file cases, validated destination activation
   and fault-injected recovery. Source copies and backups remain protected.
5. **M5 — coordinated cloud cutover:** establish stopped old writers and a complete
   source, one conversion authority, duplicate prevention, late/offline old clients,
   graph/share destination policy and independent v2 replica recovery. KVS cannot
   establish this fence. Do not activate an empty cloud destination as success.

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
