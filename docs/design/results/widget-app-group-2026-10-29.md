# Actual WidgetKit / App Group access — 2026-10-29

Result: positive for the bounded app-owned synchronization / local read-only
widget baseline. This extends the [first access safeguard](extension-readonly-access-2026-10-29.md)
with an actual WidgetKit target and signed hardware App Groups. It does not
certify interactive widget writes, account cutover or the whole PA02 matrix.

## Delivered laboratory

[WidgetAccessProbe](../../../Experiments/WidgetAccessProbe/README.md) reproducibly
prepares a separate copy of the configured demo. It adds small/medium WidgetKit
families, shared detached model/reader code, a view model and actor-owned app
writer, explicit one-use CLI stages, receipts, evidence collection and three
focused demo tests. The original configured demo was not edited.

The containing app has Development CloudKit plus the authorized App Group. The
extension has the same App Group and no CloudKit entitlement. Signature inspection
confirmed both facts. The widget calls public openReadOnly, queries the counter,
requires exact public errors for attempted mirroring/mutation admission, closes
its leases, and returns immutable timeline values. Its manifest contains IDs,
mode and last owner PID, **no counter value**. Query allowance is explicitly
4096; it is not increased in response to a failure. No native contexts or direct
Core Data/CloudKit record manipulation are used by the feature.

The shared namespace is Library/Application Support/GraphEvoLaboratory/WidgetAccess
inside the App Group. This respects CoreDevice's Library/Documents/tmp file
transport boundary. Early root-level evidence files were preserved; new runs
use the supported namespace, with no store migration or rewriting. An initial
unsigned Simulator installation lacked an App Group mapping and did not produce
a usable timeline. Ad-hoc signing registered the real mapping; that signed
configuration supplies the accepted Simulator evidence.

## Observed matrix

| Environment | Actual result | Scope |
|---|---|---|
| Dedicated iOS 27 Simulator, local single store | Missing-store entry, then 0 → 1; owner close, later read of 1, reopen and 2 | Real WidgetKit extension and separate PIDs, simulated sandbox/runtime |
| iPad, iPadOS 27.0, app mirrored private/shared pair | Missing-store entry before initialization; 0 → 1 with app owner live; explicit native owner close, later widget read of 1; existing pair/IDs reopened, then 2 | Real signed App Group and public Graph APIs; Home Screen rendering directly observed |
| Maintainer's iPhone, iOS 27.2, app mirrored private/shared pair | Missing-store entry before initialization; 0 → 1 → 2, retaining the original run/files/IDs through explicit app relaunches | Real signed App Group; app/widget process liveness retained independently; maintainer confirmed both widget sizes visibly show 2 and Safeguards passed, with a supplied photo |
| iPhone XR, iOS 18.7.10 | Signed app/extension installed, App Group accessible, instruction-only launch acknowledged | Widget execution not verified: Device Hub remained Connecting display; no widget report was obtained |

For accepted reads, reports contain status=ready, the expected run/value,
mirrorRefused=true, mutationRefused=true and a widget PID distinct from the
manifest's owner PID. Process lists separately confirmed the app and widget
were alive for the retained owner/read windows. PID inequality alone is not
used as owner liveness proof. The iPad's post-close entry timestamp is later
than the durable close report's native file modification timestamp. Local
commits, native setup, query results and visible rendering are distinct evidence.

On iPad, CLI prepared one fresh mirrored fixture and awaited two setup events.
Subsequent increment/close/reopen actions used the actual UI in the same app
process. On iPhone, the app was explicitly relaunched between the numbered
updates; this establishes reopening, not one continuous writer across phases.
Both devices' widgets queried their own app's local files; this was not a
cross-device export/import or cross-account sharing test. No invitation, new
share, purge, cloud reset, schema conversion or lifetime file lock was introduced.
A widget can read persisted state while the app's owner is closed; that does not
make the widget a synchronizer.

## Checks

- Full package suite: **520 pass** (322 legacy, 111 store, 64 runtime, 23 model).
- New demo WidgetProbeOwnerTests: **3 pass** on iOS Simulator, covering stable
  identity/counter after close/reopen, seed replay refusal without replacement,
  and refusal to mutate an unrelated run.
- Configured device app with embedded extension: signed build and installation
  pass on iPad, XR and the explicitly authorized maintainer iPhone.
- Clean generator preparation and Simulator build pass; simulator signing is
  ad-hoc with actual App Group registration.
- Structured report checks pass for accepted hardware missing/0/1/2 states.
- Python syntax, Ruby syntax, manifest and diff checks pass.

Raw stores, manifests, report files, device/process logs, signing information and
personal screenshots remain outside the repository. The supplied iPhone photo
is retained as private visual evidence, not published with source.

## Remaining work and disposition

This validates a first physical baseline for a containing-app CloudKit owner
plus a local read-only widget. Keep the iOS 18 actual-widget gap explicit.
Suspension/jetsam, protected-data/locked-device access, concurrent migration or
reset, account/revocation/cache policy, production size/memory envelopes and
interactive widget writes still require their own decisions/evidence before
the corresponding beta/stable gates. App background/Home Screen transitions
here are not an exhaustive suspension or crash campaign. WidgetKit reloads are
system-scheduled; this is not an instantaneous-refresh promise.

#93 was reviewed at 87066849aab8ddf91c6d7e96edac75a6d13e3c69; macOS/iOS CI
40942387291 passed, including its independent-process consumer, and it merged
into the consolidation parent at cb975b4d2002592ea16d4ca854663e748421cbd9.
Historical non-reproduced launch/invitation incidents remain open until recurrence,
per the maintainer's disposition; this experiment does not explain them.
