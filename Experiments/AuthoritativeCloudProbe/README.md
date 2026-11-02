# MF10 authoritative-cloud laboratory

The first stage proves the contract's prerequisite before implementing seed
publication. It uses a new synthetic private Development zone and two independent
untagged `GraphEvoActivation` records with the same fixed record ID. Exactly one
conditional first save must succeed; the other must return serverRecordChanged.
A later untagged save must preserve the winner and its real server change tag.
No engine, application data or private support archive participates in this stage.

```sh
python3 Experiments/AuthoritativeCloudProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-mf10-host
xcodebuild build -project /tmp/new-mf10-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-mf10-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Inspect the signed Development entitlements before installing on an available
device. Launch once with `PublicMirroredProbe/launch_probe.py`, a fresh evidence
directory and `--record-transport claim-exclusion RUN-UUID owner`. A durable
started marker refuses replay. The independent result is at
`Library/Application Support/GraphEvoLaboratory/AuthoritativeCloud/RUN-UUID/claim.report.json`.
Retain raw evidence externally; do not commit accounts, stores, signing or logs.
The probe retains its zone and never resets cloud data. A failed stage must be
investigated before a separately defined continuation; never replay it.

This prerequisite alone does not establish MF10 publication, peer recovery,
production deployment or v1 writer/completeness acceptance.

## Production activation protocol

Pass `--activation` to the exporter to add only the adjacent external bridge and
controller. Normal package/CI targets remain unchanged. Each stage is invoked as
`--record-transport STAGE RUN-UUID REPLICA`, reserves an immutable started marker
and refuses replay. Use `collect_report.py` for the independent bounded report.
Terminate only the PID acknowledged by the prior host before a planned restart;
retain writer owners through independent peer observation.

| Order | Stage / replica | Required observation |
| --- | --- | --- |
| 1 | prepare / owner | Synthetic five-primitive v1 source, complete local conversion/backup, explicit 2-MiB attachment, immutable six-record seed and blocked writes. |
| 2 | verify-account / owner and peer | Compare salted account digests privately before private-zone peer requests. No account value/digest enters reports or Git. |
| 3 | seed / owner | Restart preserves native admission; one production batch acknowledges the six records while phase remains seeding. |
| 4 | publish / owner | Restart recovers the empty queue, verifies the complete server seed/assets and publishes exact authority. |
| 5 | recover-peer / peer | Genuinely empty independent S04 store recovers current UUIDs, full records/topology and asset bytes, without outgoing work. Owner stays alive. |
| 6 | update-owner / owner | One ordinary post-publication property edit reaches the server. Peer stays alive until the new stage is admitted. |
| 7 | refresh-peer / peer | Reopen fetches/imports the later value; complete local/server inventories agree and upload work remains empty. Owner stays alive. |
| 8 | prepare then seed / contender | A separate conversion has new random IDs/operation. Its authority request is refused as conflict before any send. Owner remains live. |
| 9 | verify / owner | Original source bytes, authority and current six-record server/local inventories remain intact after the contender. |
| 10 | recover-peer / fresh | Another genuinely empty replica recovers the current state after ordinary edits, preserving the original authority and no-feedback semantics. |

All native stores, salted digests, session files and raw reports remain outside
Git/CI. No source database is copied to create a peer. Claim and activation runs
use distinct fresh UUIDs/zones; old protocol results retain their actual runtime
pins. A first-create proof and an owner-only run never establish peer acceptance.
