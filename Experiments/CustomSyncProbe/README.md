# CS01 — CKSyncEngine routing, graph pause and local schema migration

Experiment only, based directly on `codex/graphevo-2`. Do not merge the prototype
or treat success as production sync acceptance. Keep the configured demo unchanged.
Use only fresh run-named GE2.CS01 zones in the authorized Development test container;
never modify native Core Data mirror zones or copy native metadata into this format.

## Questions and bounded scope

- Can private graphs have distinct zones without owner-only shares, then share A
  in place while B stays private?
- Can zone-scoped CKSyncEngine input route to separate local Graph controllers,
  each with one graph/store, including fresh other-account recovery?
- Can A stop sending/applying imports with a queued write, retain state across
  relaunch, migrate its native model while paused, and resume both local and peer
  changes while B can still export?

Each Graph controller uses a plain local Core Data stack, not a CloudKit container.
Lab-only native models `GraphEvo.CS01.local.1/2` isolate the experiment from S02
public opening. Version 2 adds one optional native diagnostic attribute; the cloud
record envelope remains unchanged. The package-only factory permits explicit
fixture graph identities; no public opening API is added.

Wire records use the fresh GE2CS01Node type, one record per graph node, with bounded
payload Data. The prototype handles the four known entity/relationship/action
fixture records. Queueing is explicit in the fixture; generic history discovery,
deletions, assets, conflict resolution and account acceptance are not implemented.
No application format registry/version is introduced. Schema/codec/account errors
are retained as failures; malformed bodies have a durable inbox before decoding.

CKSyncEngine automatic scheduling is disabled for deterministic manual operations.
Per-graph gates filter send/fetch scope and application of fetched data. Pausing
calls cancelOperations and drains admitted operations/application before returning;
cancellation itself is not assumed to be a barrier. This first run exercises idle
pause with pending work, B-only progress and restart. In-flight/automatic/background
stress, crash/power-loss recovery and complete atomic store/journal publication
remain unverified. Do not generalize this gate to production suspension safety.

## Protocol

Prepare a disposable Debug host:

```sh
python3 Experiments/CustomSyncProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-CS01-host
```

Verify actual signed Development entitlements and preserve source/executable hashes.
Install on owner iPad and different-account XR. Use the acknowledged public launcher
with `--custom-sync <stage> <new-run-UUID>`. Reports are one-use and bind PID/ticket;
never replay consumed migrations, seeds or share creation.

1. iPad `prepare`; XR `identity`. Transfer only the protected identity transport.
2. iPad `seed-share`: create A/B locally and two private zones, acknowledge all
   records, verify both server zones have no share, then create a zone-wide share
   for A and invite the pinned recipient. Verify B still has no share. Retain owner.
3. Transfer fixture.json/invitation.json only to XR; `peer-baseline` accepts A,
   recovers all records/topology into A's local store, and creates no B store.
4. iPad `pause-migrate`: enqueue A before pause; block A sync, close/back up its
   local store, migrate model 1→2, edit/enqueue the migrated root, and keep A paused.
   B exports an independent progress property while A remains gated.
5. XR `peer-paused-edit`: confirm A's migrated root was not exported, edit another
   record and acknowledge that independent remote write. Retain peer writer.
6. iPad `owner-paused-check`: after relaunch, verify paused/outbox state survives,
   migrated local root remains and the peer's update is not applied yet.
7. iPad `resume`: send A's queued root and fetch the peer's disjoint child update;
   verify identities/topology, B's control fields and zero unexpected zones.
8. XR `peer-final`: independently observe both changes. `peer-fresh` then recovers
   A into a strictly new local directory/state; no native store is transferred.
9. iPad `owner-fresh-A`: register only zone A in a new private reader/controller;
   verify fresh data and no B store despite B's zone existing in that database.
10. After independent observations, stop acknowledged probe processes and retain
    complete local cases/queue/state/model backups outside Git. Inspect physical
    model metadata and graph/native IDs separately; do not parse private SQL tables.

The result must separate selective routing, native schema/data migration, queue
persistence and peer recovery from production reliability. A conflict or unsupported
case must never become a silent successful partial graph. This is an experiment to
choose a path; the implementation, cloud cutover and full v1 migration are later work.
