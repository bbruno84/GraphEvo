# Fresh native identity private/shared probe

Status: controlled A5 sharing/recovery/lifecycle and A6 attachment runs passed on
2026-10-29 on owner iPadOS 27.0 and different-account XR iOS 18.7.10. Retain the
first recovery save conflict and later explicit successful recovery in the
[result](../../docs/design/results/native-identity-paired-devices-2026-10-29.md).
Public mirrored defaults are unchanged; reviewed adoption remains separate.

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

Add `--attachments` to prepare a separate A6 file host instead of A5. It uses
`--a6 <stage> <new-run-UUID>` and the distinct
`GraphEvoLaboratory/NativeIdentityFiles/<run-UUID>/` directory. Follow
[A6's procedure](../A6NativeProbe/README.md) with separate transports and fixtures;
never mix A5 and A6 runs. The host adds full native integrity on seed and normal
file verification, and requires A's final full integrity count to be zero after
cascade. Both host variants were built for generic iOS and run on physical peers.

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
| Local native setup | Both private/shared loads and successful native setup with the optional identity columns/indexes | Observed in controlled run |
| Owner boundaries | A5/B5 full native integrity and distinct owner-only share zones | Observed in controlled run |
| Independent participant import | XR imports exact A IDs/native columns and endpoints, shared scope, A5 full integrity, B absent | Observed in controlled run |
| Participant insertion | Entity/Relationship/Action and owned details assigned once; owner independently recovers A8/B5 and native integrity | Observed in controlled run |
| Participant details | New property/tag/group assignment, exact values, no pending operation, all rows in A's zone | Observed in controlled run |
| Permissions | Read-only rejects a library edit; restored read/write edit returns to owner | Observed in controlled run |
| Interrupted assignment | Existing Debug pause, original ledger and single-assignment recovery; independent owner observation | First save conflict; explicit recovery succeeded |
| Lifecycle | Revoke, reaccept and exact shared-zone leave preserve participant private control and owner A/B | Observed in controlled run |
| Attachments | Separate native-column file fixture/import/replacement/checksum/cascade acceptance | Observed in separate A6 run |

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

## Explicit recovery and launch tickets

`recover-after-conflict` is a distinct host ticket for explicit recovery of a
retained assigned patch after a failed save. It calls recoverSharedOperation on
the existing journal, requires pending intent, verifies completion/empty ledger
and recovered values; it never invokes patchShared or native assignment again.
It is not an automatic retry of arbitrary application code. The first failed
`recover-patch` report remains part of acceptance evidence.

`reinvite-after-revoke` records a new invitation only after the run's confirmed
revocation. Distinct read-only observation tickets may be used after host launch
failures, retaining their exact roles in the result. The retained device run
separated known-process termination from launch after two CoreDevice pre-report
launch failures. Never replay a mutation whose invocation is uncertain.

The A5 and A6 successes cover one fixture/size and two OS versions. They do not
close account switching, simultaneous structural writer, arbitrary crash, quota,
server-enforcement, wider payload/performance or mandatory v1 migration gates.

## Public API adoption host

`--public-api` selects published schema opening and integrity methods rather
than the historical compatibility wrapper. For a public-only A6/private consumer
and separate read-only failure diagnosis, use
[PublicMirroredProbe](../PublicMirroredProbe/README.md). Current native files
require model version GraphEvo.nativeIdentity.alpha.2; original unversioned
laboratory files are retained as history and are not silently adopted.
