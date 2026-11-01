# MF06 — representative consumer migration result, 2026-11-01

This local-only [consumer laboratory](../../../Experiments/ConsumerMigrationFlow/README.md)
exercises the integrated MF01–MF05 path. Shipping source is
`76515e76484f2a2052d3d5c4af3a61f3932c5647` (#126). No distributed source, normal
test target, package manifest or workflow changes were needed. The example and
fault suite live outside default build/CI targets; the preparation script overlays
them onto a disposable committed package export and records revision/checksums.

## Consumer shape and responsibilities

The example repairs a synthetic invoice through ordinary working GraphStore
operations: string cents become an integer, an obsolete entity/edge/file is
deleted, a surviving action is reduced, a category/relationship is inserted and
a new 2-MiB file replaces the old content. It explicitly owns its eligibility,
semantic validation, ledger phases and peer-verification policy. It uses no raw
native mutations, format registry, graph diff or working-copy cloud binding.

The library supplies original holds, complete working copy, PH reduction/seal,
validated backup, atomic original publication and durable native commit proof.
The consumer saves a small request/journal outside the graph; no paths are
serialized. Its transformation writes an ordinary application operation marker
in the same working transaction. That particular marker makes its own lost
transformation checkpoint recoverable without rerunning the body. It is not
mandatory Graph metadata or a generic multi-step recovery guarantee.

One local example correction was required: a begun-but-unsent ledger operation
becomes `recoveryRequired` on restart. The consumer must inspect its own durable
request identity and explicitly resume it before expecting remote confirmation.
Another client's running operation is refused. Graph's existing behavior was
correct; no runtime change was required.

## Deterministic local result

Final macOS and iOS 18.5 Simulator runs pass **six functions / ten invocations**,
with no failures/skips. The same example source is used in the physical bridge.

| Case | Result |
|---|---|
| Restart after preparation | Reacquire holds before application use; transform once, one backup, valid final graph. |
| Transformation committed before consumer checkpoint | Recognize the exact application operation marker; do not run the body again. |
| Restart after seal | Recover the sealed copy, validate final data, publish without replay. |
| Native publication committed before consumer result | Recover the original native receipt; do not republish or create another backup. |
| Ledger completed before consumer checkpoint | Recognize the same terminal operation and repair only the consumer checkpoint. |
| Invalid transformation input | Refuse without original edits or a premature backup. |
| Semantic rejection after working transaction | Refuse before seal/publication/backup; original stays unchanged. |
| Ledger network outage after data commit | Preserve the successful publication receipt, recover ledger separately. |
| Begin result lost before consumer journal | Recover only the exact durable consumer request; no second operation. |
| Foreign operation / malformed journal | Refuse before opening/editing a working copy. |

The laboratory review also changed test cleanup to detach successfully before
deleting fixtures; failed fixtures remain available for diagnosis. The export
script's revision/hash manifest and outside-repository destination guard were
checked. Source diff/manifest checks pass. These checks do not replay the whole
shipping suite: that code is byte-identical to the reviewed green #324 checkpoint
already recorded in [MF05](migration-publication-2026-11-01.md).

## Physical iPad/XR result

The disposable signed demo uses the exact shipping pin above plus the local
consumer example and an external probe. Entitlements were checked for only
`iCloud.com.valerioburiani.GraphCKDemo`, Development. iPad owns A and private
control B; XR has another account and explicitly accepts read-only participation
in A from an empty store. Fresh fixtures/zones only; no container reset.

All **ten reserved stages** pass:

1. XR prepares its protected account capability without creating a graph.
2. iPad seeds A/B, sends real records/assets and creates invitation/global ledger information.
3. XR accepts into an empty independent replica and reads the original five primitives and old file.
4. iPad begins its operation, transforms/validates/seals the isolated copy and refuses original writes. Original A remains unchanged with no backup; B reaches value 2 in the cloud while A is paused.
5. XR observes the running/validated ledger while A still contains old application data.
6. iPad restarts, recovers the seal and publishes with one verified backup, deliberately losing the consumer result before its journal update. Data is not sent yet.
7. iPad restarts again, recovers the native receipt without transformation replay or another backup, sends normal PH batches and verifies complete native cloud inventories.
8. XR independently reads the final five primitives: integer amount, category/edge, reduced action, exact new 2-MiB file and old IDs absent. Ledger still reports running; no upload feedback.
9. Only after that independent verification does the iPad consumer complete the ledger operation.
10. Restarted XR observes the same completed operation and migrated data, retaining read-only access.

Owner native store identities, share URL and global consumer ledger information
are retained. The control graph progresses independently. Writers remain alive
through each independent observation; acknowledged processes are then explicitly
terminated for planned restart. The probes finish with both apps closed.

A first fresh fixture failed an instrumentation check after successful sealing:
the probe called `collectSyncChanges`, which persists a PH checkpoint, while the
original write hold was active. The runtime correctly refused that write. The
corrected probe reads persisted pending state without saving and audits native
cloud inventories. No consumed mutation was replayed: the complete ten-stage
protocol ran on a new fixture; first-run reports/stores remain preserved. This is
not a reproduced runtime crash or a claim that all sync bookkeeping is admitted
under a local write hold.

Source/overlay hashes, reports, capabilities, invitations, signing and stores are
retained locally outside git. No account values or sandbox paths are committed.
Application and control observations are distinct; a ledger phase alone is not
a CloudKit data barrier or distributed lock.

## Scope and next work

The protected flow composes without adding runtime machinery. The minimal path
is prepare → ordinary consumer edits → semantic validation/seal → publication;
the example's extra checkpoints implement its explicit interruption policy.
Public executor exposure, production consumer adoption, multi-transaction
transformation recovery, participant-origin migration, fresh shared bootstrap
after publication, physical kill/power-loss during save, external writers and
scale remain open. No beta or v1 conversion gate closes here.

Next: define and validate the mandatory v1 source identity/value/attachment
conversion and coordinated cloud cutover, using this existing protected path.
Consumers still own application compatibility; a new format registry is not
introduced. As an experiment/documentation-only increment, MF06 requires no new
full CI run; normal CI still excludes this laboratory.
