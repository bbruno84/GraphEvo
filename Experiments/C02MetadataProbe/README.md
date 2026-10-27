# C02 read-only native metadata check

Read the source demo README/AGENTS. Prepare a new disposable configured copy:

```sh
python3 Experiments/C02MetadataProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoC02Demo
xcodebuild build -project /tmp/GraphEvoC02Demo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoC02Build -allowProvisioningUpdates
```

The source demo/configuration remains unchanged. Install the disposable build on
the original owner iPad and different-account XR. Use a new ticket UUID and
launch `--c02 owner <ticket>` on iPad and `--c02 participant <ticket>` on XR.
Never replay a reserved ticket; retain any failed result before designing a new
read-only diagnosis. Reports contain no identities, invitations or file bytes.

This reads the existing successful A6 run
`291F43CA-76F3-4B93-B780-B6CFC8DD5F7D` and its protected fixture envelope.
It expects the single A8 parent left after the successful A8 deletion, the
owner's exact original B attachment, and B absent on the participant account.
The probe opens the existing private/shared pair through GraphDatabase, checks
pending-operation diagnostics, then compares typed query, ID fetch and count.
Owner checks full B attachment metadata/exact bytes; participant checks catalog
isolation. Handles close after the read checks.

There are no application writes, share preparation/invitation/acceptance,
permission changes, wipe or recovery replay. Native opening can still perform
ordinary framework bookkeeping/imports; this is not immutable-file inspection.
This checks actual private/shared metadata access on retained stores, not fresh
replica recovery or new cross-account writes/partial native assignment.
