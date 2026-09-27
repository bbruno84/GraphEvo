# Structural validation

`Entity`, `Relationship`, and `Action` inherit `validateStructure()` from `Node`.
The same validator runs before Graph-level Watch report delivery.

```swift
let result = entity.validateStructure()
if result.isValid {
    consume(entity)
} else {
    for issue in result.issues {
        logger.error(issue.error?.localizedDescription ?? "Unresolved reference")
    }
}
```

## Persisted state and scope

Validation reads the saved local store in a separate private context. SQLite
reads use a pinned query generation. Unsaved edits in the caller's context are
ignored; a never-saved root fails even if it already has a permanent object ID.
For an in-memory backend, validation reads committed context saves, without
claiming disk durability or SQLite query-generation isolation.

The synchronous API performs store I/O. Call it on the node's owning context
queue. It does not save, repair, merge, or mutate caller objects. Results contain
object IDs, reference states, and errors, not managed objects from the private
context. Successful validation does not refresh the caller's facade: its pending
edits or cached values can differ from the saved state that was checked.

The bounded scope is:

| Root | Dependencies checked |
|---|---|
| Entity | Its properties, tags, groups; directly associated relationships and actions, including their properties, tags, groups and endpoints/participants |
| Relationship | Its properties, tags, groups, subject and object |
| Action | Its properties, tags, groups and all subjects and objects |

Endpoint entities are fetched and their attributes materialized, but none of
their relationships are traversed, including property/tag/group collections.
The application can separately validate an endpoint if its domain requires it.
There is no recursive traversal of the mesh and no application deduplication.

Materialization means fetching a persisted row and reading its Core Data
attributes, including transformables. Optional nil values are not application
validation errors; this does not validate the semantics of decoded payloads.

## Reference results

`references` starts with the root reference, whose `sourceObjectID` and
`relationshipName` are nil. Other entries identify the source object, the Core
Data relationship name, and the destination object ID. Empty relationships have
one entry with no destination ID. Collections with members have one entry per
member. Reference order is deterministic within the same saved state.

- `absent`: the optional relationship or collection exposes no destination.
  This is informational and does not fail validation.
- `unresolved`: a referenced destination could not be fetched/materialized, or
  the validator could not access the root/store. The error preserves the cause.
- `materialized`: the destination was fetched and its attributes read.

`issues` contains unresolved entries; `isValid` is true when there are none.
The source ID and relationship name distinguish multiple paths to the same
object. Object IDs are local-store identifiers, not cross-device identifiers.

The guarantee is limited to the object and dependencies within this scope that
Core Data currently exposes. An empty relationship does not prove that another
link will not arrive later. A fault is not evidence of missing data; an error
is not evidence that the data will eventually arrive. Validation does not
certify CloudKit import completion or replace application constraints.

## Watch report integration

`GraphWatchReport.structuralValidationResults` contains one result per unique
surviving event owner. Property/tag/group events validate their owning node.
The results describe a saved-state snapshot taken during report processing,
not a reconstruction of each historical transaction or a guarantee that data
cannot change again before the callback.

Persistent History cloud batches retain the existing all-or-nothing policy:
structural failure emits `watchReportMaterializationFailed`, delivers no batch,
and leaves the delivery token unchanged for a later processing request. The
Persistent History processing token remains independent. This applies to
history-gap recovery as well. No retry timer is introduced.

A structural diagnostic has `eventKind == "structuralValidation"` and an error
of type `GraphStructuralValidationFailure`; its `result` contains all reference
details and underlying causes. The warning count includes failed owner
validations alongside any event materialization failures.

Local batches retain best-effort delivery: events belonging to failed owners
are omitted and `watchEventMaterialization` errors expose the validation
failure. A non-empty report may include both successful and failed validation
results. Direct/simulated cloud batches also withhold a structurally invalid
batch, but have no persistent delivery cursor or automatic retry.

Owners explicitly deleted in the batch are excluded: their deletion events do
not require the deleted row to remain in the store. Removed property/tag/group
events still validate a surviving owner, without requiring the removed member
to exist. Direct validation of a saved deletion fails as expected.

The validator itself only returns results. Retry and delivery policy belong to
the caller, including the Watch report coordinator. Legacy Watch callbacks are
independent and retain their existing behavior.
