# MF04a logical graph emptying — 2026-11-01

## Source and scope

Candidate source: `a19ae6287cc91f2df81584b2ed18d2664a692e7a`, on
`codex/v2-migration-workspace`, directly from integrated MF03/#122 (`5b22750`).
PR #123 now delivers the [MF04a emptying API](../graphevo-2-logical-emptying.md)
and retains the [MF04 workspace design](../graphevo-2-migration-workspace.md)
as unimplemented future scope. No workspace, migration publication or backup
activation is claimed. S03, node/asset wire formats and session format 6 are
unchanged. Subsequent evidence/status edits are documentation-only.

## Deterministic and local validation

macOS 27.0.1, Xcode 27.2 / Apple Swift 6.4.2:

- Full `swift test`: **826 functions** passed (331 legacy, 396 store, 76 runtime,
  23 model).
- iOS 18.5 Simulator store/runtime/model targets: **494 functions / 580
  parameterized invocations** passed, zero failures/skips/runtime warnings.
- Release `GraphEvo`, Swift 6 ModelConsumer, package manifest and diff checks pass.

Thirteen new functions cover:

- all primitive kinds, tags/groups/typed values and a 2-MiB attachment;
- PH output consisting of exactly the removed IDs/deletes, no-op repeated emptying,
  preserved conflict policy and graph reopen/fresh-ID repopulation;
- enclosing-transaction rollback, real caller cancellation before save and
  emptying/repopulation in one transaction; deleted-ID reuse refusal on the
  history-sync backend;
- atomic explicit record-limit refusals and malformed attachment preflight;
- current/native multi-graph resource isolation, hidden catalog retention and
  standalone typed local graph support;
- observed query refresh, native read-only stores, local write reservations and
  read-only participant admission;
- 137 records flowing through normal 100+37 send batches, independent replica
  deletion import without reupload, unchanged binding/local ledger state;
- partial delete failure retained across reopen and successful later delivery;
- an older frozen save success after emptying retaining the newer pending delete,
  without recreating its record.

In-development tests exposed the historical Entity deletion cascade deleting the
hidden membership Action. The final implementation detaches retained membership
and application-action inverses before entity deletion. An initial cancellation
seam cancelled a Core Data background task rather than the admitted caller; the
final gate cancels the actual caller after edits and before the save check.
Initial test compilation issues were corrected before final validation. None is
reported as a passing run. Expected baseline corruption/read-only diagnostics
remain distinguishable from failed assertions.

The record limit bounds selected logical records, not full native inventory,
payload memory/SQL I/O, elapsed time or total remote pending work. Existing PH and
deleted-ID limits remain in force; no silent budget increase or timing threshold
was introduced.

## Physical protocol

Owner: iPad di Bruno, private database. Participant: iPhone XR / iPhone di Maria
Elena, a different iCloud account, read-only shared database. Existing Development
container: `iCloud.com.valerioburiani.GraphCKDemo`. New fixture/zone run:
`4377BC2B-3239-4F9D-882C-3D6CDA5E80D6`. No container reset, schema reset or consumed
mutation replay. The signed disposable demo pinned source `a19ae62`; the injected
probe/bridge and all raw artifacts remained outside the checkout.
Probe SHA-256:
`f18374e140b7d5bfe0893985b57023f261de68392bb21949f92182a9f6b07bf8`.
The first host build needed a missing Core Data import correction before any
physical stage began. The shipping source pin did not change.

| Stage | Device | Confirmed scope |
|---|---|---|
| identity | XR | Protected recipient identity prepared; no graph created. |
| seed | iPad | A has two Entities, one Relationship, one Action and a 2-MiB file owned by the edge; B is an independent private control graph. Both publish. A gets a read-only invitation and control ledger. Exact native inventories and source store UUIDs captured/validated. |
| accept | XR | Fresh replica accepts the invitation and imports all five A records, including exact attachment bytes. Local upload queue remains empty. removeAll is refused by read-only permission. |
| empty | iPad | removeAll returns five; PH discovers exactly five pending deletes, delivered in batches of at most two until drained. Repeated removal returns zero. Cloud A contains only its original CKShare/control ledger; native store UUIDs, ledger revision, invitation URL and B remain unchanged. |
| read-empty | XR | Independently fetches/applies deletions and observes zero A application records, with no reupload. Participation remains active; read-only mutation is still refused. |
| repopulate | iPad | Same GraphID/native store/zone/share accepts two new Entities and one Relationship with fresh IDs, delivered through normal batches. Old IDs remain absent; B and ledger remain unchanged. |
| read-new | XR | Same participation independently imports the exact three fresh IDs, with all old records absent and upload queue empty. No local mutation was used to force the result. |
| audit | iPad | Restart verifies the three fresh IDs and absence of the originals; native cloud inventory is three GraphEvoNode records, one original CKShare and one GraphEvoControl. B remains its original single node. Store UUIDs, share URL, ledger revision and empty queues retained. |

Each reserved stage passed once. The owner stayed alive through independent
peer observation before later owner restarts. Inventories used typed Graph scope
and CloudKit zone-change APIs, not direct SQLite inspection. Complete native
records were decoded, including the seed CKAsset. The emptying operation never
issued a zone deletion or native mirroring purge.

## Remaining gates and delivery

This bounded physical run demonstrates logical emptying/repopulation under the
custom CKSyncEngine backend while preserving sharing/control state. It does not
prove a global cloud wipe, remote atomicity, absence of concurrent remote inserts,
read-write guest emptying, permission/account changes during delivery, process
kill during deletion publication, production scale, secure physical erasure or
immediate external-storage reclamation. Injected failure/late-receipt tests are
separate from physical network-failure evidence.

MF04 working-copy identity, sealing/recovery, post-validation backup and
original-store migration publication remain design-only. Mandatory v1 conversion
and the post-alpha gates remain open. At the original candidate report, review/CI/merge had not yet been requested;
the completed review and subsequent checkpoint are recorded below. Follow review/corrections,
then any requested full checkpoint, then authorized merge. No laboratory was
added to CI.


## Pre-CI review

Review of `165132e` found no remaining defect in the examined implementation.
The review checked graph-scoped preflight/destructive boundaries, hidden control
retention, native/current adapters, cancellation and permission admission,
deleted identity tracking, frozen-send acknowledgement and independent transport
receipts. It preserves the distinction between local commit and remote delivery.

Two additional adversarial regressions were added without changing library code:
an externally injected cross-graph incoming Action refuses emptying while keeping
both graphs intact; a consumer catching a record-limit refusal can commit a
separate patch without partial emptying or pending deletes. The reviewed focused
macOS suite passes **15 functions** (emptying and transport), and iOS 18.5 Simulator
passes **12 emptying functions / 13 invocations**. The earlier complete suites and
eight physical stages retain shipping-source pin `a19ae62`; they were not rerun
merely for added regression tests. Full remote validation follows this completed
review before authorized integration. No workspace behavior is certified.


## Remote checkpoint and integration

After review, full [CI #311](https://github.com/bbruno84/GraphEvo/actions/runs/41301437693)
passed macOS and iOS on reviewed head
`5ca26449a45704e8ebbb95a51f72fba0e781c0ef`, including the added regression tests.
The label was added only after review and removed after success before recording
these documentation-only integration notes. Shipping library source remains
`a19ae62`; unchanged library tests are not rerun for evidence documentation alone.
PR #123 records the authorized merge into `codex/graphevo-2`. Physical laboratories
were not added to CI. Workspace and broader beta/stable gates remain open.
