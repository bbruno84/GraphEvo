# Durable CKAsset spool — physical checkpoint protocol

Uses the unchanged committed S04 custom-sync runtime. This bridge is copied only
into an external signed host; ordinary package products and CI do not compile it.
Read the [spool contract](../../docs/design/graphevo-2-durable-asset-spool.md).

## Preparation

```sh
python3 Experiments/CloudSpoolProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-spool-host
xcodebuild build -project /tmp/new-spool-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-spool-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Verify the signed app uses only the retained laboratory Development container.
Do not edit the user's demo checkout. Use a fresh run UUID, same-account physical
owner/peer and two fresh private zones `GE2-Spool-<run>-0/1`. No reset, purge,
production data, copied store or previous consumed-stage replay is permitted.
Old laboratory stores remain untouched. Account stages write a salted digest
privately; compare the two digests before running a mutation and never log them.

Use a separate bundle if an eligible profile is available; both launch/collect
helpers accept `--bundle-identifier`. With the existing signed laboratory bundle,
confirm that no other trial needs its live owner before the initial host takeover.
Never erase old app data. Launch with this directory's `launch_probe.py`; arguments after the ticket are
`--cloud-spool <stage> <run-UUID> owner|peer|fresh`. Collect each unique report with
this directory's `collect_report.py`. App-relative evidence is under
`Library/Application Support/GraphEvoLaboratory/CloudSpool/<run>/<replica>/`.
Every stage reserves a `.started` marker before work. Stop on failure/missing
report, retaining stores, logs and original process; do not retry the stage.

## Ordered stages

| Stage / role | Assertion |
|---|---|
| account / owner and peer | Read-only CloudKit account preflight; compare salted digests privately. No graph opened. |
| prepare-owner / owner | Commit four 10 MiB attachments, an empty attachment and an owner with serialized array/dictionary/Codable values. Publish separate 512-byte control. Freeze a 30 MiB main attempt, without sending it. Retain complete reference/file digest proof. |
| resume-owner / owner | After confirmed prior report and process termination, reopen the same files, prove the frozen attempt and file hashes unchanged, send across bounded work windows, verify full server/local state and outgoing-file retirement. |
| fetch-peer / peer | Create genuinely empty stores; fetch all 40 MiB plus control into the durable inbox without importing. Prove native stores remain empty, references/files exist and session/inbox coding stays below 256 KiB. |
| apply-peer / peer | After confirmed prior report and process termination, reopen unchanged inbox and prove IDs/references/file hashes. Apply without a network fetch, then compare complete local/server inventories, exact content and control. Verify no outgoing feedback, duplicate nodes or retained consumed files. |
| verify-owner / owner | After independent peer observation, reopen original owner, fetch/apply and verify complete state, control, queues and outgoing cleanup. |
| recover-fresh / fresh | While the owner remains live, use another genuinely empty replica on the independent device; recover all IDs/content/payloads/control and prove no feedback or retained incoming spool. |

The launcher terminates an existing app. After initial takeover, use it only for a PID whose previous
stage and launch reports were acknowledged. Keep each writer owner alive until
the independent peer has observed its changes. Use separate fresh evidence
directories for every launch/report; never print account values, archives or
body bytes. Keep generated stores, evidence and signing files outside Git.

## Interpretation

This protocol kills/relaunches the app after a durable outgoing preparation and
after durable incoming staging, before send/import respectively. It does not
claim interruption during file publication, native save, an SDK send callback,
or physical power loss. The main fixture is 40 MiB total, not a single oversized
asset; each file obeys the retained 10 MiB ceiling. It exercises ordinary private
replication, not MF10 conversion/authority or cross-account sharing acceptance.
Full server enumeration rejects pagination rather than inferring completeness
from a partial page. This is bounded synthetic device correctness evidence,
not a production latency/memory or arbitrary-media envelope.

## Bounded read-only continuation

`verify-applied-peer / peer` is allowed only after the retained initial
`apply-peer` report failed. It never fetches or applies again: it requires the
complete already-imported replica, compares all records/assets with the server,
and checks that this fixture's queues/files are empty. The original initial
probe incorrectly required the global session inbox to be empty; CKSyncEngine
also reported unrelated historical zone lifecycle events. Those events must be
preserved, not purged to pass a fixture check. Keep the original failure and
continuation provenance separate. No shipping runtime correction is implied.
