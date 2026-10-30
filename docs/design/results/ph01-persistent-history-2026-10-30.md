# PH01 — Graph Persistent History feasibility (2026-10-30)

Outcome: **eleven tests / nineteen expanded cases pass on macOS and iOS Simulator
26.5**. Persistent History provides the needed change-discovery evidence for the
bounded real-Graph fixture, including details, deletes, cascade and durable token
replay. The test requires preservation of the existing native graph/node identity
attributes on deletion; selected S02 by itself does not provide those values.

This supports implementing a PH-based source of changes instead of intercepting
every consumer mutation to write a second change journal. It is not yet a durable
production outbox, CKSyncEngine integration or adoption of a new selected schema.
The experiment remains on `codex/v2-persistent-history-experiment`, without a PR
or merge. Integration remains at `c3e7583`, the reviewed #106 merge; its exact-head
iOS/macOS CI `41123609834` passed. No atomic intent-journal implementation exists.

## Model and provenance

The [protocol](../../../Experiments/PersistentHistoryProbe/README.md) uses the
actual twelve-entity S02 factory, native identity adapter and typed graph APIs.
The lab model changes only six attribute-preservation flags: ge2GraphID and
ge2NodeID on the three node kinds. It adds neither columns nor entities, and uses
`GraphEvo.PH01.preserved.1` rather than relabelling the selected production model.
Model hash changes are explicitly asserted, and normal native S02 openers refuse
lab files. No implicit migration or model selection is introduced.

Host toolchain: Xcode 27.1 / Swift 6.4. iOS evidence is an arm64 iPhone 17 Pro
Simulator on iOS 26.5 (23F77), not a physical device or iOS 18 result. The XCTest
result summary reports eleven test functions, with nineteen expanded executions.
Source SHA-256, full logs and result bundles are retained externally under
`/tmp/graphevo-ph01-evidence` and the PH01 result-bundle paths; no stores, tokens,
raw logs or identity-bearing transports are committed.

The small native helper reads history through public Core Data APIs, on a native
context queue under the runtime writer gate. It does not inspect private tables
or recreate the native mirror's internal sync machinery. Fixtures use fresh local
stores, with no CloudKit container, account, cloud records or device data involved.

## Observations

| Case | Observed outcome |
|---|---|
| Selected S02 negative control | A deleted Relationship lacks preserved graph/node projections. The candidate reducer refuses that deletion rather than inventing an identity. |
| Existing property value replacement | The property-row update resolves to its live owner ID even when discovery must start from the detail row. |
| Property removal, tag/group additions and removals | Native node relationship changes make the correct application owner a save candidate. |
| Relationship and Action endpoint changes | The changed graph record is discoverable; inverse-node updates may add conservative candidates. |
| Delayed property update/removal with owner alive | Collecting only after the detail row has disappeared still discovers the owner from the retained node relationship changes. |
| Delayed property update/removal followed by owner deletion | The native deletion tombstone identifies the final owner delete. Its deleted edge and surviving Action changes are also discoverable. |
| Attachment cascade | Owner deletion yields delete candidates for the Entity, its Relationship, its own attachment and the attachment owned by the deleted edge. The surviving Action is a save candidate. |
| Attachment replacement | Metadata/content updates remain attributable to the same attachment ID. |
| Direct Action deletion | Its preserved graph/node identity yields the correct delete candidate. Together with the other cases, all three node kinds are covered. |
| Saved insert→delete→recreate before collection | Reduction yields delete after the first two transactions, then save after recreation with the same logical ID. |
| Rollback | A patched value followed by transaction failure produces no new history transaction. |
| Persisted token and reopen | Retaining the old serialized token across close/reopen replays the same transactions/candidates. Advancing to the returned token leaves no further transactions. Store identity remains the same. |
| Import without echo | A distinct import author is persisted. Its changed value is seen by the query observer but produces no local upload candidate, including after reopen. A later local edit produces a save candidate. |

No native attribute or detail-body mutation was added solely to manufacture
history events. No snapshots or manual changed-ID list are written by the
consumer API in order to drive this experiment.

## Validation and actual limits

The full macOS suite passes **585 tests**: 331 legacy, 160 store, 71 runtime,
23 model. The PH01 iOS Simulator suite passes all eleven functions/nineteen cases.
Package manifest and diff checks pass. Initial preparation compilation errors
were corrected before executing the passing suites; no functional case was
removed or weakened after an observed failure.

The helper reads a complete retained history range and the current local data
while its one native owner holds the writer gate. This does not establish
production pagination/checkpoint boundaries, external-writer safety, bounded
memory or optimal candidate counts. A missing live detail owner is covered by
other native events in the tested cases; arbitrary unresolved correlations must
remain explicit in a production implementation rather than being discarded.
The reducer is deliberately a fixture-level conservative candidate extractor.

The token test demonstrates clean reopen and replay, not a process crash or
power failure. Pending work is not durably published by this prototype, and no
send acknowledgements exist. Token corruption/expiry, history pruning, store
replacement, copied checkpoints, imported/local conflicts, account changes,
CKRecord/CKAsset encoding and cross-device delivery remain separate work.

## Recommended implementation direction

1. Adopt PH as the source of committed changes; keep consumers' typed mutation
   APIs independent of sync bookkeeping. Persist distinct local/import/metadata
   authors and preserve local observation of imports.
2. Select the minimal identity-preservation model change explicitly, with its
   model identifier and migration/fresh-alpha policy. This is a concrete
   correctness reason to reopen the native target; do not silently edit S02.
3. Implement one scoped history processor per graph with stable local writer
   cuts, complete detail/node correlation and visible unresolved/error states.
4. Persist the pending IDs/operations/generations together with the consumed PH
   checkpoint; advance only after durable publication. Do not confuse discovery
   progress with upload acknowledgement or purge relevant history early.
5. Build immutable send batches from coherent current reads and retain newer
   changes when older sends complete. Register pending work with the shared
   private/shared CKSyncEngine instances owned by ContextManager.

Develop that implementation separately from this retained experiment. The
selected model, public opening paths and integration roadmap are not rewritten
by a successful lab result alone.

Apple references: [persistent history and native export](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users),
[authors and change consumption](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes),
[preserved deletion values](https://developer.apple.com/documentation/coredata/nsattributedescription/preservesvalueinhistoryondeletion),
[CKSyncEngine pending changes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class/pendingrecordzonechanges).
