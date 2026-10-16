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
Decoder failures from `GraphValueTransformer` are captured during each validation
read and returned as unresolved references with the original error. This
includes decoding performed by the fetch itself. The transformer's public
nil-on-failure behavior outside validation is preserved; a genuine optional nil
value remains valid.

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

Local-authored history remains excluded from cloud callbacks, but its deletion
records are used to recognize superseded remote events. If a pending remote
object was subsequently deleted locally, its obsolete events are omitted before
materialization. Surviving remote events are still delivered. An interval with
only local or superseded changes advances the delivery token without invoking
the completion. Mere absence from the store is never treated as deletion proof:
an unresolved reference without a retained deletion record still fails.

The validator itself only returns results. Retry and delivery policy belong to
the caller, including the Watch report coordinator. Legacy Watch callbacks are
independent and retain their existing behavior.


## Known performance limitation

Actions with many participants can cause repeated participant enumeration when
many related entities are validated in the same report. Fetches are cached, but
per-root reference results are not shared, so work and result size can grow
quadratically. Report processing waits synchronously for validation. The Action
scope is intentionally retained; optimizing this cost is deferred, not replaced
by a weaker validation contract.


## Confirmed remote deletions

Retained remote deletions supersede older insert/update records for the same
object. The coordinator attempts to reconstruct their typed deletion events.
If a deleted detail's former owner or payload is unavailable, it is delivered
in `report.unmaterializedDeletions` with its local object ID and the original
reconstruction error. The application can invalidate cached references or
refresh its queries; GraphEvo does not invent the missing owner or value.
A report may contain only these deletion references. They count as delivered
evidence and allow the token to advance, while failures on surviving objects
continue to retain the entire batch. No Core Data model changes or additional
history-preservation attributes are required.

## Optional creation dates

An absent `createdDate` remains valid according to the existing Core Data model.
`Node.createdDateIfPresent` exposes the absence and `Node.createdDate` returns
`Date.distantPast` as a compatibility fallback. Reading does not mutate the
store, and encoding omits the absent date. These accessors read the facade's
context; the validator independently reads saved state.

## Regression coverage

The contract is exercised against disposable Core Data stores. Remote-history
fixtures use a separate context and a remote transaction author; they do not
claim to reproduce live CloudKit scheduling. Corruption fixtures close the store
before changing an archived payload, then reopen it through GraphEvo.

| Contract or failure mode | Regression suite and evidence |
|---|---|
| Saved state, pending edits, permanent IDs without rows, deleted roots, store isolation, in-memory saves | `GraphStructuralValidationTests` |
| Empty optional references; own and directly associated properties, tags and groups; all endpoint participants | `GraphStructuralValidationTests` |
| Bounded traversal in a mesh and self-loops | `GraphStructuralValidationTests` |
| Materializable endpoint with corrupt details: containing Entity, Relationship and Action pass; separate endpoint validation fails | `GraphStructuralValidationRegressionTests.testCorruptEndpointDetailsRequireSeparateApplicationValidation` |
| Corrupt Relationship and Action properties invalidate the edge and both associated entity roles | `GraphStructuralValidationRegressionTests.testCorruptRelationshipDetailsFailBothIncomingAndOutgoingEntityValidation` and `testCorruptActionDetailsFailBothSubjectAndObjectEntityValidation` |
| Missing endpoint carries its destination ID and cause; cloud delivery retries after repair | `GraphStructuralValidationTests.testDanglingEndpointIsReportedAndDoesNotTraverseItsEntity` and `testCloudValidationFailureRetainsDeliveryTokenAndRetriesAfterRepair` |
| Corrupt Entity payloads, repeated reads, optional nil, valid Data, diagnostic scope restoration | `GraphStructuralValidationRegressionTests` |
| Local best-effort delivery excludes invalid owners and includes failure results alongside valid owners | `GraphStructuralValidationRegressionTests.testLocalBatchOmitsInvalidOwnerAndStillDeliversValidOwner` |
| Invalid survivor retains the entire cloud interval, including deletion evidence, until repair | `GraphStructuralValidationRegressionTests.testInvalidSurvivorRetainsDeletionEvidenceUntilRepair` |
| Local deletion supersedes pending remote changes without discarding unrelated survivors | `GraphStructuralValidationRegressionTests` |
| Remote deletions of all node families; missing detail reconstruction; deletion-only reports; persisted cursor after coordinator recreation | `GraphWatchRemoteDeletionTests` |
| Existing report ordering, source selection, legacy callbacks, incremental history, cursor persistence and retry | `GraphWatchReportTests` |
| Optional creation date, fallback, encoding, pending edits and no read-side mutation for all facades | `NodeOptionalCreatedDateTests` |
| API available without `@testable` access | `PublicGraphWatchReportAPICompileTests` |

### Failure injection and history recovery

`GraphStructuralReadFailureTests` uses a test-only persistent store coordinator
that rejects selected destination fetches with a known error; all other reads
use the real SQLite store. It verifies unresolved Action subjects/objects and
unresolved tags/groups for every node family, including validation through an
associated Entity. Assertions check the source ID, relationship name,
destination ID, unresolved state and original error. Removing the injected
failure makes a fresh validation succeed. This represents a reference exposed
by Core Data whose destination cannot currently be read; it does not pretend
the destination row is absent.

Separate closed-store deletion fixtures demonstrate the observable absence
boundary. On the tested SDKs, deleted Action participant rows are omitted from
the exposed collections even when join rows remain. Deleted tag/group rows
likewise disappear from their inverse collections. The tests assert that the
validator reports only the remaining participants or an absent collection,
without inventing unresolved references that Core Data does not expose.
This distinction is part of the contract, not proof of import completeness.

`GraphWatchHistoryGapTests` expires a real delivery cursor by pruning history
through Core Data and first verifies that fetching with it throws an expired
history error. It then exercises the complete report coordinator for:

- Retained valid history, gap diagnostics, cursor advancement and no replay
  after coordinator recreation.
- Empty retained history, with a gap diagnostic and no invented events.
- An invalid survivor mixed with remote deletion evidence: no partial report,
  unchanged expired cursor, and delivery with the gap diagnostic after repair.

Remaining integration limits are live cross-device CloudKit scheduling and OS
versions outside the local macOS/iOS Simulator runs. Large Action participant
sets still need performance measurements; functional tests are not a throughput
or latency guarantee. Line coverage remains supplementary to these behavioral
assertions.
