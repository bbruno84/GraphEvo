# T01 — real manual record transport laboratory

The [ten-stage real result](../../docs/design/results/record-transport-cloudkit-2026-10-31.md)
records the initial successful iPad/iPhone run. This host validates the integrated
T01 implementation, not the retained CS01 prototype. It exports the current committed library tree into a new external
host directory and records its revision. The only extra library source is the
adjacent `GraphCloudTransportDeviceProbe.swift`, copied into that disposable
GraphEvo target so it can reach package/internal operations. It is **not** part
of the distributed library, a new public opener or a replacement sync engine.
Do not use an unreviewed library tree for acceptance evidence.

## Preparation and safety

Use the already configured demo as the source; the script never edits it.

```sh
python3 Experiments/RecordTransportProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-t01-host
xcodebuild build -project /tmp/new-t01-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-t01-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Verify the built app's signing entitlements identify only the authorized
`iCloud.com.valerioburiani.GraphCKDemo` container and Development environment.
The configuration label does not switch the server environment. Install the
signed disposable app; retain its source revision and build/signing evidence
outside the repository. Never commit signing configuration, native stores,
session state, account identities or raw device logs.

Each fresh run UUID selects distinct private A/B zones and app-relative local
directories. No cloud reset, old-store conversion, zone deletion or existing
fixture overwrite occurs. Replica files live at the current sandbox's
`Library/Application Support/GraphEvoLaboratory/RecordTransport/<run>/<replica>/`.
All persisted cloud routes are path-free. Stage reservations are written before
work and refuse replay, including after a failed or missing report. Do not rerun
a consumed mutation or manufacture a fresh replica by copying a native store.
Diagnose partial work before designing an explicit recovery stage.

## Ordered protocol

Use the acknowledged PublicMirroredProbe launcher, with a **new external output
directory for every launch**. CLI after the launch ticket:

`--record-transport <stage> <run-UUID> owner|peer|fresh`

The launcher acknowledgement only proves that the intended process and scene
started. Separately retrieve `<stage>.report.json` from the replica directory;
`status: passed` is the stage result. `collect_report.py` performs bounded read-only
report retrieval and refuses mismatched/failed reports; it never relaunches a stage.
Explicitly terminate only an acknowledged prior host PID before a planned restart
to avoid racing CoreDevice's terminate-existing launch. A native save, empty pending list or launcher
receipt alone does not establish server/replica recovery.

| Stage / replica | Assertion |
|---|---|
| `seed owner` | Fresh exclusive A/B stores; Entity/Relationship/Action fixture in A and unchanged control B; actual CKSyncEngine sends; independent direct server fetch verifies complete values/topology and nonempty native change tags. |
| `read-baseline peer` | Create empty independent stores, fetch/apply through the production engine/inbox, compare exact primitives, check no upload feedback and independent server state. Prefer same-account second hardware; same-device independent stores establish a narrower boundary. |
| `update owner` | Reopen original stores/session; change values/remove a property/add tags, add an entity and edge, extend action subjects. Before sending, the actual frozen provider archive must reuse the server's change tag. Compare all local/server records and B. |
| `read-update peer` | Existing independent peer imports updated values and all new references without feedback. |
| `delete owner` | Delete the original target entity; assert edge cascade, surviving action's reduced endpoints, unchanged new edge and B, and server absence via unknownItem. |
| `read-delete peer` | Existing peer imports deletions/cascades and keeps its queue empty. |
| `reopen owner` | Restart and recover original native/session state without edits or upload; verify final local/server fixture. |
| `read-delete fresh` | Start genuinely empty stores after deletions; recover only final surviving primitives and unchanged B. |
| `audit owner`, `read-audit fresh` | Read-only final audits compare the complete local application-node inventory and complete server zone modifications from a nil token (bounded at 100 records with moreComing refused). No unexpected record may survive in A or B. |

Owners remain retained after each report until host termination. Actual server
fetches provide independent remote evidence before replacing the owner process;
keep the writer running for independent peer observation whenever using second
hardware. Do not interpret this as a global synchronization barrier.

The fixture uses fixed dates, tags/groups, explicit null, UUID, binary data,
property removal and all graph primitive kinds. Queries verify GraphRecord values
and topology. Server inspection uses CF01 decoding and exact record IDs, never
Core Data SQLite inspection or a clone of the source store. Server change tags
are real framework metadata, never fabricated.

## Acceptance limits

No CKAsset, sharing/invitation, automatic scheduling, account switch, genuine
conflict-resolution policy, actual kill-during-commit or backup restoration is
proved here. Same-device independent stores are not physical cross-device proof.
The initial #111 CI store-test process exit was not reproduced locally on iOS
18.5 or in exact-head CI `41190746167`; iOS result-bundle retention was added,
without weakening runtime guards/tests. Its cause remains undiagnosed and belongs
to crash/stress follow-up, not a claimed fix.
