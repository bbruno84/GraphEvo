# T06 — automatic foreground synchronization probe

Build a disposable demo over a committed runtime, using the existing acknowledged
launcher. New GE2-T06 zones and genuinely new stores only; never reset/purge the
authorized Development container, copy stores or replay a reserved mutation.
Read the [contract](../../docs/design/graphevo-2-automatic-sync.md).

```sh
python3 Experiments/AutomaticSyncProbe/prepare_demo.py ../GraphEvoDemo /tmp/new-auto-host
xcodebuild build -project /tmp/new-auto-host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-auto-build -allowProvisioningUpdates IPHONEOS_DEPLOYMENT_TARGET=17.0
```

Verify signed entitlements: iCloud.com.valerioburiani.GraphCKDemo, Development.
Same-account iPad owner and iPhone peer/fresh. Compare account identity privately;
never commit session documents, raw reports, device logs or stores. The host
aggregates actual scene activity and forwards only container-matched private/shared
hints. Notification forwarding is disabled in periodic-peer and pause-peer.

Use PublicMirroredProbe/launch_probe.py with new external output directories and
`--automatic-sync <stage> <run-UUID> owner|peer|fresh` after its ticket. Collect
using this directory's bounded read-only collect_report.py; it never launches.
App-relative evidence lives below GraphEvoLaboratory/AutomaticSync/<run>/<replica>.
Each stage reserves .started before effects. Stop on failure and retain originals.

| Ordered stage | Assertion |
|---|---|
| seed owner | Automatic upload A1/B1,date10; full inventories and empty queues. |
| read-baseline peer | Empty recovery A1/B1, no upload feedback. |
| periodic-peer peer | Complete initial catch-up; write ready marker. Keep live; wait for A2/B2 through the actual 60s timer without notification forwarding. |
| update-owner owner | Only after peer ready, consumer changes A2/B2,date200; automatic publication. Then collect held periodic-peer. |
| pause-peer peer | A paused,B active at 2/2; write ready marker and keep live. |
| update-control-owner owner | Publish A3/B3,date400 automatically. After passed report copy pause-peer.continue to peer. |
| continue pause-peer | Consumer writes A4,date500 while paused. Automatic B reaches3, A retains pending work with no A record envelopes. Resume A; automatic convergence A4/B3. Pause A again for restart. |
| observe-owner owner | Independent automatic A4/B3 convergence, no feedback. |
| reopen-peer peer | New process starts T05 active and automatically recovers A4/B3. |
| read-final fresh | Empty stores automatically recover exact A4/B3, queues empty. |

Nine final stage reports cover these actions. Ready/continue files are external
laboratory barriers, not sync triggers. Never call manual send/fetch/apply in a
stage. Keep writers alive through independent observations and terminate only
acknowledged process IDs for planned restarts. Final verification compares full
scoped logical inventories and full server-zone modifications from nil tokens,
limit100 with moreComing refused, real change tags and exact edit dates. Do not
query paused A directly during its scoped-fetch assertion.

This is bounded foreground private-data evidence. It does not certify APNs delivery,
background execution, shared participants, crash/backup, EDGE or supported scale.

The optional read-final/current stage creates another guarded empty replica under
current, after the nine-stage run, to verify a later committed runtime without
replaying mutations. Record its runtime separately. Observed [ten-report result](../../docs/design/results/automatic-foreground-sync-2026-10-31.md).
