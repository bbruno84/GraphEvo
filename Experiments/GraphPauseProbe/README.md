# T05 — per-graph pause on one real private engine

The external bridge uses committed production code. New GE2-T05 run zones A/B,
new owner/peer/fresh stores and the authorized test container
`iCloud.com.valerioburiani.GraphCKDemo`, Development. Same-account iPad/iPhone.
Do not reset/purge the container, copy stores into new replicas, replay started
stages, log account values or commit raw stores/session documents/device logs.
Read the [contract](../../docs/design/graphevo-2-sync-pause.md).

```sh
python3 Experiments/GraphPauseProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-pause-host
xcodebuild build -project /tmp/new-pause-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-pause-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Inspect signed entitlements before installation. Use PublicMirroredProbe's
acknowledged launcher with fresh ticket/output directory, then this directory's
bounded read-only report collector. Arguments after the ticket:
`--graph-pause <stage> <run-UUID> owner|peer|fresh`.
App-relative files live under
`Library/Application Support/GraphEvoLaboratory/GraphPause/<run>/<replica>/`.
Each stage reserves its started marker before effects. Stop on any failure;
inspect retained state without repeating a consumed mutation. Terminate only
previously acknowledged process PIDs for planned restarts and keep writers live
through independent observations. Launch receipts are not stage acceptance.

| Ordered action | Assertion |
|---|---|
| seed owner | Publish A1/B1,date10 and compare exact local/server inventories/tags. |
| read-baseline peer | Independent empty stores recover baseline, no upload feedback. |
| pause-peer peer, first phase | Pause A twice, B stays active. Write pause-peer.ready, then await external continuation (180-second deadline). Keep this process alive. |
| update-owner owner | Only after ready is observed, publish A2/B2,date200. Verify its passed report before allowing the peer to proceed. |
| continue pause-peer | Copy an empty control file to peer/pause-peer.continue. Peer saves local A3/date300 while paused; send/apply A refuse. Native scoped fetch/import advances B2 without A record bodies entering its inbox. Resume A, fetch/apply and publish A3; verify full inventories/queues. Pause A again before finishing, for the restart test. |
| observe-owner owner | Independent convergence A3/B2, no feedback. |
| reopen-peer peer | Without fetch, data/queues survive but process-local pause starts active. |
| read-final fresh | New empty stores recover exact A3/B2 and empty upload queues. |

Seven stage reports cover these actions; pause-peer deliberately spans the
owner update. Its ready marker is not the stage's final result. The continuation
file is a laboratory barrier, not an application feature or a mutation retry.
Compare accounts privately after baseline. All final verification enumerates
complete typed local inventories and complete server-zone modifications from
nil tokens, limit100 with moreComing refused, including real native change tags,
full GraphRecords and modifiedAt. During the paused interval, inspect retained
inbox kinds rather than directly fetching A through an independent CKDatabase.
That avoids polluting the claim that the manager excludes A's record fetch.

In-flight send/fetch/native-write barriers, cancellation, attachment refresh
coverage and failures are deterministic local tests. This device protocol
validates actual zone-scoped framework behavior and process-local reset; it is
not an EDGE/background, shared-account, migration-exclusion or crash certificate.

Observed evidence: [seven-stage result](../../docs/design/results/graph-sync-pause-2026-10-31.md).
