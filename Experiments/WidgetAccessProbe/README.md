# Actual WidgetKit / shared Graph laboratory

This prepares a separate configured copy of GraphEvoDemo with a real WidgetKit
extension. The original configured demo and all prior stores stay unchanged.
The target reads through public `GraphDatabase.openReadOnly`, not a copied
counter in UserDefaults/JSON or a provider invoked inside the app. The app is
the only writer and optional CloudKit owner. No direct Core Data APIs or private
WidgetKit APIs are used.

## Preparation

Prerequisites: configured demo, local v2 checkout containing the extension access
increment, Xcode 27.x, Python 3 and separately installed MIT-licensed Ruby
`xcodeproj` (tested 1.27.0; its source is not bundled). The generated host targets
iOS 18+ for the XR matrix. Shared value/reader types opt out of the demo's
MainActor default; the widget target compiles in Swift 6 mode. The app feature
uses a view model and one actor-owned writer rather than the v1 GraphProvider.

```sh
python3 Experiments/WidgetAccessProbe/prepare_demo.py \
  /path/to/configured/GraphEvoDemo /tmp/new-widget-laboratory \
  --app-group group.com.example.GraphEvoDemo \
  --widget-bundle com.example.GraphEvoDemo.GraphEvoProbeWidget
```

Use identifiers belonging to the authorized developer team. The widget bundle
must be prefixed by the configured app bundle identifier. These values and local
signing changes are written only to the external copy, never tracked project
files. The script adds the group to the copy's local app entitlements and creates
a group-only widget entitlement file. It retains CloudKit Development entitlement
only in the containing app. Automatic signing/REGISTER_APP_GROUPS is enabled;
Apple account agreements/capabilities must permit provisioning both targets.
The extension is embedded in the app. Existing source signing files are not edited.

```sh
xcodebuild build -project /tmp/new-widget-laboratory/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/widget-device-build -allowProvisioningUpdates
```

For Simulator **keep ad-hoc signing enabled** so App Group mappings are actually
registered; building with CODE_SIGNING_ALLOWED=NO is not an accepted runtime test:

```sh
xcodebuild build -project /tmp/new-widget-laboratory/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/widget-simulator-build CODE_SIGN_IDENTITY=-
```

## Protocol and UI

Install the built containing app, which includes its extension. Add the
**GraphEvo laboratory** widget to the Home Screen before creating a fixture.
The missing-store entry should say `open-app-first`. It attempts public read-only
opening of a deliberately absent path and requires `missingStore`, with no SQLite
creation. Gallery placeholders/previews are never Graph evidence.

The app opens the independent widget laboratory by default. Buttons prepare a
new local or mirrored fixture, increment its counter, request a widget timeline,
and close the application's Graph owner. Each preparation uses a fresh UUID and
is never replayed into an existing directory. Reopening uses the saved graph/node
IDs and original files. Manual increment/reload/close actions have distinct
tickets. No reset, purge, migration or invitation is part of the feature.

Only the app creates the run's `private.sqlite`; mirrored mode also creates
`shared.sqlite` and awaits both native setup events before seeding. The mode uses
the configured test container without resetting it. It does not prepare a share
or invite another account. Native setup/local commits are not cloud export proof.
Every real provider invocation opens existing resources locally, queries the
published node with explicit maximumCandidates=4096, checks attempted mutation
body admission is refused, and closes both graph/database leases before returning.
No budget is silently raised, failed query turned into a zero, or value supplied
from the manifest. Missing/failed states remain visible.

The shared manifest contains only run/graph/node IDs, mode and last owner PID.
It has **no counter value**. Each widget entry records its actual queried value,
provider PID, owner PID, status and safeguards under:

```text
<App Group>/Library/Application Support/GraphEvoLaboratory/WidgetAccess/
  active.json
  <run>/private.sqlite [and shared.sqlite]
  AppReports/<run>/<one-use-stage>.txt
  WidgetReports/<invocation-UUID>.json
  widget-latest.json
```

The extension writes only separate laboratory evidence files, not Graph rows.
Logical IDs and raw reports/stores remain protected test artifacts. Reports do
not include account identities, invitation URLs or cloud record IDs. Do not
commit them. `collect_evidence.py` validates a copied report without invoking a
provider; PID difference is not proof that the app owner is still alive. Capture
app liveness and its successful retain/close report separately.

CLI app stages are optional for repeatable device orchestration:

```text
--launch-ticket <fresh-UUID> --widget-lab local|cloud <new-run-UUID>
--launch-ticket <fresh-UUID> --widget-lab update1|update2|close|reload <same-run-UUID>
```

Use the [acknowledged launcher](../PublicMirroredProbe/README.md#acknowledged-launches-and-causal-triage).
Do not replay a reserved write after a timeout. An existing app may merely be
reactivated with old arguments; receipts/stage reports are distinct evidence.
The default UI resumes the manifest's run for explicit increment after reopening.
A close command in a newly launched process with no loaded owner is a no-op;
prove clean native detachment using the original owner's UI and a later widget
read, rather than treating process termination or a cold close as that event.

## Verification matrix

1. Add an actual Home Screen widget before fixture creation; require a missing
   store, mirror refusal, no SQLite under NotInitialized/Forbidden, and a report
   from the extension process. Preview UI is not sufficient.
2. Prepare local run once. Keep the app's owner alive. Require widget query 0,
   then commit 1 in the app and require a later widget query 1 with both guards.
3. Close the app's owner. Require a later widget query of unchanged 1. Reopen the
   same files/IDs, commit 2 and require widget query 2. Retain process evidence.
4. Repeat the meaningful steps on real iOS App Group/sandbox with an app-owned
   private/shared CloudKit container. Distinguish native setup, local visibility,
   independent cloud recovery, and WidgetKit scheduling. This protocol alone
   does not establish independent cloud export/recovery.
5. Check app background/resume and widget timeline reopen; add protected-data,
   account/revocation and crash coverage separately. A Simulator cannot certify
   hardware suspension/jetsam/locked-device policy or memory limits.

`WidgetProbeOwnerTests` is copied into the demo test target: three tests cover
closed-owner resume with stable IDs/exact counter, seed replay refusal without
replacement, and foreign-run mutation refusal. Run with `-only-testing:GraphEvoDemoTests/WidgetProbeOwnerTests`.
No interactive widget write or CloudKit entitlement exists in the extension.
Timeline requests are system-scheduled and budgeted; the app requests a targeted
reload after explicit state changes, with a 15-minute fallback policy. No
permanent observer or native owner is retained in the widget. The library stays
independent of WidgetKit.

Device evidence must stay under the App Group Library/Documents/tmp transport
boundary. Early root-level trial files are retained separately, not moved or
converted; prepare a new run in the supported laboratory namespace.

See the [actual Simulator/device result](../../docs/design/results/widget-app-group-2026-10-29.md)
for accepted scope, initial signing/transport observations and remaining gaps.
