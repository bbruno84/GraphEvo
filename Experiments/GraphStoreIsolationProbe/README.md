# GI01 — one graph controller, dedicated stores, native cloud import scope

Experiment-only branch from `codex/graphevo-2`. Do not merge this laboratory or
change the integration architecture merely because the probe runs. Retain the
result, then choose and separately develop a production solution. MC01's closed
copy feasibility does not establish independent per-graph physical publication.

## Question

Can a controller with a dedicated S02 private store (or private/shared pair)
keep only its own logical graph while native Core Data mirroring uses the same
CloudKit container and model as another controller? Does recovery into strictly
new resources preserve that physical partition?

The probe writes A only through original controller A and B only through original
controller B. Each uses a distinct GraphDatabase/native owner and resource URL.
Both graphs get distinct owner-only share zones. The test inspects the unfiltered
resource catalog and validates exact synthetic roots/children/edges/actions;
filtering an app-facing graph handle is not evidence of physical isolation.

## Safety and protocol

Use only the authorized Development test container, owner iPad and different-account
XR. No cloud reset, zone purge or old-fixture edits. Public GraphEvo APIs only;
S02/default model and implementation remain unchanged. Existing account data may
arrive; classify only new run-bound A/B, retaining unrelated counts without IDs.

```sh
python3 Experiments/GraphStoreIsolationProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-GI01-host
```

Build/sign Debug against the integration code. Verify actual signed Development
container, source/executable hashes, install on the two devices and launch with
the acknowledged PublicMirroredProbe launcher:
`--graph-isolation <stage> <new-run-UUID>`. Every stage is one-use; bind each report
to the actual PID/launch ticket/scene. Never replay a consumed mutation.

1. iPad `prepare` creates only the case/transport directory. XR `identity` opens
   its identity resource pair and writes the protected recipient transport.
   Transfer only identity.json to the owner case directory.
2. iPad `seed-recover` opens two independent private controllers, seeds exactly
   one new graph per controller, prepares distinct zones and invites the pinned
   recipient to both. It then opens two strictly absent private directories,
   conceptually intended for A and B, with identical supported mirroring options.
   Observe full A/B payloads in each fresh/original resource. Keep all owners alive.
3. Transfer only fixture.json and invitation-A/B.json to XR. XR `accept-separate`
   opens two independent private/shared pairs, accepts A via pair A and B via pair B,
   then observes the actual graph catalog/payloads of both resource groups.
4. XR `recover-shared` repeats only recovery into two new absent pairs using the
   already accepted original invitations. No native stores/sidecars are transferred.
5. After independent observations, stop only acknowledged probe PIDs and collect
   whole case directories into protected external evidence. Public read-only
   inspection of each copied physical resource distinguishes real imported data
   from accidental wrapper/runtime catalog sharing.

A complete foreign graph in a dedicated resource is a decisive counterexample.
Missing data, setup/export events and an elapsed observation window do not prove
isolation. Report execution failure/incomplete recovery separately from a
counterexample. No command exposes account IDs or invitation URLs in logs.

## Interpretation

Separate files, distinct zones, controller-facing Graph handles and physical
import partitioning are different properties. This probes the supported current
NSPersistentCloudKitContainer configuration, not all conceivable architectures.
Do not infer that 1 controller : 1 Graph is impossible from a failed physical
partition; do not infer that native per-graph import filtering exists either.
A result must distinguish the controller abstraction from exclusive physical
ownership, and leave the production decision to the next design discussion.
