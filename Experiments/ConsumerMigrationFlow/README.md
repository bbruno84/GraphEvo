# MF06 — representative consumer migration

This is a local-only integration laboratory over MF01–MF05, not another runtime
executor, public API, format registry or v1 conversion. Normal CI does not compile
or run these files. Shipping `Sources`, `Tests` and the manifest are unchanged.

`ConsumerMigrationExample.swift` is application/example code using existing
package-only operations. It repairs a synthetic invoice: converts a string cent
amount into a typed integer, removes an obsolete entity/edge/file, preserves a
surviving action, adds a category/relationship and replaces a 2-MiB attachment.
It explicitly updates the graph ledger, then publishes through the ordinary
workspace/backup/native-receipt path. It never edits native Core Data objects,
transplants history, attaches the copy to sync or computes a graph diff.

## Local protocol

Use a new external destination and only disposable synthetic data:

```sh
python3 Experiments/ConsumerMigrationFlow/prepare.py /tmp/new-consumer-migration-host
swift test --package-path /tmp/new-consumer-migration-host --filter ConsumerMigrationFlowTests
```

The script archives the committed shipping tree and adds the two local files to
that export's existing test target. `runtime-revision.txt` identifies the shipping
pin; `consumer-laboratory.json` records overlay SHA-256 hashes. The laboratory is
inside the exported package solely to access package-only APIs, not proof of a
public opener. Do not point it at an application, device, cloud or v1 store.

For iOS, run `xcodebuild test -scheme GraphEvo-Package` from the exported directory
with an available simulator and `-only-testing:GraphEvoStoreTests/ConsumerMigrationFlowTests`.
Do not add these fault protocols to the production CI workflow.

The six test functions cover ten invocations: restart after preparation,
transformation-before-consumer-checkpoint, seal, native-publication-before-result,
and ledger-completion-before-consumer-checkpoint; rejected input and post-transformation
semantic validation with no premature
backup; ledger outage after committed data; a lost begin result; foreign ledger
operation/malformed consumer journal refusal. They explicitly close/reopen owners
and sessions. They are not physical power-loss or OS process-kill tests.

## Consumer and library responsibilities

The happy path remains prepare → mutate the ordinary working `GraphStore` →
validate → publish. Graph supplies isolation, seal/PH discovery, verified backup,
atomic original publication and commit receipts. The consumer defines eligibility,
the transformation, semantic validation, ledger information and peer policy.

The example adds a small *consumer-owned* journal for its requested operation,
workspace and returned receipt. Its paths are supplied at bootstrap; only IDs,
phase labels and the bounded receipt are serialized. An immutable request UUID is
saved before beginning the ledger operation, so a missing result can be matched
to that exact request. A foreign running ledger operation is refused, not adopted.
Recovery-required local ledger intent is inspected before explicit resume; it is
not mistaken for a confirmed remote revision. Unknown journal/receipt state fails
closed. This example assumes one caller owns its directory and supplies the
correct source before application access; it is not a hardened generic journal,
multi-process recovery coordinator or distributed lock.

The consumer's `consumerRepair` marker is ordinary application data, saved with
the transformation in the same working transaction. Its exact operation UUID lets
this particular consumer skip an already committed transformation after losing
its own checkpoint. It is not native per-record versioning or a requirement for
every application. Multi-transaction transformations must define their own
supported checkpoints/idempotency rather than blindly replay arbitrary bodies.

Before any original commit, the example validates its domain semantics and seals
the working graph. No backup is created on domain rejection. Publication creates
and verifies one `.geb`; retry after a lost result reuses native commit evidence
and does not repeat the transformation, publication or backup.

The ledger stays independent of application data pause. Its `running` state can
be observed while the original still has old data. The consumer calls completion
only after its own verification policy succeeds. A completed ledger projection
and materialized migrated records are separate observations: another device must
apply its own admission policy, not treat a ledger phase as a cloud data barrier.
The example never automatically pauses or resumes another device.

## Physical protocol

Use the existing disposable signed-demo export mechanism and the exact committed
shipping source, adding only the external probe plus this example to the exported
module. Preserve their hashes and source revision. Fresh zones/fixture UUIDs only;
no container reset, copied native replicas or replay of reserved mutation stages.
Current sandbox paths are resolved on each launch. Reports, identities, invitation
capabilities, signing and stores stay outside git.

| Stage | Assertion |
|---|---|
| XR identity | Capability only; no graph created. |
| iPad seed | Fresh A/B, complete initial application inventory and 2-MiB file, confirmed real sends, read-only invitation and global consumer ledger information. |
| XR accept | Empty independent participant imports the original, no upload feedback. |
| iPad prepare | Begin ledger, prepare/transform/validate/seal copy, refuse original writes, zero backups. A stays old; unrelated B advances to 2 while A is paused. |
| XR observe-prepared | Running/validated ledger is visible while the original records/file remain old. |
| iPad publish | Restart and recover the seal; commit with a verified backup, deliberately lose the result before updating the consumer journal. No data send yet. |
| iPad recover | Restart again, recover native receipt without body replay or another backup; send ordinary PH batches and inspect complete native cloud inventories. |
| XR read-final | Observe final invoice/category/edge/action and exact new file bytes, no feedback; ledger still reports running until the consumer explicitly completes. |
| iPad finish | Consumer completes the verified operation, retaining original global ledger information and share. |
| XR observe-complete | Same completed operation and matching migrated application data; read-only permission retained. |

Keep each writer process alive until independent peer observation. Use separate
stage reservations/reports and explicit verified-PID termination for restart.
Neither local save nor a launcher acknowledgement certifies peer recovery.

Participant-origin workspaces, fresh-after-publication shared bootstrap,
external-process writers, physical interruptions during native save, scale,
distributed compatibility policy and mandatory v1 conversion remain open.
