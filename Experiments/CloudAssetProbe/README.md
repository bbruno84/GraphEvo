# T04 — CKAsset transport and async export device protocol

Runs the committed package-only production ContextManager/coordinator/provider.
The bridge only controls fixture identities, edit clocks and ordered actions.
Read [T04](../../docs/design/graphevo-2-cloud-assets.md) and the
[physical result](../../docs/design/results/cloud-assets-2026-10-31.md).

## Isolated host

```sh
python3 Experiments/CloudAssetProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-asset-host
xcodebuild build -project /tmp/new-asset-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-asset-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Export a committed runtime to a new external host. The helper adds only this
bridge; it never edits the original demo. Verify signed entitlements: only
`iCloud.com.valerioburiani.GraphCKDemo`, Development. Use same-account iPad/iPhone,
a new run UUID, three new stores per replica and private zones
`GE2-T04-<run>-A/C/B`. A uses lastEditWins, C cloudWins, B is the control.
App-relative files live under
`Library/Application Support/GraphEvoLaboratory/CloudAssets/<run>/<replica>/`.
No container reset, purge, old store copying, fixture conversion or raw account
logging. Compare accounts privately; never commit session documents, file data,
frozen archives, local signing, device logs or private case envelopes.

Use `PublicMirroredProbe/launch_probe.py` and then this directory's
`collect_report.py`, each with a new external output directory. Arguments after
the launch ticket: `--cloud-assets <stage> <run-UUID> owner|peer|fresh`.
Unique started markers reserve effects before execution. Stop on any failure or
missing report; inspect original state without replaying the consumed stage.
Terminate only previously acknowledged PIDs for planned restarts. Retain writer
owners through independent server/peer observation. Launch and stage receipts
are separate facts.

| Ordered logical stage | Assertions |
|---|---|
| seed / owner | A: owner + 10MiB asset + empty asset; C/B: owner + 512-byte asset. Publish and compare complete local/server inventory, content, dates and real native tags. |
| read-baseline / peer | New empty stores recover through cancellable async export; exact files and metadata, no upload feedback. |
| prepare-peer / peer | Replace A/C with 4096-byte content/date300; freeze original server base, without send. |
| owner-replace / owner | Publish competing A/C 2048-byte content/date200; B unchanged. |
| resolve-peer / peer | A publishes current peer content with at most one targeted retry; C imports whole owner revision. Exact outcomes, data, inventories and queues checked. |
| observe-owner / owner | Independently fetch/import A4096/C2048/B512 and A's empty file, without feedback. |
| reopen-peer / peer | No fetch: content, policies, metadata and empty queues survive restart. |
| delete-owner / owner | Delete A owner; three deletions cascade to both files, C/B unchanged. |
| read-deleted / peer | Independent replica applies exact cascade without resurrection/feedback. |
| read-final / fresh | New empty stores recover A empty, exact C/B records/files and queues. |

Every verification enumerates typed scoped local nodes and all server zone
modifications from nil tokens, limit100, refusing moreComing. It compares full
GraphRecords plus expected bytes, ownership, modifiedAt and actual nonempty server
tags. Attachment metadata checks SHA-256 and length. Real server fields must be
CKAsset, not Data. No native SQLite inspection is used to infer synchronization.

## Explicit bounded continuations

These are recovery stages for the retained initial run, not generic retry loops:

- `seed-remaining owner`: only after the recorded initial fixture error. A must
  contain three local records and C/B no application rows. A is never reseeded;
  only C/B are created, then all local/server inventories are verified completely.
- `resolve-remaining peer`: only after the recorded pre-receipt conflict failure.
  Both persisted attempts must equal the original Frozen-A/C artifacts and each
  graph must retain exactly one pending change. Retry those immutable attempts
  with the corrected runtime; no consumer replacement body is replayed.

Never use these continuations if their preconditions do not hold. The result
retains original failures, subsequent code correction and exact runtime provenance.
Private entity/asset evidence does not close shared-account permissions, real
media/resource envelopes, actual process death mid-publication, EDGE latency,
background execution or joint backup restoration.
