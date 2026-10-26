# GraphEvo documentation

This directory contains GraphEvo technical documentation and practical
guides. For an introduction to the project, see the [main README](../README.md).

## Recommended paths

| If you want to... | Read... |
|---|---|
| understand every public API | [API reference](api/public-api.md) |
| integrate GraphEvo for the first time | [Getting started](guides/getting-started.md) |
| understand the graph model | [Graph model](concepts/graph-model.md) |
| configure the database | [Persistence](concepts/persistence.md) |
| use CloudKit | [CloudKit](concepts/cloudkit.md) |
| run searches | [Search and predicates](guides/search-and-predicates.md) |
| observe changes | [Watchers](guides/watchers.md) |
| validate saved graph structure | [Structural validation](guides/structural-validation.md) |
| manage migrations | [Migrations](migrations/overview.md) |
| manage backups | [Backups](migrations/backups.md) |
| understand remote changes | [Persistent History](migrations/persistent-history.md) |
| consult utilities and tools | [Utilities](api/utilities.md) |

Instructions for AI agents are in [`AGENTS.md`](../AGENTS.md).

## Future design

- [GraphEvo 2 initial specification](design/graphevo-2-specification.md): current
  requirements and proposed contracts, including mandatory v1 data migration.
- [GraphEvo 2 delivery plan](design/graphevo-2-delivery-plan.md): alpha sequence,
  schema/API consolidation and beta/final release gates.
- [GraphEvo 2 decision register](design/graphevo-2-decisions.md): maintainer
  decisions, technical proposals and open choices.
- [GraphEvo 2 A1 store runtime](design/graphevo-2-store-runtime.md): implemented
  local ownership foundation, package boundary, lifecycle and verification scope.
- [GraphEvo 2 A2 async operations](design/graphevo-2-async-transactions.md):
  local serialized transactions, cancellation/commit boundary and read semantics.
- [GraphEvo 2 A3 model contracts](design/graphevo-2-application-models.md): first
  protocol/value/patch increment, schema bridge evidence and remaining public scopes.
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
