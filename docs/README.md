# GraphEvo documentation

This directory contains GraphEvo technical documentation and practical
guides. For an introduction to the project, see the [main README](../README.md).

## Recommended paths

| If you want to... | Read... |
|---|---|
| understand current GraphEvo 2 progress and the active development branch | [V2 development status](design/graphevo-2-development-status.md) |
| understand every public API | [API reference](api/public-api.md) |
| integrate GraphEvo for the first time | [Getting started](guides/getting-started.md) |
| understand the graph model | [Graph model](concepts/graph-model.md) |
| configure the database | [Persistence](concepts/persistence.md) |
| use CloudKit | [CloudKit](concepts/cloudkit.md) |
| run searches | [Search and predicates](guides/search-and-predicates.md) |
| observe changes | [Watchers](guides/watchers.md) |
| validate saved graph structure | [Structural validation](guides/structural-validation.md) |
| manage migrations | [Migrations](migrations/overview.md) |
| inspect v1 native schema migration experiments | [SM01–SM03 result](design/results/schema-migration-2026-10-30.md) |
| manage backups | [Backups](migrations/backups.md) |
| understand remote changes | [Persistent History](migrations/persistent-history.md) |
| consult utilities and tools | [Utilities](api/utilities.md) |

Instructions for AI agents are in [`AGENTS.md`](../AGENTS.md).

## Future design

- [Consumer-owned data](design/graphevo-2-data-formats.md): application meaning,
  optional version properties and typed decoding without a central format registry.

- [MC01 store-copy experiment](design/results/mc01-store-copy-history-2026-10-30.md):
  Closed working-store edits, retained native history and independent cloud recovery,
  with whole-resource ownership and activation limits.

- [Migration manager renewal](design/graphevo-2-migration-manager.md): M1 journal,
  consumer-defined application-data plans and remaining M2–M6 admission/conversion work.
- [M2a local data migration](design/graphevo-2-data-migration-local.md): isolated
  data/version publication, prepared artifacts and interruption reconciliation.

- [GraphEvo 2 selected persistent schema](design/graphevo-2-persistent-schema.md):
  Historical S01 shape and four-area evidence; superseded by S02.
- [S02 identity-only schema](design/graphevo-2-identity-schema.md):
  Current graph/node identity model, consumer-owned data and validation gates.
- [S01 public device acceptance](design/results/s01-native-sharing-recovery-2026-10-30.md):
  iPad/XR sharing, attachment lifecycle, two empty replicas and persisted-model evidence.
- [GraphEvo 2 initial specification](design/graphevo-2-specification.md): current
  requirements and proposed contracts, including mandatory v1 data migration.
- [GraphEvo 2 delivery plan](design/graphevo-2-delivery-plan.md): alpha sequence,
  schema/API consolidation and beta/final release gates.
- [GraphEvo 2 post-alpha checklist](design/graphevo-2-post-alpha-checklist.md):
  end-of-alpha decisions and beta/stable validation follow-ups across all increments.
- [GraphEvo 2 decision register](design/graphevo-2-decisions.md): maintainer
  decisions, technical proposals and open choices.
- [GraphEvo 2 A1 store runtime](design/graphevo-2-store-runtime.md): implemented
  local ownership foundation, package boundary, lifecycle and verification scope.
- [GraphEvo 2 A2 async operations](design/graphevo-2-async-transactions.md):
  local serialized transactions, cancellation/commit boundary and read semantics.
- [GraphEvo 2 A3 model contracts](design/graphevo-2-application-models.md): first
  protocol/value/patch increment, schema bridge evidence and remaining public scopes.
- [GraphEvo 2 typed local store](design/graphevo-2-typed-store.md): persisted
  identities, scoped public CRUD, gateway ownership and backed-up local adoption.
- [GraphEvo 2 A4 graph separation](design/graphevo-2-graph-separation.md): catalog,
  hidden membership, personal native zones and explicit local alpha upgrade.
- [GraphEvo 2 A5 user sharing](design/graphevo-2-user-sharing.md): paired resource
  ownership, private invitations, participant edits, permissions and durable recovery.
- [GraphEvo 2 A6 native attachments](design/graphevo-2-attachments.md): owned file
  lifecycle, bounded I/O, shared assignment, integrity and whole-content backups.
- [GraphEvo 2 A7 bounded queries](design/graphevo-2-queries.md): typed predicates,
  current-state pagination, bounded relations/traversal, projections and aggregates.
- [GraphEvo 2 A8 observation](design/graphevo-2-observation.md): bounded async
  current state, live rescan hints and demand-aware Combine adapters.
- [GraphEvo 2 consolidation](design/graphevo-2-consolidation.md): integrated
  cost baseline and proposed selective-access, file and observation improvements.
- [GraphEvo 2 metadata experiment](design/graphevo-2-metadata-experiment.md):
  C02a baseline/A/B comparisons and scope-confined metadata batching candidate.
- [GraphEvo 2 attachment metadata experiment](design/graphevo-2-attachment-metadata-experiment.md):
  C03a split metadata, legacy fallback and local cost/correctness evaluation.
- [GraphEvo 2 native identity experiment](design/graphevo-2-native-identity-experiment.md):
  C02b isolated native model, explicit copy conversion and selective point lookup.
- [GraphEvo 2 experiment matrix](design/graphevo-2-experiment-matrix.md):
  binary/query variants, regression and owner/participant native lifecycle, with
  [measured outcomes](design/results/cost-matrix-2026-10-27.md).
- [GraphEvo 2 design outline](design/graphevo-2-outline.md): discussion draft
  retaining the original goals and architectural questions. The specification
  supersedes it for current decisions; neither describes the v1 public API.
- [GraphEvo 2 verification roadmap](design/graphevo-2-verification-roadmap.md):
  experiments to validate framework behavior in GraphEvoDemo before and during
  implementation.
- [GraphEvo 2 execution checklist](design/graphevo-2-test-checklist.md): retained
  evidence, remaining tests and their scope.
- [GraphEvoDemo initial assessment](design/graphevo-demo-initial-assessment.md):
  source state, existing coverage, build evidence, and laboratory preparation.

- [C02b native identity results](design/results/c02b-native-identities-2026-10-27.md):
  selective reads/patches, retained endpoint regressions, bounded topology and
  metadata batching, explicit integrity costs and remaining migration/cloud gates.

- [C04a shared observation experiment](design/graphevo-2-shared-observation-experiment.md):
  exact-descriptor grouping, per-consumer decoding/cancellation, unchanged broad
  invalidation and a startup/update CPU/memory matrix.

- [C04a shared observation results](design/results/c04a-shared-observation-2026-10-27.md):
  repeated startup/update wall/CPU/RSS comparisons, execution attempts versus
  delivered views, retained preflight correction and remaining adoption gates.

- [C04 public observation adoption checks](design/results/c04-public-observation-2026-10-29.md):
  per-handle public async/Combine wiring, lifecycle checks and retained targeted
  Release comparison; physical adoption and startup/query costs remain open.

- [Identity-guarded query materialization result](design/results/identity-guarded-queries-2026-10-29.md):
  same-schema public query body selection, native transformer checks and matched
  baseline/candidate Release rows; complete structural inventory remains.

- [Native identity integration contract](design/graphevo-2-native-identity-integration.md):
  same-view absence safety, metadata versus full integrity, all-writer invariants
  and protected-source conversion/native adoption gates.

- [Native identity readiness result](design/results/native-identity-readiness-2026-10-29.md):
  fail-closed negative reads, resource routing, native body exclusion and separate
  metadata/full-integrity costs; public/native schema adoption remains open.

- [Common native identity writer acceptance](design/results/native-identity-writers-2026-10-29.md):
  common local writes/files/rollback/reopen on the optional-column model, guarded
  partial imports and remaining native/conversion gates.

- [Fresh native local store acceptance](design/results/native-fresh-local-stores-2026-10-29.md):
  explicit public native schema, create-only activation, compatible reopen and
  storage integrity; native paired/mirrored acceptance remains separate.

- [Fresh native identity paired acceptance laboratory](../Experiments/NativeIdentityPairedProbe/README.md) — internal host, offline checks and pending physical matrix.

- [Native identity paired device acceptance](design/results/native-identity-paired-devices-2026-10-29.md) — controlled iPad/XR sharing, explicit conflict recovery and native attachment lifecycle.

- [Public native mirrored schema adoption](design/results/native-public-mirrored-schema-2026-10-29.md) — explicit schema overloads, pre-load version guard and separate public consumer evidence.

- [Public adoption causal triage](design/results/native-public-causal-triage-2026-10-29.md):
  reproduced launch acknowledgement defect, traced invitations and unresolved historical causes.

- [Containing app and extension access](design/graphevo-2-app-extension-access.md):
  app-owned synchronization, extension refusal and local read-only opening; iOS gate remains open.

- [Extension access safeguard result](design/results/extension-readonly-access-2026-10-29.md):
  520 tests, selected sanitizer and independent-process public reader evidence.

- [Actual WidgetKit / App Group result](design/results/widget-app-group-2026-10-29.md):
  signed app-owned cloud synchronization with read-only widgets; physical iPad/iPhone evidence.
