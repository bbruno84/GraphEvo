# T02 — real concurrent record conflicts, 2026-10-31

Result: **thirteen ordered stages passed** on iPad/iPhone with the integrated
manual transport. Real save conflicts preserve local work; successes in the same
batch acknowledge independently; other graphs progress; retries/restarts retain
unresolved work. Record-ID deletions have different conflict semantics, recorded
explicitly below. No consumer conflict resolver or automatic convergence is added.

## Provenance

- Pinned runtime `31eac7c0c2a369933a4bebc3eb3d406cf9f3b7bb`, after reviewed
  #112 device evidence (`30f7089`) and #113 checkpoint policy (`31eac7c`).
  Production Sources, native S03 and CF01 remain unchanged by this laboratory.
- #112 exact-head macOS/iOS CI `41192210370` passed on `ee073e8`; its integration
  CI `41192922760` passed on `30f7089`. #113 policy validation `41193277258`
  skipped all expensive jobs as intended; it is not a new full test checkpoint.
- A disposable signed demo exports the pinned committed runtime and adds only
  [the external conflict bridge](../../../Experiments/RecordConflictProbe/README.md).
  No prototype engine is merged/used, no public production opener is introduced.
- Signed entitlements verified: authorized test container
  `iCloud.com.valerioburiani.GraphCKDemo`, **Development**. No reset/schema
  deletion/zone purge or old fixture conversion. All four zones use a fresh run.
- iPad (10th generation), iPadOS 27.0, owner; iPhone 18 Pro, iOS 27.2, peer and
  later independent fresh replica. Native account values compared privately and
  matched. No native stores were copied to initialize replicas.

Concurrency is deliberately controlled: both replicas observe value 1; the peer
edits and durably freezes its original server base before owner writes change
the server. Subsequent stale requests necessarily target a newer/deleted server
version. Every stage has a unique reservation, actual process/scene launch
receipt and separate passed report. All thirteen stages ran once, without a
failed-stage retry. Writers stayed alive through independent server/peer checks.

## Observed cases

| Case | Server outcome | Local / PH / receipt outcome |
|---|---|---|
| U: owner saves 2; peer sends frozen 3 plus new leaf 30 | Original update fails with real `serverRecordChanged` (14); unrelated leaf in the same non-atomic batch succeeds. Server retains 2 and leaf 30. | Peer retains 3. Exactly the failed target remains pending/frozen; leaf is acknowledged alone. No automatic overwrite or merge. |
| D: owner saves 2; peer sends deletion prepared at 1 | Record-ID deletion succeeds and server record disappears. | Peer deletion is durably acknowledged. Owner later imports it without feeding upload. |
| R: owner deletes; peer sends update prepared at 1 | Save fails with real `unknownItem` (11). Record remains absent. | Peer retains value 3, pending save and original frozen attempt. No implicit recreation or acknowledgement. |
| B: peer updates 99→100 while U/R are unresolved | Update succeeds through the same private engine. | Other graph progress is independent; U/R remain pending. |
| U: peer then edits local 3→4 and retries | Stale attempt still conflicts; server remains 2. | Original frozen bytes still contain 3, while the pending PH generation is newer and local data remains 4. Retry does not erase or acknowledge the newer edit. |
| Peer explicitly fetches U update / R deletion | Real remote events are downloaded. | Each selected import refuses with `pendingImport` and rolls back. Native local data/pending work and corresponding incoming record envelopes remain retained. |
| Owner observes final changes | U contains 2 and leaf 30; D/R are absent; B=100. | Complete local/server inventories agree, no imported changes feed upload. |
| Peer restarts again | Server remains unchanged. | Local U=4/R=3, pending generations, two frozen attempts and refused incoming work survive. |
| Fresh independent replica after collisions | Recovers U=2 + leaf 30, empty D/R, B=100. | Complete local/server inventories agree, pending upload work empty, no source-store copy. |

Initial seed/baseline and preparation are also asserted stages; the complete
ordered protocol is in the linked README. Final inventories enumerate exact local
application IDs and server-zone modifications from a nil token (100-record bound,
moreComing refused), not only a few known IDs. Typed graph reads compare values
and fixed dates. No native SQLite inspection is used to infer synchronization.

After the restart tests, a separate protected read of the peer's persisted engine
document confirmed specific bound U `recordChanged` and R `recordDeleted`
envelopes still present, no unconsumed sent receipts, and format-2 bindings with
only graph/zone identity. Raw account/session values and frozen record archives
remain outside the repository. Signed build, pinned runtime, launch receipts,
thirteen stage reports and original stores/zones remain available privately.

## Deletion semantics and remaining decisions

For these stale existing-record cases, **deletion wins on the server in both
orders**: a delete following an update removes it; an update following a delete
fails without resurrection. The local losing update is still retained. Do not
promise a save-style change-tag comparison for a deletion. Apple's deletion API
accepts [record IDs](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordidstodelete),
while [save conflicts](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged)
require application-specific handling. The experiment establishes the actual
native transport behavior; it does not select a complete library policy.

A future resolution boundary must explicitly decide how to publish local/server
choices or a consumer-provided value without dropping newer local generations.
Until that exists, unresolved work remains conservatively refused and durable;
passing this test does not imply that replicas automatically converge after a
conflict. No implicit field-level diff, metadata reset or consumer callback replay
was introduced to make the tests pass.

Still open: consumer-visible resolution/rebase and its races, multi-node
structural/dependency conflicts, duplicate/create collisions, sharing/permissions,
assets, account changes, offline/rate limiting, graph pause, actual interruption
inside publication, consistent backup restore and supported scale/resource bounds.
This small fixture does not close the complete conflict/account/crash beta gates.
