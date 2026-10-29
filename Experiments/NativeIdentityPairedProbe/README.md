# Fresh native identity private/shared probe

Status: built for physical acceptance; no native result yet. The 2026-10-29
Development reset was confirmed by the maintainer, but installation lost device
connectivity before any probe stage was launched. Do not infer an empty cloud
from an empty local catalog. Reconfirm the controlled cloud state if other
writers have since run.

This host reuses the one-use [A5 sharing procedure](../A5NativeProbe/README.md),
including protected run-bound transports, exact graph/member/zone checks,
permission changes, recovery and voluntary leave. It selects the internal
GraphNativeIdentityPairedLaboratory opener on fresh native-column resources.
Public mirrored opens continue using their previous model. The new host uses
`@testable import GraphEvo`; it is not an external public-API consumer.

```sh
python3 Experiments/NativeIdentityPairedProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoNativePairDemo
xcodebuild build -project /tmp/GraphEvoNativePairDemo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoNativePairBuild -allowProvisioningUpdates
```

Use Debug on the authorized iPad owner and different-account XR, the approved
Development container and a new run UUID. The original demo checkout remains
untouched. A5's `--a5 <stage> <run-UUID>` dispatcher is retained, but all store,
report and transport paths are under
`Library/Application Support/GraphEvoLaboratory/NativeIdentity/<run-UUID>/`.
Never substitute old A5 stores or transport files. No reset, automatic migration
or historical backfill is implemented by this probe.

## Acceptance matrix

| Step | Required evidence | Current status |
|---|---|---|
| Offline pair adapter | Equal UUIDs in separate graphs/stores route correctly; local-only resolver rejects mirrored context; missing projections fail; shared writes without accepted metadata fail | Local test passed |
| Local native setup | Both private/shared loads and successful native setup with the optional identity columns/indexes | Awaiting device run |
| Owner boundaries | A5/B5 full native integrity and distinct owner-only share zones | Awaiting device run |
| Independent participant import | XR imports exact A IDs/native columns and endpoints, shared scope, A5 full integrity, B absent | Awaiting device run |
| Participant insertion | Entity/Relationship/Action and owned details assigned once; owner independently recovers A8/B5 and native integrity | Awaiting device run |
| Participant details | New property/tag/group assignment, exact values, no pending operation, all rows in A's zone | Awaiting device run |
| Permissions | Read-only rejects a library edit; restored read/write edit returns to owner | Awaiting device run |
| Interrupted assignment | Existing Debug pause, original ledger and single-assignment recovery; independent owner observation | Awaiting device run |
| Lifecycle | Revoke, reaccept and exact shared-zone leave preserve participant private control and owner A/B | Awaiting device run |
| Attachments | Separate native-column file fixture/import/replacement/checksum/cascade acceptance | Follow-up; not exercised by A5 host |

Follow A5's ordered stages and separate stage tickets. The generated host adds
full native storage validation to A/B verification, so indexed point success
alone cannot certify the imported graph. It also retains seed, identity,
invitation and permission writers for peer observation. A native setup event,
local save, mapping, full local integrity and independent peer recovery remain
distinct facts. Do not replay a reserved mutation after timeout, clear journals,
repair imported identities or fabricate native share metadata.

The offline test uses NSPersistentCloudKitContainer with two local SQLite
stores and no cloud options: it does not contact CloudKit, assign shares, or
prove cross-user synchronization. Only the physical rows above can close native
acceptance. Public mirrored schema selection remains gated on those results.

Apple's [model guidance](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit)
and [persistent container sharing API](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer)
define the supported boundary. Model initialization and configured indexes do
not establish remote uniqueness, completed imports or authorization.
