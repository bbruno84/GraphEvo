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
