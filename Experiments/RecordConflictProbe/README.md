# T02 — real concurrent record conflicts

This laboratory exercises the integrated T01 transport without installing a
resolver or prototype engine. Both devices start from the same real server
version. The peer edits and freezes its outgoing attempts before the owner
publishes competing changes. The peer then sends its stale attempts. This is
controlled logical concurrency; success does not depend on simultaneous taps
or network timing.

## Isolation and preparation

Use a new run UUID and new external host/evidence directories. The preparation
script reuses the reviewed T01 disposable host exporter, pins the committed
runtime and adds only the adjacent external bridge. It never edits the original
demo or production Sources/manifest. Inspect the signed app's entitlements:
only `iCloud.com.valerioburiani.GraphCKDemo`, Development. No cloud reset,
old-store conversion, zone purge or existing fixture replay is authorized here.

```sh
python3 Experiments/RecordConflictProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-conflict-host
xcodebuild build -project /tmp/new-conflict-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-conflict-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

One ContextManager controls all four exclusive graph stores through its private
engine. The graphs have separate `GE2-C01-<run>-U/D/R/B` private zones; C01 is
this disposable host's zone prefix, unrelated to the local consolidation cost
benchmark. U tests update/update and partial success; D tests update then stale
delete; R tests delete then stale update; B tests independent progress.

Every graph starts with one entity: value 1, or 99 in B. Fixed logical IDs/dates
permit exact comparisons. App-relative files live under
`Library/Application Support/GraphEvoLaboratory/RecordConflicts/<run>/<replica>/`.
Frozen references contain detached batch/zone/node identities and native archives,
never store URLs. Do not copy native stores to construct a peer/fresh replica.
Do not commit stores, frozen archives, account/session files, raw device logs,
local signing or private run envelopes.

## Execution

Use `PublicMirroredProbe/launch_probe.py` with fresh output directory/ticket on
every launch, then `RecordConflictProbe/collect_report.py` for the independent
stage result. CLI after the launch ticket:

`--record-conflict <stage> <run-UUID> owner|peer|fresh`

Only one explicit stage runs per host process. Each stage reserves its started
marker before effects and refuses replay, including after failures/missing
reports. Stop on any failure; inspect the existing state before designing a
recovery stage. Neither helper retries a mutation. Before a planned restart,
terminate only the PID acknowledged for the previous host. Keep writers alive
through independent server/peer observation. Launcher success alone does not
establish stage or synchronization success.

| Ordered stage / replica | Assertion |
|---|---|
| `seed owner` | Four new graph/store/zone fixtures, actual server tags, queues empty. |
| `read-baseline peer` | Four genuinely empty stores recover exact baseline without upload feedback. Privately compare account identities. |
| `prepare-peer peer` | U value 3 plus unrelated new leaf, D deletion, R value 3. Freeze three actual native attempts against unchanged baseline; no send. |
| `owner-compete owner` | U/D become value 2; R deleted. Send and independently verify server state after peer preparation. |
| `submit-update peer` | Stale U tag is demonstrably older than server tag. Real serverRecordChanged retains local 3. New leaf in the same non-atomic batch succeeds; only that success is acknowledged. |
| `submit-delete peer` | D's stale record-ID deletion removes server value 2. Local deletion acknowledged; server absent. |
| `submit-after-delete peer` | R's stale save returns unknownItem, retains local 3/pending attempt and does not recreate the server record. |
| `independent-progress peer` | B becomes 100 through the same private engine while U/R remain pending. |
| `retry-peer peer` | New local U value 4 has a newer PH generation. Frozen attempt still contains value 3 and its original generation. Retry does not acknowledge/overwrite the newer edit or resolve the collision. |
| `fetch-conflicts peer` | Explicit fetch retains U's server value and R's deletion. Applying either fails with pendingImport, preserving local data/queue and inbox. D/B effects remain independent. |
| `observe-owner owner` | Recover partial-success leaf, D deletion and B update. Complete local/server inventories match; no upload feedback. |
| `reopen-peer peer` | Local 4/3, pending generations, frozen attempts and refused incoming work survive process restart. |
| `read-final fresh` | New empty stores recover only server winner + leaf in U, empty D/R and B=100. Full inventories match without feedback. |

The collector performs bounded read-only report retrieval. Reports contain only
outcomes/check descriptions. Protected session inspection can additionally verify
that the specific bound U/R record envelopes remain retained, sent receipts are
consumed and bindings remain path-free. It is not a substitute for graph/PH checks.

## Meaning of the result

The [initial thirteen-stage result](../../docs/design/results/record-conflicts-cloudkit-2026-10-31.md)
records exact runtime/CI/device provenance and observed outcomes. In particular,
record-ID deletion is not protected by a save change-tag comparison. Do not claim
that all concurrent operations become serverRecordChanged. An unresolved local
edit stays preserved even when the server record is absent; this is not an
implemented consumer resolution API or automatic convergence policy.

Pending remote/local collisions conservatively refuse the whole selected import;
this laboratory does not add automatic field merging, last-writer-wins, tombstones,
rebase, schema changes or mutation replay. Multi-node structural conflicts,
attachments, sharing/account changes, offline/throttling, power-loss and joint
backup restore remain separate gates. Per the alpha CI policy, use signed local
builds/physical evidence for this excluded bridge; do not claim skipped remote
jobs are new full-suite passes.
