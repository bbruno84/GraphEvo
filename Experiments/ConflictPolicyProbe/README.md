# T03 — automatic conflict policy device protocol

Uses the package-only production ContextManager/coordinator/CKSyncEngine path,
with an injected clock controlling only automatic consumer edit timestamps.
No prototype resolver, raw metadata edits or server change-tag fabrication.
Native S03 is unchanged. Read the [contract](../../docs/design/graphevo-2-conflict-policies.md).

## Prepare an isolated signed host

Export a committed runtime into a new external directory; the adjacent bridge is
added only there. Never edit the original demo, copy native stores to a new
replica, replay a started stage, reset the container or purge old fixtures.

```sh
python3 Experiments/ConflictPolicyProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-policy-host
xcodebuild build -project /tmp/new-policy-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-policy-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Verify signed entitlements: only authorized test container
`iCloud.com.valerioburiani.GraphCKDemo`, Development. Install on iPad and iPhone
with the same iCloud account; compare identities privately, never log them.
One ContextManager owns seven exclusive stores and its single private engine.
Zones are `GE2-T03-<new-run-UUID>-U/L/C/T/D/R/B`. Each graph starts with one entity
at value 1 (control B=99), createdDate 1 and automatically stamped modifiedAt 10.
C uses cloudWins, all other graphs lastEditWins. Each reopened handle must read
its persisted policy. Files are app-relative under
`Library/Application Support/GraphEvoLaboratory/ConflictPolicies/<run>/<replica>/`.
Bindings and detached frozen batches contain no local store URL.

## Ordered execution

Use `PublicMirroredProbe/launch_probe.py` with a fresh output directory/ticket,
then `ConflictPolicyProbe/collect_report.py` with another fresh output directory.
Arguments after the ticket: `--conflict-policy <stage> <run-UUID> owner|peer|fresh`.
Each stage reserves a started marker before any effect. Stop on any failure or
missing report and inspect retained state; neither helper replays a mutation.
Terminate only the previously acknowledged process PID for a planned restart.
Keep writers alive through independent server/peer observation. Launcher receipts
and actual stage reports are separate evidence. Store raw evidence privately
outside the repository; never commit account/session documents, archives or logs.

| Stage / replica | Assertions |
|---|---|
| seed / owner | Create seven new stores/zones, publish baseline; exact local/server inventories, real nonempty native tags, queues empty. |
| read-baseline / peer | Seven genuinely empty stores recover baseline and dates without feedback. |
| prepare-peer / peer | U=3 plus unrelated new leaf=30, date100; L/C/R=3 date300; T=3 date200; D deleted. Freeze six native attempts; no send. |
| owner-compete / owner | U/L/C/T/D=2 date200; R deleted. Publish after peer attempts are frozen. |
| resolve-peer / peer | Edit current L=4 date400 after frozen3. Send six graphs: U cloud winner + partial leaf success; L current4 rebase/retry; C cloud despite newer local date; T tie cloud; D deletion succeeds; R associated unknownItem resolves deletion. Then B=100 date500. Exact results/counts, full inventories and queues checked. |
| reopen-peer / peer | Without fetch, resolved data/dates, persisted policies and empty queues survive process/session restart. |
| observe-owner / owner | Explicit fetch/import converges to final state with no feedback. |
| read-final / fresh | New independent empty stores recover final data/dates/complete inventories; no source-store copying. |

Final server state: U=2/date200 plus leaf30/date100, L=4/date400, C=2/date200,
T=2/date200, B=100/date500; D/R absent. Verification enumerates all local logical
IDs through the typed/scoped adapter and all server zone modifications from a nil
token, limit100, refusing moreComing. It checks full GraphRecords, dates, actual
server tags and empty PH queues. There is no SQLite-file inference of sync.

See the [initial result](../../docs/design/results/conflict-policies-cloudkit-2026-10-31.md)
for exact runtime/device provenance. This bounded entity-only private protocol
covers real CAS/unknownItem behavior. General structural conflicts, assets,
sharing/permissions, clock skew, power-loss and backup remain separate gates.
