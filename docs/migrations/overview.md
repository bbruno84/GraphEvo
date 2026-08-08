# Migrations

A migration is an application-level transformation of saved data. GraphEvo
provides the lifecycle and ledger, but does not decide how to interpret the
application's data.

## When a migration is needed

Use a migration when the meaning or format of properties, entity identity, or
relationship structure changes. An incompatible Core Data model change is not
migrated automatically.

## Contract

Implement `GraphMigration`:

```swift
struct AddNoteStatus: GraphMigration {
    let id = "add-note-status"
    let version = 1

    func needsRun(
        at phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: inout GraphMigrationContext?
    ) -> Bool {
        phase == .postMigration
    }

    func handlePhase(
        _ phase: GraphMigrationManager.GraphLifecyclePhase,
        configuration: GraphStoreConfiguration?,
        graph: Graph?,
        context: GraphMigrationContext?,
        completion: @escaping (GraphMigrationResult) -> Void
    ) {
        // Transform data...
        completion(.done)
    }
}
```

Other protocol functions define backup behavior, remote-change handling, legacy
completion recognition, and state reset.

## Phases

- `.preInit`: before the graph fully opens;
- `.postInit`: after initialization;
- `.postMigration`: the migration phase;
- `.ready`: the graph is ready for normal use.

Register migrations before creating the graph:

```swift
GraphMigrationManager.registerMigration(AddNoteStatus())
```

Registration occurs once per `id`, and execution follows registration order.

## Results and state

The completion receives `GraphMigrationResult`: `.done` for completion,
`.error(Error)` for failure, `.fallback` for an alternative path, and
`.skipped` when no migration is required.

The ledger exposes `GraphMigrationRecord` and the `started`, `done`, and
`failed` states. An application error is emitted as `GraphFailure.migration`; it
does not automatically mean that the graph is unusable.

## Context

`GraphMigrationContext` passes data between phases.
`previousMigrationRecord` exposes the previous record when available.

## Safety rules

1. Back up persistent data before transforming it.
2. Make the migration repeatable or check the ledger before running it.
3. Do not delete the original store before verifying the result.
4. Record migration errors and version.
5. Test both success and restoration after failure.
